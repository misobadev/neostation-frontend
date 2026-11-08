import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_7zip/flutter_7zip.dart' as f7z;

import 'config_service.dart';
import '../utils/optimized_md5_utils.dart';

import 'package:neostation/services/logger_service.dart';

/// Service responsible for managing compressed archive operations (ZIP, 7z).
///
/// Primarily used to temporarily extract ROM files stored in archives before
/// passing them to emulators that do not support reading from compressed containers.
class ArchiveService {
  static final _log = LoggerService.instance;

  /// Longest single path component most Android and Linux filesystems accept,
  /// in bytes. Not characters: a Japanese ROM title costs three bytes a glyph.
  static const int _maxNameBytes = 255;

  /// Name of the directory that holds one archive's extracted contents.
  ///
  /// On desktop [archivePath] is a filesystem path and its basename is the file
  /// name. On Android it is a SAF `content://` URI, and a SAF document id
  /// encodes every `/` as `%2F` — so there is no separator left for
  /// [path.basename] to split on and it returns the whole encoded id,
  /// `primary%3Aemu%2Froms%2Fgba%2F…`, as the name. The encoding is what makes
  /// that fatal rather than merely ugly: each separator costs three bytes
  /// instead of one and every space becomes `%20`, so a deep folder plus a long
  /// ROM name overruns the 255-byte limit on a single name and the directory
  /// cannot be created at all (errno 36, `File name too long`). The ROM is then
  /// parked as `extract_failed` and never hashed.
  ///
  /// Decoding the id and taking its real basename brings the name back inside
  /// the limit by construction, because the archive itself lives on a
  /// filesystem with the same limit, so its own file name already fits.
  ///
  /// Both callers derive the directory through here so that `extractRom` and
  /// `cleanupTempFolder` cannot disagree about where it is; they each built the
  /// path independently before, which is what let this go unnoticed on one of
  /// them.
  @visibleForTesting
  static String tempDirNameFor(String archivePath) {
    if (!archivePath.startsWith('content://')) {
      // A plain path is already split on real separators. It is also not
      // percent-encoded, so decoding it would corrupt any name holding a
      // literal '%'.
      return _clampToNameLimit(path.basename(archivePath));
    }

    final documentId = archivePath.split('/').last;
    String decoded;
    try {
      decoded = Uri.decodeComponent(documentId);
    } on ArgumentError {
      decoded = documentId;
    }

    // A document id reads like "primary:emu/roms/gba/Game.zip" once decoded,
    // and is always '/'-separated whatever the host platform's style is.
    final name = path.posix.basename(decoded);
    return _clampToNameLimit(name.isEmpty ? documentId : name);
  }

  /// Truncates [name] to [_maxNameBytes] **bytes** without splitting a rune.
  ///
  /// The backstop for the two paths above that can still hand back something
  /// long: an undecodable document id, and a name that is genuinely oversized.
  /// Nothing reads this name back, so losing the tail costs nothing.
  static String _clampToNameLimit(String name) {
    if (utf8.encode(name).length <= _maxNameBytes) return name;

    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in name.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > _maxNameBytes) break;
      buffer.write(char);
      bytes += size;
    }
    return buffer.toString();
  }

  /// Resolves an archive entry's name to a path inside [tempDirPath], or null
  /// if the entry would land anywhere else.
  ///
  /// Entry names come out of the archive, not from us, and [path.join] trusts
  /// them: an absolute name is treated as a complete path and [tempDirPath] is
  /// discarded outright, while a relative one may walk out with `../`. Either
  /// shape lets a crafted ROM archive write to any path the app can reach —
  /// zip slip. No genuine ROM archive names its entries that way, so refusing
  /// the entry costs nothing and the extraction simply reports failure.
  @visibleForTesting
  static String? safeOutputPath(String tempDirPath, String entryName) {
    final root = path.normalize(path.absolute(tempDirPath));
    final resolved = path.normalize(path.join(root, entryName));

    // isWithin is false for the directory itself as well as for anything
    // outside it, which is what we want: an entry must name a file under root.
    return path.isWithin(root, resolved) ? resolved : null;
  }

  /// Extracts a ROM from a ZIP or 7z archive into a temporary system-specific directory.
  ///
  /// The extraction target is located at `user-data/temp/[systemFolderName]/[archiveName]`.
  /// Identifies and returns the path to the largest file within the archive,
  /// which is typically the actual ROM image.
  /// Returns null if extraction fails or no file is found.
  static Future<String?> extractRom(
    String archivePath,
    String systemFolderName,
  ) async {
    try {
      final userDataPath = await ConfigService.getUserDataPath();
      final archiveName = tempDirNameFor(archivePath);
      final extension = path.extension(archivePath).toLowerCase();

      final tempDirPath = path.join(
        userDataPath,
        'temp',
        systemFolderName,
        archiveName,
      );
      final tempDir = Directory(tempDirPath);

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      if (extension == '.7z') {
        return await _extract7z(archivePath, tempDirPath);
      } else {
        return await _extractZip(archivePath, tempDirPath);
      }
    } catch (e) {
      _log.e('Error extracting file $archivePath: $e');
      return null;
    }
  }

  /// Internal logic for 7z extraction using the native 7zip library.
  ///
  /// Handles Scoped Storage (SAF) on Android by copying the archive to a
  /// temporary file if necessary.
  static Future<String?> _extract7z(
    String archivePath,
    String tempDirPath,
  ) async {
    try {
      String pathToExtract = archivePath;
      bool isTempFile = false;

      if (Platform.isAndroid && archivePath.startsWith('content://')) {
        final tempFile = File(path.join(tempDirPath, 'temp_rom.7z'));
        final bytes = await OptimizedMd5Utils.readAllBytes(archivePath);
        await tempFile.writeAsBytes(bytes);
        pathToExtract = tempFile.path;
        isTempFile = true;
      }

      final archive = f7z.SZArchive.open(pathToExtract);
      String? largestFilePath;
      int largestSize = -1;
      int largestIndex = -1;

      for (int i = 0; i < archive.numFiles; i++) {
        final file = archive.getFile(i);
        if (!file.isDirectory) {
          if (file.size > largestSize) {
            largestSize = file.size;
            largestIndex = i;
          }
        }
      }

      if (largestIndex != -1) {
        final file = archive.getFile(largestIndex);
        final outPath = safeOutputPath(tempDirPath, file.name);

        if (outPath == null) {
          // Leaves largestFilePath null, so this returns failure below after
          // the archive and the staged copy have been cleaned up as usual.
          _log.e('Refusing 7z entry outside the temp directory: ${file.name}');
        } else {
          final outFile = File(outPath);
          if (!await outFile.parent.exists()) {
            await outFile.parent.create(recursive: true);
          }

          archive.extractToFile(largestIndex, outPath);
          largestFilePath = outPath;
        }
      }

      archive.dispose();

      if (isTempFile) {
        await File(pathToExtract).delete();
      }

      return largestFilePath;
    } catch (e) {
      _log.e('Error extracting 7z $archivePath: $e');
      return null;
    }
  }

  /// Internal logic for ZIP extraction using the pure Dart [Archive] package.
  ///
  /// Decodes bytes directly to support Scoped Storage (SAF) URI sources.
  static Future<String?> _extractZip(String zipPath, String tempDirPath) async {
    try {
      final bytes = await OptimizedMd5Utils.readAllBytes(zipPath);
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? largestFile;

      for (final file in archive) {
        if (file.isFile) {
          if (largestFile == null || file.size > largestFile.size) {
            largestFile = file;
          }
        }
      }

      if (largestFile != null) {
        final filePath = safeOutputPath(tempDirPath, largestFile.name);
        if (filePath == null) {
          _log.e(
            'Refusing ZIP entry outside the temp directory: '
            '${largestFile.name}',
          );
          return null;
        }

        final outFile = File(filePath);
        await outFile.create(recursive: true);

        await outFile.writeAsBytes(largestFile.content as List<int>);

        return filePath;
      }
      return null;
    } catch (e) {
      _log.e('Error extracting ZIP $zipPath: $e');
      return null;
    }
  }

  /// Recursively deletes the temporary folder created during extraction.
  ///
  /// Should be called after the emulator process terminates to free up disk space.
  static Future<void> cleanupTempFolder(
    String systemFolderName,
    String zipPath,
  ) async {
    try {
      final userDataPath = await ConfigService.getUserDataPath();
      final zipName = tempDirNameFor(zipPath);
      final tempDirPath = path.join(
        userDataPath,
        'temp',
        systemFolderName,
        zipName,
      );
      final tempDir = Directory(tempDirPath);

      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (e) {
      _log.e('Error deleting temp folder: $e');
    }
  }
}
