import 'dart:io';
import 'dart:isolate';

import 'package:koni_archive/io.dart';
import 'package:flutter_7zip/flutter_7zip.dart' as f7z;
import 'package:path/path.dart' as p;

import '../utils/safe_path.dart';
import 'logger_service.dart';

/// Installs downloaded 7z/RAR game archives while retaining companion files.
class RommArchiveService {
  /// RomM can stream a folder as ZIP while its list entry has neither an
  /// archive extension nor the multi-file flag. Identify the actual payload
  /// using only its header, so extraction does not depend on that metadata.
  static Future<String> ensureArchiveExtension(String downloadPath) async {
    final input = await File(downloadPath).open();
    final List<int> header;
    try {
      header = await input.read(8);
    } finally {
      await input.close();
    }
    bool startsWith(List<int> signature) =>
        header.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => header[i] == signature[i],
        ).every((matches) => matches);
    final String? extension;
    if (startsWith([0x50, 0x4b, 0x03, 0x04]) ||
        startsWith([0x50, 0x4b, 0x05, 0x06]) ||
        startsWith([0x50, 0x4b, 0x07, 0x08])) {
      extension = '.zip';
    } else if (startsWith([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) {
      extension = '.7z';
    } else if (startsWith([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]) ||
        startsWith([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00])) {
      extension = '.rar';
    } else {
      extension = null;
    }
    if (extension == null ||
        p.extension(downloadPath).toLowerCase() == extension) {
      return downloadPath;
    }
    final target = '$downloadPath$extension';
    await File(downloadPath).rename(target);
    return target;
  }

  /// A self-contained ROM needs no game folder, even inside archive wrappers.
  /// Descriptor files and games with companions retain their relative layout.
  static Future<bool> containsSingleGameFile(
    String archivePath,
    Set<String> extensions,
  ) async {
    final archive = await openArchiveFile(archivePath);
    try {
      final files = archive.entries.where((entry) => entry.isFile).toList();
      if (files.length != 1) return false;
      final ext = p
          .extension(files.single.path)
          .toLowerCase()
          .replaceFirst('.', '');
      return extensions.contains(ext) &&
          !{'m3u', 'cue', 'scummvm'}.contains(ext);
    } finally {
      await archive.close();
    }
  }

  static Future<String?> prepareDownload(
    String archivePath,
    String destDir,
    Set<String> extensions, {
    bool scummVm = false,
    bool flattenSingleFile = false,
  }) async {
    final exts = extensions
        .map((ext) => ext.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .toSet();
    final format = p.extension(archivePath).toLowerCase().substring(1);
    if (!scummVm && exts.contains(format)) return p.basename(archivePath);
    try {
      // Decoding large/solid archives must not block gamepad input or progress UI.
      return await Isolate.run(
        () => _extract(archivePath, destDir, exts, scummVm, flattenSingleFile),
      );
    } catch (e, st) {
      LoggerService.instance.e(
        'RomM archive extraction failed for $archivePath',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  static Future<String?> _extract(
    String archivePath,
    String destDir,
    Set<String> exts,
    bool scummVm,
    bool flattenSingleFile,
  ) async {
    final archive = await openArchiveFile(
      archivePath,
      // Make the 7z decoder's built-in 1 GiB cap a typed size-limit error,
      // so the native fallback below can handle larger solid folders.
      options: p.extension(archivePath).toLowerCase() == '.7z'
          ? const ArchiveReadOptions(maxContainerDecodeSize: 1 << 30)
          : const ArchiveReadOptions(),
    );
    Directory? staging;
    f7z.SZArchive? nativeSevenZ;
    Map<String, int>? nativeIndices;
    try {
      final entries = archive.entries;
      // Inspect the raw index: the VFS view hides duplicate paths.
      final seen = <String>{};
      for (final entry in entries) {
        if (entry.pathEscapedRoot ||
            (!entry.isFile && !entry.isDirectory) ||
            safeJoin(destDir, entry.path) == null ||
            !seen.add(entry.path.toLowerCase())) {
          throw const FormatException('Unsafe or duplicate archive entry');
        }
      }
      final files = entries.where((entry) => entry.isFile).toList();
      final playable = files.where((entry) {
        final ext = p.extension(entry.path).toLowerCase().replaceFirst('.', '');
        return scummVm ? ext == 'scummvm' : exts.contains(ext);
      }).toList();
      if (playable.isEmpty) return null;
      playable.sort((a, b) {
        int priority(ArchiveEntry entry) =>
            switch (p.extension(entry.path).toLowerCase()) {
              '.m3u' => 0,
              '.cue' => 1,
              _ => 2,
            };
        final order = priority(a).compareTo(priority(b));
        return order != 0 ? order : a.path.compareTo(b.path);
      });

      // Verify/decompress the whole download before replacing library files.
      staging = await Directory.systemTemp.createTemp('romm_archive_');
      for (final entry in files) {
        final output = File(safeJoin(staging.path, entry.path)!);
        await output.parent.create(recursive: true);
        if (nativeSevenZ == null) {
          try {
            final sink = output.openWrite();
            try {
              await sink.addStream(archive.openRead(entry));
              await sink.flush();
            } finally {
              await sink.close();
            }
            continue;
          } on SizeLimitExceededException {
            if (p.extension(archivePath).toLowerCase() != '.7z') rethrow;
            // The Dart decoder caps a solid 7z folder at 1 GiB. Use the
            // existing native SDK for large DVD ROMs instead of rejecting them.
            nativeSevenZ = f7z.SZArchive.open(archivePath);
            nativeIndices = {};
            for (var i = 0; i < nativeSevenZ.numFiles; i++) {
              final file = nativeSevenZ.getFile(i);
              if (!file.isDirectory) {
                nativeIndices[normalizeEntryPath(file.name).path] = i;
              }
            }
          }
        }
        final index = nativeIndices![entry.path];
        if (index == null) {
          throw const FormatException('7z entry missing from native index');
        }
        nativeSevenZ.extractToFile(index, output.path);
      }

      var targetDir = destDir;
      var stripWrapper = files.every((entry) {
        final segments = entry.path.split('/');
        return segments.length > 1 && segments.first == p.basename(destDir);
      });
      var indexedName = p.basename(playable.first.path);
      if (scummVm) {
        final descriptor = File(safeJoin(staging.path, playable.first.path)!);
        final id = (await descriptor.readAsString())
            .replaceFirst(RegExp(r'^\uFEFF'), '')
            .trim();
        if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$').hasMatch(id)) {
          return null;
        }
        targetDir = p.join(destDir, id);
        final firstSegments = files
            .map((entry) => entry.path.split('/').first)
            .toSet();
        stripWrapper =
            firstSegments.length == 1 &&
            files.every((entry) => entry.path.contains('/'));
      }
      final outputs = <ArchiveEntry, String>{};
      for (final entry in files) {
        final relative = flattenSingleFile && files.length == 1
            ? p.posix.basename(entry.path)
            : stripWrapper
            ? entry.path.split('/').skip(1).join('/')
            : entry.path;
        final target = safeJoin(targetDir, relative)!;
        await _checkTarget(destDir, target, archivePath);
        outputs[entry] = target;
      }

      String? playlistPath;
      String? playlist;
      if (!scummVm &&
          !flattenSingleFile &&
          exts.contains('m3u') &&
          p.extension(playable.first.path).toLowerCase() != '.m3u') {
        indexedName = '${p.basenameWithoutExtension(archivePath)}.m3u';
        playlistPath = p.join(destDir, indexedName);
        await _checkTarget(destDir, playlistPath, archivePath);
        if (outputs.values.any((target) => p.equals(target, playlistPath!))) {
          return null;
        }
        // Cue sheets already reference their binary tracks. Keep those tracks
        // as companion files rather than adding them as extra playlist discs.
        final hasCue = playable.any(
          (entry) => p.extension(entry.path).toLowerCase() == '.cue',
        );
        final discs = playable.where(
          (entry) => !hasCue || p.extension(entry.path).toLowerCase() != '.bin',
        );
        playlist =
            '${discs.map((entry) => p.relative(outputs[entry]!, from: destDir).replaceAll('\\', '/')).join('\n')}\n';
      }
      for (final entry in files) {
        final target = File(outputs[entry]!);
        await target.parent.create(recursive: true);
        await File(safeJoin(staging.path, entry.path)!).copy(target.path);
      }
      if (playlistPath != null) {
        await Directory(destDir).create(recursive: true);
        await File(playlistPath).writeAsString(playlist!, flush: true);
      }
      await archive.close();
      await File(archivePath).delete();
      return indexedName;
    } finally {
      nativeSevenZ?.dispose();
      await archive.close();
      await staging?.delete(recursive: true);
    }
  }

  static Future<void> _checkTarget(
    String root,
    String target,
    String archivePath,
  ) async {
    if (p.equals(target, archivePath)) {
      throw const FormatException('Archive would overwrite itself');
    }
    var current = target;
    while (p.isWithin(root, current)) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('Archive target contains a symlink');
      }
      current = p.dirname(current);
    }
  }
}
