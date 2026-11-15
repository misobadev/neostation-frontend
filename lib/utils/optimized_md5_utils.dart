import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:archive/archive.dart';
import 'package:neostation/services/logger_service.dart';

import '../services/saf_directory_service.dart';
import '../services/archive_service.dart';

import 'dart:convert';

import 'semaphore.dart';

/// Utility service for high-performance MD5 hashing and file access.
///
/// Optimized for cross-platform execution, supporting standard filesystems
/// and Android Storage Access Framework (SAF) URI paths.
class OptimizedMd5Utils {
  static final _log = LoggerService.instance;

  /// Validates file existence, supporting both standard paths and Android SAF URIs.
  static Future<bool> fileExists(String filePath) async {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      return true; // Assume existence if path originated from SAF picker.
    }
    return await File(filePath).exists();
  }

  /// Retrieves the file size in bytes.
  static Future<int> getFileSize(String filePath) async {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      return await SafDirectoryService.getFileSize(filePath);
    }
    return await File(filePath).length();
  }

  /// Reads the entire content of a file into a [Uint8List].
  ///
  /// Uses chunked reading for SAF URIs to optimize memory usage and performance.
  static Future<Uint8List> readAllBytes(String filePath) async {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      final builder = BytesBuilder();
      int offset = 0;
      const chunkSize = 1024 * 1024 * 2; // 2MB chunks.
      while (true) {
        final chunk = await SafDirectoryService.readRange(
          filePath,
          offset,
          chunkSize,
        );
        if (chunk == null || chunk.isEmpty) break;
        builder.add(chunk);
        if (chunk.length < chunkSize) break;
        offset += chunk.length;
      }
      return builder.toBytes();
    }
    return await File(filePath).readAsBytes();
  }

  /// Reads a specific byte range from a file.
  static Future<Uint8List> readRange(
    String filePath,
    int offset,
    int length,
  ) async {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      final chunk = await SafDirectoryService.readRange(
        filePath,
        offset,
        length,
      );
      return chunk ?? Uint8List(0);
    }
    final raf = await File(filePath).open();
    await raf.setPosition(offset);
    final bytes = await raf.read(length);
    await raf.close();
    return bytes;
  }

  /// Calculates a specialized MD5 hash for Nintendo DS ROMs.
  ///
  /// This implementation follows the RetroAchievements C-reference logic,
  /// which hashes the header, ARM9 code, ARM7 code, and icon/title blocks.
  static Future<String> calculateDsMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) {
        throw Exception('File does not exist: $filePath');
      }

      int offset = 0;
      // Read the 512-byte hardware header.
      final headerBytes = await readRange(filePath, offset, 512);
      if (headerBytes.length != 512) {
        throw Exception('Failed to read DS header');
      }
      final header = List<int>.from(headerBytes);

      // Detect and skip SuperCard-specific headers.
      if (header[0] == 0x2E &&
          header[1] == 0x00 &&
          header[2] == 0x00 &&
          header[3] == 0xEA &&
          header[0xB0] == 0x44 &&
          header[0xB1] == 0x46 &&
          header[0xB2] == 0x96 &&
          header[0xB3] == 0) {
        offset = 512;
        final header2 = await readRange(filePath, offset, 512);
        if (header2.length != 512) {
          throw Exception('Failed to read DS header after SuperCard skip');
        }
        for (int i = 0; i < 512; i++) {
          header[i] = header2[i];
        }
      }

      // Parse binary offsets and sizes from the header.
      int arm9Addr = _readUint32LE(header, 0x20);
      int arm9Size = _readUint32LE(header, 0x2C);
      int arm7Addr = _readUint32LE(header, 0x30);
      int arm7Size = _readUint32LE(header, 0x3C);
      int iconAddr = _readUint32LE(header, 0x68);

      // Security check: validate code size sanity.
      if (arm9Size + arm7Size > 16 * 1024 * 1024) {
        throw Exception('ARM9 + ARM7 code size exceeds 16MB threshold');
      }

      final hashData = <int>[];
      // 1. Hash the first 352 bytes (0x160) of the header.
      hashData.addAll(header.sublist(0, 0x160));

      // 2. Hash the ARM9 binary segment.
      if (arm9Size > 0) {
        final arm9Code = await readRange(filePath, arm9Addr + offset, arm9Size);
        hashData.addAll(arm9Code);
      }

      // 3. Hash the ARM7 binary segment.
      if (arm7Size > 0) {
        final arm7Code = await readRange(filePath, arm7Addr + offset, arm7Size);
        hashData.addAll(arm7Code);
      }

      // 4. Hash the 2.5KB (0xA00) icon/title metadata block.
      final iconBlock = await readRange(filePath, iconAddr + offset, 0xA00);
      if (iconBlock.length < 0xA00) {
        hashData.addAll(iconBlock);
        hashData.addAll(List.filled(0xA00 - iconBlock.length, 0));
      } else {
        hashData.addAll(iconBlock);
      }

      return crypto.md5.convert(hashData).toString();
    } catch (e) {
      _log.e('Error calculating DS MD5 for $filePath: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for Arcade ROMs (MAME, FBNeo, NeoGeo).
  ///
  /// Per RetroAchievements specifications, Arcade hashing is based on the
  /// lowercase filename without the extension.
  static String calculateArcadeMd5(String filePath) {
    try {
      String fileName = filePath;

      // Decode URI components if the path is an Android SAF identifier.
      if (fileName.startsWith('content://')) {
        try {
          fileName = Uri.decodeFull(fileName);
        } catch (_) {}
      }

      // Extract the base filename.
      if (fileName.contains('/')) {
        fileName = fileName.substring(fileName.lastIndexOf('/') + 1);
      }
      if (fileName.contains('\\')) {
        fileName = fileName.substring(fileName.lastIndexOf('\\') + 1);
      }

      // Strip the last file extension.
      int dotIndex = fileName.lastIndexOf('.');
      String nameWithoutExtension = dotIndex != -1
          ? fileName.substring(0, dotIndex)
          : fileName;

      final bytes = utf8.encode(nameWithoutExtension);
      return crypto.md5.convert(bytes).toString();
    } catch (e) {
      _log.e('Error calculating Arcade MD5 for $filePath: $e');
      rethrow;
    }
  }

  /// Reads a 32-bit unsigned integer in Little-Endian format.
  static int _readUint32LE(List<int> bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  /// Streams [filePath] in chunks, SAF-aware, without ever holding the whole
  /// file in memory.
  ///
  /// [readAllBytes] is fine for the per-system generators, which need random
  /// access into a header and run behind a size gate. Anything that only walks
  /// the bytes in order should use this instead, so a large ROM costs one
  /// buffer rather than its full size.
  static Future<void> readChunked(
    String filePath,
    void Function(Uint8List chunk) onChunk, {
    int chunkSize = 2 * 1024 * 1024,
  }) async {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      int offset = 0;
      while (true) {
        final chunk = await SafDirectoryService.readRange(
          filePath,
          offset,
          chunkSize,
        );
        // null is a read *error* (the platform side reports EOF as an empty
        // array, and readRange maps PlatformException to null). Treating it as
        // end-of-file would hand the caller a truncated stream — and a hash of
        // truncated bytes is confidently wrong, so fail loudly instead.
        if (chunk == null) {
          throw FileSystemException(
            'SAF read failed at offset $offset',
            filePath,
          );
        }
        if (chunk.isEmpty) break;
        onChunk(chunk);
        offset += chunk.length;
        if (chunk.length < chunkSize) break;
      }
      return;
    }

    await for (final chunk in File(filePath).openRead()) {
      onChunk(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
  }

  /// Calculates a standard MD5 hash for the given file.
  static Future<String> calculateFileMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) {
        throw Exception('File does not exist: $filePath');
      }

      final bytes = await readAllBytes(filePath);
      return crypto.md5.convert(bytes).toString();
    } catch (e) {
      _log.e('Error calculating MD5 for $filePath: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for NES/Famicom and Famicom Disk System ROMs.
  ///
  /// If the ROM includes an iNES header ("NES\x1a") or an FDS header
  /// ("FDS\x1a"), the first 16 bytes are skipped before hashing, which is what
  /// rcheevos does and therefore what RetroAchievements' registered hashes are
  /// computed over. Handles compressed (.zip, .7z) files by extracting them
  /// first.
  static Future<String> calculateNesMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) {
        throw Exception('File does not exist: $filePath');
      }

      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      final lowerPath = filePath.toLowerCase();
      if ((lowerPath.endsWith('.zip') || lowerPath.endsWith('.7z')) &&
          bytes.length >= 4) {
        if (lowerPath.endsWith('.7z')) {
          final extractedPath = await ArchiveService.extractRom(
            filePath,
            'temp_nes',
          );
          try {
            if (extractedPath != null) {
              romBytes = await File(extractedPath).readAsBytes();
            }
          } finally {
            await ArchiveService.cleanupTempFolder('temp_nes', filePath);
          }
        } else if (bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04) {
          try {
            final archive = ZipDecoder().decodeBytes(bytes);
            ArchiveFile? nesFile = archive.firstWhere(
              (f) => f.isFile && f.name.toLowerCase().endsWith('.nes'),
              orElse: () => archive.firstWhere((f) => f.isFile),
            );
            romBytes = nesFile.content as List<int>;
          } catch (e) {
            _log.e('Error extracting NES ZIP: $e');
            romBytes = bytes;
          }
        }
      }

      // Check for an iNES ("NES\x1a") or FDS ("FDS\x1a") header. Both are
      // 16 bytes and both are excluded from the hash RetroAchievements
      // registers; a headered .fds hashed whole matches nothing.
      if (_hasNesOrFdsHeader(romBytes)) {
        // Strip 16-byte header.
        return crypto.md5
            .convert(romBytes.length > 16 ? romBytes.sublist(16) : romBytes)
            .toString();
      } else {
        return crypto.md5.convert(romBytes).toString();
      }
    } catch (e) {
      _log.e('Error calculating NES MD5 for $filePath: $e');
      rethrow;
    }
  }

  /// Whether [bytes] starts with a 16-byte iNES or FDS header.
  ///
  /// Both magics share a layout — three ASCII letters then 0x1A — and both
  /// precede 16 bytes that RetroAchievements excludes from the hash.
  static bool _hasNesOrFdsHeader(List<int> bytes) {
    if (bytes.length < 4 || bytes[3] != 0x1A) return false;
    // "NES" or "FDS".
    final isNes = bytes[0] == 0x4E && bytes[1] == 0x45 && bytes[2] == 0x53;
    final isFds = bytes[0] == 0x46 && bytes[1] == 0x44 && bytes[2] == 0x53;
    return isNes || isFds;
  }

  /// Calculates the MD5 hash for SNES/Super Famicom ROMs.
  ///
  /// If the ROM contains a 512-byte copier header (identified if file size is
  /// 512 bytes over a multiple of 8KB), the header is ignored.
  static Future<String> calculateSnesMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) {
        throw Exception('File does not exist: $filePath');
      }

      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      final lowerPath = filePath.toLowerCase();
      if ((lowerPath.endsWith('.zip') || lowerPath.endsWith('.7z')) &&
          bytes.length >= 4) {
        if (lowerPath.endsWith('.7z')) {
          final extractedPath = await ArchiveService.extractRom(
            filePath,
            'temp_snes',
          );
          try {
            if (extractedPath != null) {
              romBytes = await File(extractedPath).readAsBytes();
            }
          } finally {
            await ArchiveService.cleanupTempFolder('temp_snes', filePath);
          }
        } else if (bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04) {
          try {
            final archive = ZipDecoder().decodeBytes(bytes);
            ArchiveFile? snesFile = archive.firstWhere(
              (f) =>
                  f.isFile &&
                  (f.name.toLowerCase().endsWith('.sfc') ||
                      f.name.toLowerCase().endsWith('.smc') ||
                      f.name.toLowerCase().endsWith('.fig') ||
                      f.name.toLowerCase().endsWith('.swc')),
              orElse: () => archive.firstWhere((f) => f.isFile),
            );
            romBytes = snesFile.content as List<int>;
          } catch (e) {
            _log.e('Error extracting SNES ZIP: $e');
            romBytes = bytes;
          }
        }
      }

      // RetroAchievements Logic: If (size % 8192) == 512, strip the first 512 bytes.
      if (romBytes.length % 8192 == 512) {
        return crypto.md5
            .convert(romBytes.length > 512 ? romBytes.sublist(512) : romBytes)
            .toString();
      } else {
        return crypto.md5.convert(romBytes).toString();
      }
    } catch (e) {
      _log.e('Error calculating SNES MD5 for $filePath: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for Atari 7800 ROMs.
  ///
  /// Skips the 128-byte header if the file starts with the signature "\x01ATARI7800".
  static Future<String> calculateAtari7800Md5(String filePath) async {
    try {
      if (!await fileExists(filePath)) throw Exception('File not found');
      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      // Extract ZIP if needed.
      if (filePath.toLowerCase().endsWith('.zip')) {
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          romBytes =
              archive
                      .firstWhere(
                        (f) =>
                            f.isFile && f.name.toLowerCase().endsWith('.a78'),
                        orElse: () => archive.firstWhere((f) => f.isFile),
                      )
                      .content
                  as List<int>;
        } catch (_) {}
      }

      // Check signature.
      if (romBytes.length >= 10 &&
          romBytes[0] == 0x01 &&
          utf8.decode(romBytes.sublist(1, 10)) == 'ATARI7800') {
        return crypto.md5
            .convert(romBytes.length > 128 ? romBytes.sublist(128) : romBytes)
            .toString();
      }
      return crypto.md5.convert(romBytes).toString();
    } catch (e) {
      _log.e('Error calculating Atari 7800 MD5: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for Atari Lynx ROMs.
  ///
  /// Skips the 64-byte header if the file starts with "LYNX\0".
  static Future<String> calculateLynxMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) throw Exception('File not found');
      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      if (filePath.toLowerCase().endsWith('.zip')) {
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          romBytes =
              archive
                      .firstWhere(
                        (f) =>
                            f.isFile && f.name.toLowerCase().endsWith('.lnx'),
                        orElse: () => archive.firstWhere((f) => f.isFile),
                      )
                      .content
                  as List<int>;
        } catch (_) {}
      }

      if (romBytes.length >= 5 &&
          utf8.decode(romBytes.sublist(0, 4)) == 'LYNX' &&
          romBytes[4] == 0x00) {
        return crypto.md5
            .convert(romBytes.length > 64 ? romBytes.sublist(64) : romBytes)
            .toString();
      }
      return crypto.md5.convert(romBytes).toString();
    } catch (e) {
      _log.e('Error calculating Atari Lynx MD5: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for Arduboy hex files.
  ///
  /// Normalizes line endings to Unix style (\n) before hashing to ensure consistency across OSs.
  static Future<String> calculateArduboyMd5(String filePath) async {
    try {
      if (!await fileExists(filePath)) throw Exception('File not found');
      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      if (filePath.toLowerCase().endsWith('.zip')) {
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          romBytes =
              archive
                      .firstWhere(
                        (f) =>
                            f.isFile && f.name.toLowerCase().endsWith('.hex'),
                        orElse: () => archive.firstWhere((f) => f.isFile),
                      )
                      .content
                  as List<int>;
        } catch (_) {}
      }

      String text = utf8.decode(romBytes, allowMalformed: true);
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      return crypto.md5.convert(utf8.encode(text)).toString();
    } catch (e) {
      _log.e('Error calculating Arduboy MD5: $e');
      rethrow;
    }
  }

  /// Calculates the MD5 hash for Nintendo 64 ROMs.
  ///
  /// Automatically detects and normalizes ByteSwapped (.v64) and Little Endian (.n64)
  /// layouts to Big Endian (.z64) before hashing.
  static Future<String> calculateN64Md5(String filePath) async {
    try {
      if (!await fileExists(filePath)) throw Exception('File not found');
      final bytes = await readAllBytes(filePath);
      List<int> romBytes = bytes;

      final lowerPath = filePath.toLowerCase();
      if (lowerPath.endsWith('.zip') || lowerPath.endsWith('.7z')) {
        if (lowerPath.endsWith('.7z')) {
          final extractedPath = await ArchiveService.extractRom(
            filePath,
            'temp_n64',
          );
          try {
            if (extractedPath != null) {
              romBytes = await File(extractedPath).readAsBytes();
            }
          } finally {
            await ArchiveService.cleanupTempFolder('temp_n64', filePath);
          }
        } else {
          try {
            final archive = ZipDecoder().decodeBytes(bytes);
            romBytes =
                archive
                        .firstWhere(
                          (f) =>
                              f.isFile &&
                              (f.name.endsWith('.z64') ||
                                  f.name.endsWith('.n64') ||
                                  f.name.endsWith('.v64')),
                          orElse: () => archive.firstWhere((f) => f.isFile),
                        )
                        .content
                    as List<int>;
          } catch (_) {}
        }
      }

      if (romBytes.length >= 4) {
        Uint8List hashBytes = Uint8List.fromList(romBytes);
        // Detect ByteSwapped (.v64)
        if (hashBytes[0] == 0x37 && hashBytes[1] == 0x80) {
          for (int i = 0; i < hashBytes.length - 1; i += 2) {
            final temp = hashBytes[i];
            hashBytes[i] = hashBytes[i + 1];
            hashBytes[i + 1] = temp;
          }
          return crypto.md5.convert(hashBytes).toString();
        }
        // Detect Little Endian (.n64)
        else if (hashBytes[0] == 0x40 && hashBytes[1] == 0x12) {
          for (int i = 0; i < hashBytes.length - 3; i += 4) {
            final temp0 = hashBytes[i];
            final temp1 = hashBytes[i + 1];
            hashBytes[i] = hashBytes[i + 3];
            hashBytes[i + 1] = hashBytes[i + 2];
            hashBytes[i + 2] = temp1;
            hashBytes[i + 3] = temp0;
          }
          return crypto.md5.convert(hashBytes).toString();
        }
      }
      return crypto.md5.convert(romBytes).toString();
    } catch (e) {
      _log.e('Error calculating N64 MD5: $e');
      rethrow;
    }
  }

  /// Batch calculates MD5 hashes for multiple files with controlled concurrency.
  static Future<Map<String, String>> calculateFilesMd5(
    List<String> filePaths,
  ) async {
    const int maxConcurrent = 4;
    final results = <String, String>{};
    final semaphore = Semaphore(maxConcurrent);

    final futures = filePaths.map((filePath) async {
      await semaphore.acquire();
      try {
        results[filePath] = await calculateFileMd5(filePath);
      } catch (e) {
        _log.e('Error in batch MD5 for $filePath: $e');
        results[filePath] = '';
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  /// Verifies if a file's MD5 hash matches the expected value.
  static Future<bool> verifyFileMd5(String filePath, String expectedMd5) async {
    try {
      final actualMd5 = await calculateFileMd5(filePath);
      return actualMd5 == expectedMd5;
    } catch (_) {
      return false;
    }
  }
}
