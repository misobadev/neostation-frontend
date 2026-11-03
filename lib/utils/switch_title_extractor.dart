import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:neostation/services/logger_service.dart';
import '../services/saf_directory_service.dart';

/// Service responsible for extracting Title IDs and metadata from Nintendo Switch ROMs.
///
/// Supports NSP (with or without tickets) and XCI formats by parsing their
/// internal file structures (PFS0, NCA, HEAD) and optionally decrypting headers.
class SwitchTitleExtractor {
  /// Internal storage for cryptographic keys.
  static final Map<String, String> _encryptionKeys = {};

  static final _log = LoggerService.instance;

  /// Tracks if the cryptographic keys have been initialized.
  static bool _keysLoaded = false;

  /// Only the NCA header key is needed for Title ID extraction.
  static const String _prodKeysData = '''
header_key = aeaab1ca08adf9bef12991f369e3c567d6881e4e4a6a47a51f6e4877062d542d
''';

  /// Loads the encryption keys from hardcoded data into the internal map.
  static Future<bool> loadKeys() async {
    if (_keysLoaded) return true;

    try {
      final lines = _prodKeysData.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;

        final parts = line.split('=');
        if (parts.length == 2) {
          _encryptionKeys[parts[0].trim()] = parts[1].trim();
        }
      }
      _keysLoaded = true;
      return true;
    } catch (e) {
      _log.e('Error loading encryption keys: $e');
      return false;
    }
  }

  /// Helper to convert a hexadecimal string to a byte array.
  static Uint8List _hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '');
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Multiplies the tweak value by alpha in the GF(2^128) field for AES-XTS mode.
  static void _multiplyTweakAlpha(Uint8List tweak) {
    var carry = 0;
    for (var i = 0; i < 16; i++) {
      final b = tweak[i];
      tweak[i] = ((b << 1) | carry) & 0xFF;
      carry = (b >> 7) & 1;
    }
    if (carry != 0) {
      tweak[0] ^= 0x87; // XTS irreducible polynomial.
    }
  }

  /// Decrypts a Nintendo Content Archive (NCA) header using AES-XTS.
  static Uint8List? _decryptNCAHeader(
    Uint8List encryptedHeader,
    String headerKeyHex,
  ) {
    try {
      final keyBytes = _hexToBytes(headerKeyHex);
      if (keyBytes.length != 32) return null;

      // AES-XTS utilizes two distinct 16-byte keys.
      final key1 = keyBytes.sublist(0, 16);
      final key2 = keyBytes.sublist(16, 32);

      final decrypted = Uint8List(0xC00);

      // Decrypt each 0x200-byte sector (6 sectors total).
      for (var sectorNum = 0; sectorNum < 6; sectorNum++) {
        final sectorOffset = sectorNum * 0x200;
        final sectorData = encryptedHeader.sublist(
          sectorOffset,
          sectorOffset + 0x200,
        );

        // Nintendo-specific tweak: big-endian sector number.
        final tweak = Uint8List(16);
        var tempSector = sectorNum;
        for (var i = 15; i >= 0; i--) {
          tweak[i] = tempSector & 0xFF;
          tempSector >>= 8;
        }

        // Encrypt the tweak with key2.
        final cipher2 = AESEngine();
        cipher2.init(true, KeyParameter(key2));
        final encryptedTweak = Uint8List(16);
        cipher2.processBlock(tweak, 0, encryptedTweak, 0);

        final cipher1 = AESEngine();
        cipher1.init(false, KeyParameter(key1));

        for (var i = 0; i < 0x200; i += 16) {
          final block = Uint8List(16);
          for (var j = 0; j < 16; j++) {
            block[j] = sectorData[i + j] ^ encryptedTweak[j];
          }

          final decryptedBlock = Uint8List(16);
          cipher1.processBlock(block, 0, decryptedBlock, 0);

          for (var j = 0; j < 16; j++) {
            decrypted[sectorOffset + i + j] =
                decryptedBlock[j] ^ encryptedTweak[j];
          }

          _multiplyTweakAlpha(encryptedTweak);
        }
      }
      return decrypted;
    } catch (e) {
      return null;
    }
  }

  /// Extracts the Title ID from a decrypted NCA header.
  static String? _extractTitleIdFromNCAHeader(Uint8List decryptedHeader) {
    if (decryptedHeader.length < 0x218) return null;

    // Validate magic identifier (NCA3 = 0x3341434E, NCA2 = 0x3241434E).
    final magic = ByteData.sublistView(
      decryptedHeader,
      0x200,
      0x204,
    ).getUint32(0, Endian.little);
    if (magic != 0x3341434E && magic != 0x3241434E) return null;

    // Title ID is located at offset 0x210 (8 bytes, little-endian).
    final titleId = ByteData.sublistView(
      decryptedHeader,
      0x210,
      0x218,
    ).getUint64(0, Endian.little);

    return titleId.toRadixString(16).toUpperCase().padLeft(16, '0');
  }

  /// Extracts game information from an XCI (NX Cartridge Image) file.
  static Future<SwitchGameInfo?> _extractFromXCI(String path) async {
    final reader = _SwitchByteReader(path);
    if (!await reader.exists()) return null;

    try {
      final fileName = path
          .split(
            Platform.isWindows || path.startsWith('content://')
                ? '/'
                : Platform.pathSeparator,
          )
          .last
          .replaceAll('.xci', '');

      final headerBytes = await reader.read(0x100, 0x200);
      if (headerBytes == null) return null;

      // Verify "HEAD" magic at offset 0x100.
      if (String.fromCharCodes(headerBytes.sublist(0, 4)) != 'HEAD') {
        return null;
      }

      // Title ID is at offset 0x118 (8 bytes, little-endian reversed).
      final titleIdBytes = await reader.read(0x118, 8);
      if (titleIdBytes != null && titleIdBytes.length == 8) {
        final titleId = titleIdBytes.reversed
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();
        return SwitchGameInfo(titleId, fileName, 'XCI');
      }
      return null;
    } catch (e) {
      return null;
    } finally {
      await reader.close();
    }
  }

  /// Extracts game information from an NSP (Nintendo Submission Package) file.
  static Future<SwitchGameInfo?> _extractFromNSP(String path) async {
    final reader = _SwitchByteReader(path);
    if (!await reader.exists()) return null;

    try {
      final fileName = path
          .split(
            Platform.isWindows || path.startsWith('content://')
                ? '/'
                : Platform.pathSeparator,
          )
          .last
          .replaceAll('.nsp', '');

      // Parse Partition Filesystem (PFS0) header.
      final headerBytes = await reader.read(0, 16);
      if (headerBytes == null ||
          String.fromCharCodes(headerBytes.sublist(0, 4)) != 'PFS0') {
        return null;
      }

      final fileCount = ByteData.sublistView(
        Uint8List.fromList(headerBytes.sublist(4, 8)),
      ).getUint32(0, Endian.little);
      final stringTableSize = ByteData.sublistView(
        Uint8List.fromList(headerBytes.sublist(8, 12)),
      ).getUint32(0, Endian.little);

      final fileEntrySize = 24;
      final fileTableBytes = await reader.read(16, fileCount * fileEntrySize);
      if (fileTableBytes == null) return null;

      final stringTableBytes = await reader.read(
        16 + (fileCount * fileEntrySize),
        stringTableSize,
      );
      if (stringTableBytes == null) return null;
      final stringTable = String.fromCharCodes(stringTableBytes);

      String? titleId;

      // Strategy 1: Search for a .tik file (fastest method, covers ~87% of cases).
      for (int i = 0; i < fileCount; i++) {
        final entryOffset = i * fileEntrySize;
        final stringTableOffset = ByteData.sublistView(
          Uint8List.fromList(
            fileTableBytes.sublist(entryOffset + 16, entryOffset + 20),
          ),
        ).getUint32(0, Endian.little);
        final nameEndIndex = stringTable.indexOf('\x00', stringTableOffset);
        final internalName = stringTable.substring(
          stringTableOffset,
          nameEndIndex == -1 ? null : nameEndIndex,
        );

        if (internalName.toLowerCase().endsWith('.tik') &&
            internalName.length >= 16) {
          titleId = internalName.substring(0, 16).toUpperCase();
          if (!isAdditionalContent(titleId)) break;
        }
      }

      // Strategy 2: Parse metadata from .cnmt.xml if Title ID wasn't found in .tik.
      if (titleId == null) {
        final dataOffset = 16 + (fileCount * fileEntrySize) + stringTableSize;
        for (int i = 0; i < fileCount; i++) {
          final entryOffset = i * fileEntrySize;
          final fileOffset = ByteData.sublistView(
            Uint8List.fromList(
              fileTableBytes.sublist(entryOffset, entryOffset + 8),
            ),
          ).getUint64(0, Endian.little);
          final fileSize = ByteData.sublistView(
            Uint8List.fromList(
              fileTableBytes.sublist(entryOffset + 8, entryOffset + 16),
            ),
          ).getUint64(0, Endian.little);
          final stringTableOffset = ByteData.sublistView(
            Uint8List.fromList(
              fileTableBytes.sublist(entryOffset + 16, entryOffset + 20),
            ),
          ).getUint32(0, Endian.little);

          final nameEndIndex = stringTable.indexOf('\x00', stringTableOffset);
          final internalName = stringTable.substring(
            stringTableOffset,
            nameEndIndex == -1 ? null : nameEndIndex,
          );

          if (internalName.toLowerCase().endsWith('.cnmt.xml')) {
            final xmlBytes = await reader.read(
              dataOffset + fileOffset.toInt(),
              fileSize.toInt(),
            );
            if (xmlBytes == null) continue;
            final xmlContent = utf8.decode(xmlBytes);

            final match = RegExp(
              r'<(TitleId|Id)>0x([0-9a-fA-F]+)</\1>',
            ).firstMatch(xmlContent);
            if (match != null) {
              titleId = match.group(2)!.toUpperCase();
              break;
            }
          }
        }
      }

      // Strategy 3: Decrypt .cnmt.nca header as a last resort (covers remaining ~4% of cases).
      if (titleId == null &&
          _keysLoaded &&
          _encryptionKeys.containsKey('header_key')) {
        final dataOffset = 16 + (fileCount * fileEntrySize) + stringTableSize;
        for (int i = 0; i < fileCount; i++) {
          final entryOffset = i * fileEntrySize;
          final fileOffset = ByteData.sublistView(
            Uint8List.fromList(
              fileTableBytes.sublist(entryOffset, entryOffset + 8),
            ),
          ).getUint64(0, Endian.little);
          final stringTableOffset = ByteData.sublistView(
            Uint8List.fromList(
              fileTableBytes.sublist(entryOffset + 16, entryOffset + 20),
            ),
          ).getUint32(0, Endian.little);
          final nameEndIndex = stringTable.indexOf('\x00', stringTableOffset);
          final internalName = stringTable.substring(
            stringTableOffset,
            nameEndIndex == -1 ? null : nameEndIndex,
          );

          if (internalName.toLowerCase().endsWith('.cnmt.nca')) {
            final encryptedHeader = await reader.read(
              dataOffset + fileOffset.toInt(),
              0xC00,
            );
            if (encryptedHeader == null) continue;

            final decryptedHeader = _decryptNCAHeader(
              Uint8List.fromList(encryptedHeader),
              _encryptionKeys['header_key']!,
            );
            if (decryptedHeader != null) {
              titleId = _extractTitleIdFromNCAHeader(decryptedHeader);
              if (titleId != null) break;
            }
          }
        }
      }

      if (titleId != null) return SwitchGameInfo(titleId, fileName, 'NSP');
      return null;
    } catch (e) {
      return null;
    } finally {
      await reader.close();
    }
  }

  /// Application IDs are aligned to 0x1000; patches use offset 0x800
  /// and add-on content uses nonzero offsets in the next application range.
  /// Reject malformed/non-application IDs rather than hiding unknown files.
  static bool isAdditionalContent(String? titleId) {
    if (titleId == null ||
        !RegExp(r'^0100[0-9a-fA-F]{12}$').hasMatch(titleId)) {
      return false;
    }
    return int.parse(titleId.substring(13), radix: 16) != 0;
  }

  /// Main entry point to extract Title ID and metadata from a Switch ROM (NSP or XCI).
  static Future<SwitchGameInfo?> extractGameInfo(String path) async {
    if (!_keysLoaded) await loadKeys();

    final extension = path.toLowerCase().split('.').last;
    if (extension == 'nsp' || extension == 'nsz') {
      return await _extractFromNSP(path);
    } else if (extension == 'xci') {
      return await _extractFromXCI(path);
    }
    return null;
  }
}

/// Container for metadata extracted from a Nintendo Switch game file.
class SwitchGameInfo {
  final String titleId;
  final String gameName;
  final String format; // 'NSP' or 'XCI'

  SwitchGameInfo(this.titleId, this.gameName, this.format);

  @override
  String toString() => '$titleId | $format | $gameName';
}

/// Internal helper for reading byte ranges from standard files or Android SAF URIs.
class _SwitchByteReader {
  final String path;
  RandomAccessFile? _raf;
  final bool isSaf;

  _SwitchByteReader(this.path) : isSaf = path.startsWith('content://');

  Future<bool> exists() async {
    if (isSaf) return true;
    return await File(path).exists();
  }

  Future<Uint8List?> read(int offset, int length) async {
    if (isSaf) {
      return await SafDirectoryService.readRange(path, offset, length);
    } else {
      _raf ??= await File(path).open();
      await _raf!.setPosition(offset);
      return await _raf!.read(length);
    }
  }

  Future<void> close() async {
    if (_raf != null) {
      await _raf!.close();
      _raf = null;
    }
  }
}
