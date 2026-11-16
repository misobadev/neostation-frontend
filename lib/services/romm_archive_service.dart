import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_7zip/flutter_7zip.dart' as f7z;
import 'package:path/path.dart' as p;

import '../utils/log_redaction.dart';
import '../utils/safe_path.dart';
import 'logger_service.dart';
import 'storage_space_service.dart';

/// An archive refused because its content is hostile, not just damaged or
/// too big: unsafe or duplicate entry paths, links, or entries posing as this
/// service's own bookkeeping. It is deleted rather than kept for extracting by
/// hand, which is the one thing nobody should do with it.
class RommUnsafeArchiveException implements Exception {
  final String message;
  const RommUnsafeArchiveException(this.message);

  @override
  String toString() => 'RommUnsafeArchiveException: $message';
}

/// Why an otherwise sound archive was not installed.
enum RommArchiveRefusal {
  /// Its contents are larger than the free space.
  notEnoughSpace,

  /// It would replace a file that isn't this ROM's.
  conflict,

  /// It is too big to handle safely: too many entries, an absurd declared
  /// size, an oversized playlist or disc descriptor, or a compression method
  /// whose memory use the archive itself controls.
  unsupported,
}

/// An archive that was not installed for a reason the user can act on, or
/// that just isn't supported. Unlike [RommUnsafeArchiveException] the download
/// is kept, so freeing space or moving a file and retrying needs no second
/// download. Thrown out of [RommArchiveService.prepareGameDownload] so the
/// caller can say why.
class RommArchiveRefusedException implements Exception {
  final RommArchiveRefusal reason;
  final String message;
  const RommArchiveRefusedException(this.reason, this.message);

  @override
  String toString() => 'RommArchiveRefusedException: $message';
}

/// Installs downloaded ZIP/7z game archives while retaining companion files.
///
/// ZIP is read with `archive` and 7z with the vendored `flutter_7zip`, the
/// same pair [ArchiveService] uses. RAR is recognised so the download keeps a
/// meaningful name, but only systems that launch `.rar` directly can use one:
/// neither library decodes it.
class RommArchiveService {
  /// RomM can stream a folder as ZIP while its list entry has neither an
  /// archive extension nor the multi-file flag. Identify the actual payload
  /// using only its header, so extraction does not depend on that metadata.
  static Future<String> ensureArchiveExtension(
    String downloadPath, {
    Set<String> extensions = const {},
    bool isMultiFile = false,
  }) async {
    final current = p
        .extension(downloadPath)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!isMultiFile &&
        extensions.any(
          (ext) =>
              ext.toLowerCase().replaceFirst(RegExp(r'^\.'), '') == current,
        )) {
      return downloadPath;
    }
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

  static String gameFolderName(String name) =>
      {'.zip', '.7z', '.rar'}.contains(p.extension(name).toLowerCase())
      ? p.basenameWithoutExtension(name)
      : name;

  static Future<String?> prepareGameDownload(
    String archivePath,
    String systemDir,
    String gameName,
    Set<String> extensions, {
    bool isMultiFile = false,
    bool scummVm = false,
    bool reuseExistingDirectory = false,
    String? playlistName,
    String? replaceRoot,
    Set<String> replaceable = const {},
    int? romId,
  }) async {
    final ext = p.extension(archivePath).toLowerCase();
    if (scummVm) {
      return prepareScummVmDownload(
        archivePath,
        systemDir,
        replaceRoot: replaceRoot,
        romId: romId,
      );
    }
    final folderName = gameFolderName(gameName);
    if (!isSafeFileName(folderName)) return null;
    final exts = extensions
        .map((ext) => ext.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .toSet();
    final forceExtract = ext == '.zip' && isMultiFile && exts.contains('m3u');
    if (exts.contains(ext.replaceFirst('.', '')) && !forceExtract) {
      await File(archivePath)
          .rename(p.join(systemDir, p.basename(archivePath)));
      return p.basename(archivePath);
    }
    return prepareDownload(
      archivePath,
      reuseExistingDirectory ? systemDir : p.join(systemDir, folderName),
      exts,
      // A self-contained ROM needs no game folder, even inside a wrapper.
      singleFileDir: systemDir,
      forceExtract: forceExtract,
      gameName: folderName,
      // A re-download may replace its own bundle folder; anything else only
      // the files recorded for this ROM.
      replaceRoot: replaceRoot,
      replaceable: replaceable,
      romId: romId,
      // A new game folder is never written through a link the user keeps
      // there (to another drive, say). A re-download into the copy found for
      // this ROM is the user's own layout and allowed.
      refuseLinkedDest: !reuseExistingDirectory,
      playlistBaseName:
          playlistName != null && p.extension(playlistName) == '.m3u'
          ? p.basenameWithoutExtension(playlistName)
          : folderName,
    );
  }

  static Future<String?> prepareScummVmDownload(
    String downloadPath,
    String destDir, {
    String? replaceRoot,
    int? romId,
  }) async {
    final ext = p.extension(downloadPath).toLowerCase();
    if ({'.zip', '.7z', '.rar'}.contains(ext)) {
      final result = await prepareDownload(
        downloadPath,
        destDir,
        {'scummvm'},
        scummVm: true,
        replaceRoot: replaceRoot,
        romId: romId,
      );
      // ScummVM never scans an archive, so keeping one "as-is" would report
      // a download that can't be played as a success (the bug #635 fixed).
      return result;
    }
    if (ext == '.scummvm' &&
        await File(downloadPath).length() <= maxDescriptorBytes) {
      final id = (await File(
        downloadPath,
      ).readAsString()).replaceFirst(RegExp(r'^\uFEFF'), '').trim();
      if (RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$').hasMatch(id)) {
        final root = destDir;
        final target = p.join(root, id, p.basename(downloadPath));
        await _checkTarget(root, target, downloadPath);
        // The target folder is this game's only when the copy found for
        // this ROM is there, or its install record names this ROM.
        final folder = p.dirname(target);
        final ours =
            replaceRoot ??
            ((await readInstallRecord(folder)).romId == romId && romId != null
                ? folder
                : null);
        if (await File(target).exists() &&
            !_mayReplace(target, ours, const {}, const {'scummvm'}, const {})) {
          throw const RommArchiveRefusedException(
            RommArchiveRefusal.conflict,
            "it would replace a file that isn't this game's",
          );
        }
        await File(target).parent.create(recursive: true);
        await File(downloadPath).rename(target);
        await _recordInstall(folder, romId, [target]);
        return p.basename(target);
      }
    }
    // A single file the system scans directly (`.scummvm`, `.dpt`) stays
    // usable as it is; anything else would be a game ScummVM can't see.
    if (!{'.scummvm', '.dpt'}.contains(ext)) return null;
    final target = p.join(destDir, p.basename(downloadPath));
    if (!p.equals(target, downloadPath)) {
      if (await File(target).exists() &&
          !_mayReplace(target, replaceRoot, const {}, const {}, const {})) {
        throw const RommArchiveRefusedException(
          RommArchiveRefusal.conflict,
          "it would replace a file that isn't this game's",
        );
      }
      await File(downloadPath).rename(target);
    }
    return p.basename(downloadPath);
  }

  /// Extracts [archivePath] into [destDir] and returns the name to index, or
  /// null when it holds nothing playable or fails verification. When the
  /// archive holds exactly one self-contained game file and [singleFileDir]
  /// is set, that file is installed there directly instead. [gameName] helps
  /// pick a bundle's base game over its updates and DLC.
  static Future<String?> prepareDownload(
    String archivePath,
    String destDir,
    Set<String> extensions, {
    bool scummVm = false,
    String? singleFileDir,
    bool forceExtract = false,
    String? gameName,
    String? playlistBaseName,
    String? replaceRoot,
    Set<String> replaceable = const {},
    bool refuseLinkedDest = false,
    int? romId,
  }) async {
    final exts = extensions
        .map((ext) => ext.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .toSet();
    final format = p.extension(archivePath).toLowerCase().substring(1);
    if (!scummVm && !forceExtract && exts.contains(format)) {
      return p.basename(archivePath);
    }
    if (!_Reader.formats.contains(format)) {
      LoggerService.instance.w(
        'RomM: cannot extract .$format downloads; kept ${oneLine(archivePath)}',
      );
      return null;
    }
    // Measured here: the platform channel behind it only works on the main
    // isolate. Unknown free space (null) applies no limit, like everywhere
    // else in the app.
    final freeBytes =
        debugFreeBytes ??
        await StorageSpaceService.freeSpaceBytes(p.dirname(archivePath));
    // Statics don't cross into the isolate; a test's hook is carried over.
    final installHook = debugInstallHook;
    final entryCap = debugMaxEntries;
    try {
      // Decoding large/solid archives must not block gamepad input or progress UI.
      return await Isolate.run(() {
        debugInstallHook = installHook;
        debugMaxEntries = entryCap;
        return _extract(
          archivePath,
          destDir,
          exts,
          scummVm,
          singleFileDir,
          gameName,
          playlistBaseName,
          freeBytes,
          replaceRoot,
          replaceable,
          refuseLinkedDest,
          romId,
        );
      });
    } on RommArchiveRefusedException catch (e) {
      // Sound, just not installable here: the caller keeps the download and
      // says why.
      LoggerService.instance.w(
        'RomM: did not install ${oneLine(p.basename(archivePath))}: '
        '${e.message}; the download was kept',
      );
      rethrow;
    } on RommUnsafeArchiveException catch (e) {
      // Kept, it would sit in the library "to extract by hand", which is the
      // one thing nobody should do with it.
      LoggerService.instance.w(
        'RomM: refused ${oneLine(p.basename(archivePath))}: ${e.message}; '
        'the download was deleted',
      );
      try {
        await File(archivePath).delete();
      } catch (_) {
        // The caller's download folder is removed anyway.
      }
      return null;
    } catch (e, st) {
      LoggerService.instance.e(
        'RomM archive extraction failed for ${oneLine(archivePath)}',
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
    String? singleFileDir,
    String? gameName,
    String? playlistBaseName,
    int? freeBytes,
    String? replaceRoot,
    Set<String> replaceable,
    bool refuseLinkedDest,
    int? romId,
  ) async {
    final archive = _Reader.open(archivePath);
    Directory? staging;
    var closed = false;
    try {
      // Check the raw entry list: a later duplicate would overwrite an
      // earlier file, and a link entry could point outside the game folder.
      final entries = archive.entries;
      if (entries.length > (debugMaxEntries ?? maxEntries)) {
        throw const RommArchiveRefusedException(
          RommArchiveRefusal.unsupported,
          'it holds too many entries',
        );
      }
      final seen = <String>{};
      final files = <_Entry>[];
      var declaredBytes = 0;
      for (final (index, raw) in entries.indexed) {
        final path = _normalizeEntryPath(raw.name);
        if (raw.isLink ||
            // A NUL ends the path where Dart hands it to the OS, so
            // `.romm_installed\0.bin` would be written as `.romm_installed`.
            raw.name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7F) ||
            path == null ||
            safeJoin(destDir, path) == null ||
            !seen.add(path.toLowerCase()) ||
            // Our own bookkeeping files must only ever be written by us.
            path.split('/').any(_isReservedName)) {
          throw const RommUnsafeArchiveException(
            'unsafe or duplicate archive entry',
          );
        }
        if (raw.unsupportedCompression) {
          throw const RommArchiveRefusedException(
            RommArchiveRefusal.unsupported,
            'it uses ZIP LZMA compression, whose memory use the archive sets',
          );
        }
        if (!raw.isDirectory) {
          // A size read as negative (a ZIP64 or 7z size past 2^63) or past
          // any real disk would slip under the free-space sum below.
          if (raw.size < 0 || raw.size > maxDeclaredBytes) {
            throw const RommArchiveRefusedException(
              RommArchiveRefusal.unsupported,
              'it declares an impossible entry size',
            );
          }
          files.add(_Entry(path, index));
          declaredBytes += raw.size;
        }
      }
      // Checked before anything is decoded: an archive whose contents can't
      // fit on the disk would only fill it. The archive itself is removed
      // after the install, so free space is what the contents can use.
      if (declaredBytes > maxDeclaredBytes ||
          (freeBytes != null && declaredBytes > freeBytes)) {
        throw const RommArchiveRefusedException(
          RommArchiveRefusal.notEnoughSpace,
          'its contents are larger than the free space',
        );
      }
      final playable = files.where((entry) {
        final ext = _ext(entry.path);
        return scummVm ? ext == 'scummvm' : exts.contains(ext);
      }).toList();
      if (playable.isEmpty ||
          (!scummVm && playable.every((entry) => _ext(entry.path) == 'm3u'))) {
        return null;
      }
      playable.sort((a, b) {
        final order = _priority(a.path).compareTo(_priority(b.path));
        return order != 0 ? order : a.path.compareTo(b.path);
      });
      final flattenSingleFile =
          !scummVm &&
          singleFileDir != null &&
          files.length == 1 &&
          playable.length == 1 &&
          !{'m3u', 'cue', 'scummvm'}.contains(_ext(files.single.path));
      if (flattenSingleFile) destDir = singleFileDir;
      if (refuseLinkedDest &&
          !flattenSingleFile &&
          await FileSystemEntity.type(destDir, followLinks: false) ==
              FileSystemEntityType.link) {
        throw const RommArchiveRefusedException(
          RommArchiveRefusal.conflict,
          'its game folder is a link',
        );
      }

      // Verify/decompress the whole download before replacing library files.
      // Stage beside the archive (the download destination), not in the system
      // temp dir: on Android that is internal storage, which can't hold a
      // multi-GB extraction when the ROMs live on an SD card. A hidden folder
      // on the same volume also lets the final step rename instead of copy.
      staging = await Directory(p.dirname(archivePath))
          .createTemp('.romm_archive_');
      // The declared sizes are the server's word. What was really written
      // is counted too, so a size that lies can't fill the disk either.
      var writtenBytes = 0;
      final budget = freeBytes ?? maxDeclaredBytes;
      for (final entry in files) {
        final output = File(safeJoin(staging.path, entry.path)!);
        await output.parent.create(recursive: true);
        await archive.extract(entry.index, output.path);
        writtenBytes += await output.length();
        if (writtenBytes > declaredBytes || writtenBytes > budget) {
          throw const RommArchiveRefusedException(
            RommArchiveRefusal.unsupported,
            'it holds more data than it declares',
          );
        }
      }

      var targetDir = destDir;
      var stripWrapper = files.every((entry) {
        final segments = entry.path.split('/');
        return segments.length > 1 && segments.first == p.basename(destDir);
      });
      // A bundle's launch file is its base game, not an update or DLC that
      // happens to sort first.
      final launch = [...playable]
        ..sort((a, b) => _compareLaunch(a.path, b.path, gameName));
      var indexedName = p.basename(launch.first.path);
      if (scummVm) {
        final descriptor = File(safeJoin(staging.path, playable.first.path)!);
        await _checkDescriptorSize(descriptor);
        final id = (await descriptor.readAsString())
            .replaceFirst(RegExp(r'^﻿'), '')
            .trim();
        if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$').hasMatch(id)) {
          return null;
        }
        indexedName = p.basename(playable.first.path);
        targetDir = p.join(destDir, id);
        final firstSegments = files
            .map((entry) => entry.path.split('/').first)
            .toSet();
        stripWrapper =
            firstSegments.length == 1 &&
            files.every((entry) => entry.path.contains('/'));
      }
      final outputs = <_Entry, String>{};
      for (final entry in files) {
        final relative = flattenSingleFile
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
      if (!scummVm && !flattenSingleFile && exts.contains('m3u')) {
        final companions = await _companions(playable, staging.path);
        final discs =
            playable
                .where(
                  (entry) =>
                      _ext(entry.path) != 'm3u' &&
                      !companions.contains(entry.path.toLowerCase()),
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        String listing(String from) =>
            '${discs.map((entry) => p.relative(outputs[entry]!, from: from).replaceAll('\\', '/')).join('\n')}\n';
        if (_ext(launch.first.path) == 'm3u') {
          // Keep a bundled playlist only while every line still names an
          // installed file; wrapper stripping and absolute paths break it.
          final bundled = launch.first;
          playlistPath = outputs[bundled]!;
          final bundledFile = File(safeJoin(staging.path, bundled.path)!);
          await _checkDescriptorSize(bundledFile);
          final contents = await bundledFile.readAsString();
          playlist =
              _resolvePlaylist(
                contents,
                p.dirname(playlistPath),
                outputs.values.toList(),
              ) ??
              (discs.isEmpty ? null : listing(p.dirname(playlistPath)));
          if (playlist == null) return null;
          if (playlist == contents) playlistPath = null;
        } else {
          indexedName =
              '${playlistBaseName ?? p.basenameWithoutExtension(archivePath)}.m3u';
          playlistPath = p.join(destDir, indexedName);
          await _checkTarget(destDir, playlistPath, archivePath);
          if (outputs.values.any((target) => p.equals(target, playlistPath!))) {
            return null;
          }
          playlist = listing(destDir);
        }
      }
      // Close once before committing, so reader failures cannot leave a
      // successfully installed game reported as failed.
      closed = true;
      archive.close();
      final stagedOutputs = <String, String>{
        for (final entry in files)
          outputs[entry]!: safeJoin(staging.path, entry.path)!,
      };
      if (playlistPath != null) {
        final generated = await Directory(staging.path)
            .createTemp('.playlist_');
        final stagedPlaylist = p.join(generated.path, 'playlist');
        await File(stagedPlaylist).writeAsString(playlist!, flush: true);
        stagedOutputs[playlistPath] = stagedPlaylist;
      }
      // The game's own folder, when it has one: a bundle's folder or a
      // ScummVM target folder, never the system folder itself. Files left in
      // it by an earlier install of this ROM (discs after the playlist was
      // deleted, say) may be replaced; see [_mayReplace].
      final gameFolder = scummVm
          ? targetDir
          : (flattenSingleFile ||
                (singleFileDir != null && p.equals(destDir, singleFileDir)))
          ? null
          : destDir;
      // A folder that merely has this game's name may be another ROM's or
      // the user's own: it only counts as this ROM's when its install
      // record says so.
      final recordedHere =
          romId != null &&
          gameFolder != null &&
          await FileSystemEntity.type(gameFolder, followLinks: false) ==
              FileSystemEntityType.directory &&
          (await readInstallRecord(gameFolder)).romId == romId;
      await _install(
        stagedOutputs,
        staging.path,
        destDir,
        archivePath,
        replaceRoot: replaceRoot ?? (recordedHere ? gameFolder : null),
        replaceable: replaceable,
        claimedExtensions: scummVm ? const {'scummvm', 'dpt'} : exts,
        // A re-download into the bundle found for this ROM records there
        // too, so its new files are known next time.
        recordDir: gameFolder ?? replaceRoot,
        romId: romId,
      );
      return indexedName;
    } finally {
      if (!closed) archive.close();
      await staging?.delete(recursive: true);
    }
  }

  static String _ext(String path) =>
      p.extension(path).toLowerCase().replaceFirst('.', '');

  /// Playlists first, then disc descriptors, then everything else.
  static int _priority(String path) => switch (_ext(path)) {
    'm3u' => 0,
    'cue' || 'ccd' || 'gdi' || 'mds' || 'toc' => 1,
    _ => 2,
  };

  static final _addOnFolder = RegExp(
    r'^(dlcs?|updates?|patch(es)?|add-?ons?)$',
    caseSensitive: false,
  );
  static final _addOnTag = RegExp(
    r'[\[(](dlc|upd|update|patch)[\])]|\[v(?!0\])\d+\]',
    caseSensitive: false,
  );

  /// Orders a bundle's playable entries so the base game comes first:
  /// playlists/descriptors, then entries outside DLC/update folders and
  /// without update tags, then names matching [gameName], then shallower
  /// paths.
  static int _compareLaunch(String a, String b, String? gameName) {
    int addOn(String path) {
      final segments = path.split('/');
      return segments.take(segments.length - 1).any(_addOnFolder.hasMatch) ||
              _addOnTag.hasMatch(segments.last)
          ? 1
          : 0;
    }

    int named(String path) {
      if (gameName == null || gameName.isEmpty) return 0;
      final stem = p.posix.basenameWithoutExtension(path).toLowerCase();
      return stem.startsWith(gameName.toLowerCase()) ? 0 : 1;
    }

    for (final order in [
      _priority(a).compareTo(_priority(b)),
      addOn(a).compareTo(addOn(b)),
      named(a).compareTo(named(b)),
      a.split('/').length.compareTo(b.split('/').length),
    ]) {
      if (order != 0) return order;
    }
    return a.compareTo(b);
  }

  /// Lower-cased archive paths of the data files each disc descriptor
  /// references, so they are not listed as discs of their own. An ISO
  /// belonging to another disc stays in a mixed-format playlist.
  static Future<Set<String>> _companions(
    List<_Entry> playable,
    String staging,
  ) async {
    final companions = <String>{};
    void add(_Entry descriptor, String name) => companions.add(
      p.posix
          .normalize(
            p.posix.join(
              p.posix.dirname(descriptor.path),
              name.replaceAll('\\', '/'),
            ),
          )
          .toLowerCase(),
    );
    for (final entry in playable) {
      final stem = p.posix.withoutExtension(entry.path).toLowerCase();
      final RegExp references;
      switch (_ext(entry.path)) {
        case 'ccd':
          companions.addAll({'$stem.img', '$stem.sub'});
          continue;
        case 'mds':
          companions.add('$stem.mdf');
          continue;
        case 'cue' || 'toc':
          references = RegExp(
            r'^\s*(?:FILE|DATAFILE|AUDIOFILE)\s+(?:"([^"]+)"|([^\s]+))',
            caseSensitive: false,
            multiLine: true,
          );
        case 'gdi':
          // `track lba type sector-size file offset`; the first line is the
          // track count and has no file field.
          references = RegExp(
            r'^[ \t]*\d+[ \t]+\d+[ \t]+\d+[ \t]+\d+[ \t]+(?:"([^"]+)"|(\S+))',
            multiLine: true,
          );
        default:
          continue;
      }
      final descriptorFile = File(safeJoin(staging, entry.path)!);
      await _checkDescriptorSize(descriptorFile);
      final descriptor = await descriptorFile.readAsString();
      for (final reference in references.allMatches(descriptor)) {
        add(entry, reference.group(1) ?? reference.group(2)!);
      }
    }
    return companions;
  }

  /// [contents] with every entry pointing at one of [installed], relative to
  /// [playlistDir]; null when an entry matches no installed file. Entries
  /// that only match by basename (wrapper-prefixed or absolute) are
  /// rewritten.
  static String? _resolvePlaylist(
    String contents,
    String playlistDir,
    List<String> installed,
  ) {
    final lines = <String>[];
    var entries = 0;
    for (final raw
        in contents.replaceFirst(RegExp(r'^﻿'), '').split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) {
        lines.add(raw);
        continue;
      }
      entries++;
      final reference = line.replaceAll('\\', '/');
      final absolute =
          reference.startsWith('/') ||
          RegExp(r'^[A-Za-z]:/').hasMatch(reference);
      if (!absolute &&
          installed.any(
            (path) => p.equals(path, p.join(playlistDir, reference)),
          )) {
        lines.add(raw);
        continue;
      }
      final name = p.posix.basename(reference).toLowerCase();
      final matches = installed
          .where((path) => p.basename(path).toLowerCase() == name)
          .toList();
      if (matches.length != 1) return null;
      lines.add(
        p.relative(matches.single, from: playlistDir).replaceAll('\\', '/'),
      );
    }
    if (entries == 0) return null;
    final resolved = lines.join('\n');
    return contents.endsWith('\n') || resolved.endsWith('\n')
        ? resolved
        : '$resolved\n';
  }

  /// Roll back replacements if any install operation fails. The archive is
  /// consumed only after every output has been installed successfully.
  static Future<void> _install(
    Map<String, String> outputs,
    String staging,
    String root,
    String archivePath, {
    String? replaceRoot,
    Set<String> replaceable = const {},
    Set<String> claimedExtensions = const {},
    String? recordDir,
    int? romId,
  }) async {
    // Read once: a folder game can have thousands of files to check. Only a
    // record naming this ROM counts.
    final record = replaceRoot == null
        ? const InstallRecord(null, {})
        : await readInstallRecord(replaceRoot);
    final recorded = romId != null && record.romId == romId
        ? record.paths
        : const <String>{};
    // Checked for every file before anything moves: a server-chosen name must
    // not replace another game's files, whose backups would only live in
    // staging and be deleted with it.
    for (final target in outputs.keys) {
      if (await File(target).exists() &&
          !_mayReplace(
            target,
            replaceRoot,
            replaceable,
            claimedExtensions,
            recorded,
          )) {
        throw RommArchiveRefusedException(
          RommArchiveRefusal.conflict,
          "it would replace ${oneLine(p.basename(target))}, which isn't "
          "this game's",
        );
      }
    }
    final backups = <String, String>{};
    final installed = <String>[];
    final createdDirs = <String>[];
    final backupDir = await Directory(staging).createTemp('.backups_');
    try {
      for (final output in outputs.entries) {
        await _checkTarget(root, output.key, archivePath);
        final target = File(output.key);
        var parent = target.parent;
        final missing = <String>[];
        while (!await parent.exists()) {
          missing.add(parent.path);
          parent = parent.parent;
        }
        for (final path in missing.reversed) {
          await Directory(path).create();
          createdDirs.add(path);
        }
        if (await target.exists()) {
          final backup = p.join(backupDir.path, '${backups.length}');
          await target.rename(backup);
          backups[output.key] = backup;
        }
        await debugInstallHook?.call('rename', output.key);
        await File(output.value).rename(output.key);
        installed.add(output.key);
      }
    } catch (_) {
      // Each step is attempted on its own: one file that can't be put back
      // must not stop the rest of the backups being restored before the
      // caller deletes staging (and the backups inside it).
      Future<void> attempt(Future<void> Function() step) async {
        try {
          await step();
        } catch (e) {
          LoggerService.instance.w(
            'RomM: install rollback step failed: ${oneLine('$e')}',
          );
        }
      }

      for (final path in installed.reversed) {
        await attempt(() => File(path).delete());
      }
      for (final backup in backups.entries) {
        try {
          await File(backup.value).rename(backup.key);
        } catch (e) {
          // Staging is about to be deleted, so park the original beside its
          // old place rather than lose it.
          LoggerService.instance.w(
            'RomM: could not restore a backup: ${oneLine('$e')}',
          );
          await attempt(
            () => File(backup.value).rename('${backup.key}.romm-backup'),
          );
        }
      }
      for (final path in createdDirs.reversed) {
        await attempt(() => Directory(path).delete());
      }
      rethrow;
    }
    // The game is installed. Removing the archive is cleanup: a locked file
    // (Windows antivirus, say) must not roll back a complete install. The
    // caller's download folder sweep retries it.
    // Recorded so a later download of this ROM may replace exactly these
    // files, whatever their format, and nothing else in the folder.
    if (recordDir != null) {
      await _recordInstall(recordDir, romId, outputs.keys);
    }
    try {
      await debugInstallHook?.call('deleteArchive', archivePath);
      await File(archivePath).delete();
    } catch (e) {
      LoggerService.instance.w(
        'RomM: could not remove the installed archive: ${oneLine('$e')}',
      );
    }
  }

  /// Name of the file, in a game's own folder, recording which RomM ROM
  /// installed there and what it wrote: a `# romm-rom-id: <id>` line, then
  /// relative `/` paths, one per line.
  static const manifestName = '.romm_installed';

  static const _recordIdPrefix = '# romm-rom-id: ';

  /// Largest install record that is read. A folder game of 250,000 files
  /// with long paths stays under it.
  static const maxRecordBytes = 64 << 20;

  /// Whether an archive entry's path [segment] names one of this service's
  /// own files (`.romm_installed`, `.romm_download_*`), as Windows would
  /// resolve it: trailing dots and spaces dropped, a `:stream` suffix
  /// ignored.
  static bool _isReservedName(String segment) {
    final colon = segment.indexOf(':');
    final name = (colon < 0 ? segment : segment.substring(0, colon))
        .replaceFirst(RegExp(r'[. ]+$'), '')
        .toLowerCase();
    return name.startsWith('.romm_');
  }

  /// The install record in [dir], or an empty one when there is none, it
  /// isn't a plain file, or it is too big to be real.
  @visibleForTesting
  static Future<InstallRecord> readInstallRecord(String dir) async {
    final file = File(p.join(dir, manifestName));
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > maxRecordBytes) {
        return const InstallRecord(null, {});
      }
      int? romId;
      final paths = <String>{};
      for (final raw in await file.readAsLines()) {
        final line = raw.trim();
        if (line.startsWith(_recordIdPrefix)) {
          romId ??= int.tryParse(line.substring(_recordIdPrefix.length));
        } else if (line.isNotEmpty && !line.startsWith('#')) {
          paths.add(line.toLowerCase());
        }
      }
      return InstallRecord(romId, paths);
    } catch (_) {
      return const InstallRecord(null, {});
    }
  }

  /// Adds [targets] inside [dir] to its install record for [romId]. A
  /// record another ROM wrote is left alone: this install didn't make the
  /// folder ours.
  static Future<void> _recordInstall(
    String dir,
    int? romId,
    Iterable<String> targets,
  ) async {
    if (romId == null) return;
    try {
      final existing = await readInstallRecord(dir);
      if (existing.romId != null && existing.romId != romId) return;
      final relative = {
        if (existing.romId == romId) ...existing.paths,
        for (final target in targets)
          if (p.isWithin(dir, target))
            p.relative(target, from: dir).replaceAll('\\', '/'),
      }.toList()..sort();
      await File(p.join(dir, manifestName)).writeAsString(
        '$_recordIdPrefix$romId\n${relative.join('\n')}\n',
        flush: true,
      );
    } catch (e) {
      LoggerService.instance.w(
        'RomM: could not record installed files: ${oneLine('$e')}',
      );
    }
  }

  /// Largest playlist or disc descriptor (`.m3u`, `.cue`, `.gdi`, `.toc`,
  /// `.scummvm`) that is read into memory. Real ones are a few KB.
  static const maxDescriptorBytes = 1 << 20;

  /// No real game declares more than this (4 TiB), and no disk holds it.
  static const maxDeclaredBytes = 1 << 42;

  static Future<void> _checkDescriptorSize(File file) async {
    if (await file.length() > maxDescriptorBytes) {
      throw const RommArchiveRefusedException(
        RommArchiveRefusal.unsupported,
        'it holds an oversized playlist or disc descriptor',
      );
    }
  }

  /// A lower entry cap, for tests: a real-size archive takes too long to build.
  @visibleForTesting
  static int? debugMaxEntries;

  /// Free bytes to assume instead of measuring, for tests.
  @visibleForTesting
  static int? debugFreeBytes;

  /// Called before each install step (`rename` of an output, `deleteArchive`),
  /// for tests that need a step to fail.
  @visibleForTesting
  static Future<void> Function(String step, String path)? debugInstallHook;

  /// Most entries an archive may hold. Folder games with every file loose
  /// (Wii U, PS3, PC) run to tens of thousands; a bomb of empty entries is
  /// millions.
  static const maxEntries = 250000;

  /// Whether an existing file at [target] may be replaced: a path in
  /// [replaceable] (the files recorded for this ROM), or, inside
  /// [replaceRoot] (this ROM's own folder), a file in a format the system
  /// launches or one in [recorded] (what this ROM's install record lists).
  /// Other files there (memory cards, saves, the user's notes) are left
  /// alone.
  static bool _mayReplace(
    String target,
    String? replaceRoot,
    Set<String> replaceable,
    Set<String> claimedExtensions,
    Set<String> recorded,
  ) {
    if (replaceable.any((path) => p.equals(path, target))) return true;
    if (replaceRoot == null || !p.isWithin(replaceRoot, target)) return false;
    if (claimedExtensions.contains(_ext(target))) return true;
    final relative = p
        .relative(target, from: replaceRoot)
        .replaceAll('\\', '/')
        .toLowerCase();
    return recorded.contains(relative);
  }

  static Future<void> _checkTarget(
    String root,
    String target,
    String archivePath,
  ) async {
    if (p.equals(target, archivePath)) {
      throw const FormatException('Archive would overwrite itself');
    }
    if (await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.directory) {
      throw const FormatException('Archive target is a directory');
    }
    // Only links below [root] can come from archive entries. The root and its
    // parents are the user's own layout: EmuDeck links `roms/gc` to
    // `roms/gamecube`, and libraries are often linked to another drive.
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

/// [name] as a `/`-separated relative path without empty or `.` segments,
/// or null when nothing is left. Containment is checked by `safeJoin`.
String? _normalizeEntryPath(String name) {
  final segments = name
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.');
  return segments.isEmpty ? null : segments.join('/');
}

/// A file entry, by its normalised path and its index in [_Reader.entries].
class _Entry {
  final String path;
  final int index;
  const _Entry(this.path, this.index);
}

/// An archive's raw entry list, duplicates included, and extraction by index.
abstract class _Reader {
  static const formats = {'zip', '7z'};

  List<
    ({
      String name,
      bool isDirectory,
      bool isLink,
      int size,
      bool unsupportedCompression,
    })
  >
  get entries;

  /// Writes entry [index] to [outputPath], failing on a checksum mismatch.
  Future<void> extract(int index, String outputPath);

  void close();

  static _Reader open(String archivePath) =>
      switch (p.extension(archivePath).toLowerCase()) {
        '.zip' => _ZipReader(archivePath),
        '.7z' => _SevenZipReader(archivePath),
        final ext => throw UnsupportedError('No reader for $ext archives'),
      };
}

class _ZipReader implements _Reader {
  final InputFileStream _input;
  final _files = <ArchiveFile>[];

  /// Central-directory CRC per entry of [_files], in the same order.
  final _centralCrcs = <int>[];

  _ZipReader(String path) : _input = InputFileStream(path) {
    try {
      // The decoder's own list keeps one entry per name; its callback sees
      // every header, so a duplicate shows up here twice.
      final decoder = ZipDecoder();
      // `verify` checks each entry's CRC and size while it streams, and
      // refuses a size the output exceeds.
      decoder.decodeStream(_input, verify: true, callback: _files.add);
      _centralCrcs.addAll(
        decoder.directory.fileHeaders.map((header) => header.crc32),
      );
      if (_centralCrcs.length != _files.length) {
        throw const FormatException('ZIP index does not match its entries');
      }
    } catch (_) {
      _input.closeSync();
      rethrow;
    }
  }

  @override
  List<
    ({
      String name,
      bool isDirectory,
      bool isLink,
      int size,
      bool unsupportedCompression,
    })
  >
  get entries => [
    for (final file in _files)
      (
        name: file.name,
        isDirectory: !file.isFile && !file.isSymbolicLink,
        isLink: file.isSymbolicLink,
        size: file.size,
        // LZMA takes its dictionary size from the entry's header, and
        // `archive` allocates it as asked: a few hundred KB can claim GBs.
        unsupportedCompression: file.compression == CompressionType.lzma,
      ),
  ];

  @override
  Future<void> extract(int index, String outputPath) async {
    final file = _files[index];
    final output = OutputFileStream(outputPath);
    try {
      // Streams the inflate straight to disk; a multi-GB disc never sits in
      // memory whole.
      file.writeContent(output);
    } finally {
      output.closeSync();
    }
    // The data's CRC was checked while it streamed (`verify: true`). The
    // local and central headers must also agree: a mismatch between them is
    // a damaged archive even when the data matches one.
    if (file.crc32 != null && file.crc32 != _centralCrcs[index]) {
      throw FormatException('CRC mismatch for ${oneLine(file.name)}');
    }
  }

  @override
  void close() => _input.closeSync();
}

/// 7z through the native LZMA SDK, which checks each file's CRC itself. It
/// decodes a whole solid folder into memory, as [ArchiveService] already
/// does for 7z ROMs.
class _SevenZipReader implements _Reader {
  final f7z.SZArchive _archive;

  _SevenZipReader(String path) : _archive = f7z.SZArchive.open(path);

  @override
  List<
    ({
      String name,
      bool isDirectory,
      bool isLink,
      int size,
      bool unsupportedCompression,
    })
  >
  get entries => [
    for (var i = 0; i < _archive.numFiles; i++)
      (() {
        final file = _archive.getFile(i);
        return (
          name: file.name,
          isDirectory: file.isDirectory,
          isLink: false,
          size: file.size,
          unsupportedCompression: false,
        );
      })(),
  ];

  @override
  Future<void> extract(int index, String outputPath) async =>
      _archive.extractToFile(index, outputPath);

  @override
  void close() => _archive.dispose();
}

/// What [RommArchiveService.manifestName] in a game folder says: the RomM
/// ROM that installed there (null when unrecorded) and the lower-cased
/// relative paths it wrote.
@immutable
class InstallRecord {
  final int? romId;
  final Set<String> paths;
  const InstallRecord(this.romId, this.paths);
}
