import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/saf_directory_service.dart';
import 'package:neostation/services/scraped_media_migration_service.dart';

class RomFolderOrganizerResult {
  final int groupsOrganized;
  final int foldersCreated;
  final int filesMoved;
  final int playlistsCreated;
  final int rootsSkipped;
  final int groupsFailed;

  const RomFolderOrganizerResult({
    required this.groupsOrganized,
    required this.foldersCreated,
    required this.filesMoved,
    required this.playlistsCreated,
    required this.rootsSkipped,
    required this.groupsFailed,
  });

  bool get hasChanges =>
      groupsOrganized > 0 || foldersCreated > 0 || filesMoved > 0;

  bool get hasFailures => groupsFailed > 0;
}

class _MutableResult {
  int groupsOrganized = 0;
  int foldersCreated = 0;
  int filesMoved = 0;
  int playlistsCreated = 0;
  int rootsSkipped = 0;
  int groupsFailed = 0;

  RomFolderOrganizerResult freeze() {
    return RomFolderOrganizerResult(
      groupsOrganized: groupsOrganized,
      foldersCreated: foldersCreated,
      filesMoved: filesMoved,
      playlistsCreated: playlistsCreated,
      rootsSkipped: rootsSkipped,
      groupsFailed: groupsFailed,
    );
  }
}

class _DiscFile {
  final File file;
  final int discNumber;

  _DiscFile({required this.file, required this.discNumber});
}

class _SafDirectory {
  final String name;
  final List<Map<String, dynamic>> files;

  _SafDirectory({required this.name, required this.files});
}

class _DiscInfo {
  final String displayBaseName;
  final String normalizedGroupKey;
  final int discNumber;

  _DiscInfo({
    required this.displayBaseName,
    required this.normalizedGroupKey,
    required this.discNumber,
  });
}

class _DiscGroup {
  final String displayBaseName;
  final String normalizedGroupKey;
  final List<_DiscFile> discFiles = [];

  _DiscGroup({required this.displayBaseName, required this.normalizedGroupKey});
}

/// The Storage Access Framework calls the organiser makes, in one place so a
/// test can stand in for Android's document provider.
class OrganizerSaf {
  const OrganizerSaf();

  Future<List<Map<String, dynamic>>> listFiles(String uri) =>
      SafDirectoryService.listFiles(uri);

  Future<bool> hasPermission(String uri) =>
      SafDirectoryService.hasPermission(uri);

  Future<String?> createDirectory(String parentUri, String name) =>
      SafDirectoryService.createDirectory(parentUri, name);

  Future<bool> moveFile(
    String sourceUri,
    String targetDirectoryUri,
    String name,
  ) => SafDirectoryService.moveFile(sourceUri, targetDirectoryUri, name);

  Future<bool> writeTextFile(String parentUri, String name, String contents) =>
      SafDirectoryService.writeTextFile(parentUri, name, contents);
}

class RomFolderOrganizerService {
  static final _log = LoggerService.instance;

  /// Replaceable so a test can organise a fake SAF tree.
  @visibleForTesting
  static OrganizerSaf saf = const OrganizerSaf();

  /// Puts the real [saf] back.
  @visibleForTesting
  static void debugReset() => saf = const OrganizerSaf();

  // Matches common multi-disc markers such as: Disc 1, Disk1, CD 2, (Disc 03)
  static final RegExp _discTokenRegex = RegExp(
    r'(?:^|[\s._\-\(\[])(disc|disk|cd)\s*0*(\d+)(?:[\s._\-\)\]]|$)',
    caseSensitive: false,
  );

  static Future<RomFolderOrganizerResult> organizeRomFolders(
    List<String> romRoots, {
    required Set<String> supportedRomExtensions,
    Set<String>? supportedSystemFolders,
    void Function(int completed, int total)? onProgress,
  }) async {
    final result = _MutableResult();
    final allowedExtensions = supportedRomExtensions
        .map((extension) => extension.toLowerCase().replaceFirst('.', ''))
        .toSet();
    final allowedFolders = supportedSystemFolders
        ?.map((folder) => folder.toLowerCase())
        .toSet();
    final scanRoots = <String>[];

    for (final rootPath in romRoots) {
      if (_isM3uDirectory(rootPath)) continue;
      if (rootPath.startsWith('content://')) {
        // The grant is held on the folder as picked (a tree URI). Check it
        // here: the folders found inside have document URIs, which never
        // match it, and without the grant the listing below comes back empty.
        if (!await saf.hasPermission(rootPath)) {
          result.rootsSkipped++;
          continue;
        }
        if (allowedFolders == null) {
          scanRoots.add(rootPath);
        } else {
          scanRoots.addAll(
            await _getSupportedSafRoots(rootPath, allowedFolders),
          );
        }
        continue;
      }

      final rootDir = Directory(rootPath);
      if (!await rootDir.exists()) {
        result.rootsSkipped++;
        continue;
      }

      if (allowedFolders == null) {
        scanRoots.add(rootPath);
      } else {
        scanRoots.addAll(
          await _getSupportedDirectoryRoots(rootDir, allowedFolders),
        );
      }
    }

    for (var index = 0; index < scanRoots.length; index++) {
      final scanRoot = scanRoots[index];
      if (scanRoot.startsWith('content://')) {
        await _organizeSafRoot(scanRoot, allowedExtensions, result);
      } else {
        await _organizeRoot(Directory(scanRoot), allowedExtensions, result);
      }
      onProgress?.call(index + 1, scanRoots.length);
    }

    return result.freeze();
  }

  static Future<List<String>> _getSupportedDirectoryRoots(
    Directory rootDir,
    Set<String> allowedFolders,
  ) async {
    final roots = <String>[];
    if (allowedFolders.contains(path.basename(rootDir.path).toLowerCase())) {
      roots.add(rootDir.path);
      return roots;
    }

    await for (final entity in rootDir.list(followLinks: false)) {
      if (entity is Directory &&
          allowedFolders.contains(path.basename(entity.path).toLowerCase())) {
        roots.add(entity.path);
      }
    }
    return roots;
  }

  static Future<List<String>> _getSupportedSafRoots(
    String rootUri,
    Set<String> allowedFolders,
  ) async {
    final roots = <String>[];
    final entries = await saf.listFiles(rootUri);
    for (final entry in entries) {
      if (entry['isDirectory'] != true) continue;
      final name = entry['name']?.toString().toLowerCase();
      final uri = entry['uri']?.toString();
      if (name != null && uri != null && allowedFolders.contains(name)) {
        roots.add(uri);
      }
    }
    return roots;
  }

  static Future<void> _organizeRoot(
    Directory rootDir,
    Set<String> allowedExtensions,
    _MutableResult result,
  ) async {
    final filesByDir = <String, List<File>>{};

    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;

      final parent = path.dirname(entity.path);

      // Keep playlist directories and their complete subtrees untouched.
      if (_containsM3uDirectory(parent)) continue;

      filesByDir.putIfAbsent(parent, () => []).add(entity);
    }

    for (final entry in filesByDir.entries) {
      await _organizeDirectory(
        directoryPath: entry.key,
        files: entry.value,
        allowedExtensions: allowedExtensions,
        result: result,
      );
    }
  }

  static Future<void> _organizeDirectory({
    required String directoryPath,
    required List<File> files,
    required Set<String> allowedExtensions,
    required _MutableResult result,
  }) async {
    final groups = <String, _DiscGroup>{};
    final playlistsByGroupKey = <String, File>{};

    for (final file in files) {
      final filename = path.basename(file.path);
      final ext = path.extension(filename).toLowerCase();

      if (ext == '.m3u') {
        final key = _normalizeForGrouping(
          path.basenameWithoutExtension(filename),
        );
        if (key.isNotEmpty) {
          playlistsByGroupKey[key] = file;
        }
        continue;
      }
      if (!_isAllowedRomExtension(filename, allowedExtensions)) continue;

      final discInfo = _extractDiscInfo(filename);
      if (discInfo == null) continue;

      final group = groups.putIfAbsent(
        discInfo.normalizedGroupKey,
        () => _DiscGroup(
          displayBaseName: discInfo.displayBaseName,
          normalizedGroupKey: discInfo.normalizedGroupKey,
        ),
      );

      group.discFiles.add(
        _DiscFile(file: file, discNumber: discInfo.discNumber),
      );
    }

    for (final group in groups.values) {
      // Multi-disc means at least two distinct disc entries.
      final distinctDiscNumbers = group.discFiles
          .map((f) => f.discNumber)
          .toSet();
      if (distinctDiscNumbers.length < 2) continue;

      if (_normalizeForGrouping(path.basename(directoryPath)) ==
          group.normalizedGroupKey) {
        continue;
      }

      final playlistFile = playlistsByGroupKey[group.normalizedGroupKey];
      final folderBaseName = _sanitizeFolderName(
        playlistFile != null
            ? path.basenameWithoutExtension(playlistFile.path)
            : group.displayBaseName,
      );
      final targetFolder = Directory(path.join(directoryPath, folderBaseName));
      final playlistSourcePath = playlistFile?.path;

      if (!await targetFolder.exists()) {
        await targetFolder.create(recursive: true);
        result.foldersCreated++;
      }

      final movedDiscPaths = <String>[];
      final sourceDiscPaths = <String>[];
      final sourceDiscFilenames = <String>[];
      final sortedDiscFiles = [...group.discFiles]
        ..sort((a, b) {
          final discCmp = a.discNumber.compareTo(b.discNumber);
          if (discCmp != 0) return discCmp;
          return path
              .basename(a.file.path)
              .compareTo(path.basename(b.file.path));
        });

      for (final disc in sortedDiscFiles) {
        final sourcePath = disc.file.path;
        final targetPath = path.join(
          targetFolder.path,
          path.basename(sourcePath),
        );
        final sourceNorm = path.normalize(sourcePath);
        final targetNorm = path.normalize(targetPath);

        if (sourceNorm != targetNorm) {
          await _moveFile(sourcePath, targetPath);
          result.filesMoved++;
        }

        sourceDiscPaths.add(sourcePath);
        sourceDiscFilenames.add(path.basename(sourcePath));
        movedDiscPaths.add(targetPath);
      }

      final playlistTargetPath = path.join(
        targetFolder.path,
        '$folderBaseName.m3u',
      );
      if (playlistSourcePath != null) {
        final sourceNorm = path.normalize(playlistSourcePath);
        final targetNorm = path.normalize(playlistTargetPath);
        if (sourceNorm != targetNorm) {
          await _moveFile(playlistSourcePath, playlistTargetPath);
          result.filesMoved++;
        }
      } else {
        result.playlistsCreated++;
      }

      final playlistLines = movedDiscPaths.map(path.basename).toList();
      await File(
        playlistTargetPath,
      ).writeAsString('${playlistLines.join('\n')}\n');
      final metadataTransfer =
          await ScraperRepository.transferMetadataToPlaylist(
            sourceRomPaths: sourceDiscPaths,
            sourceFilenames: sourceDiscFilenames,
            playlistFilename: path.basename(playlistTargetPath),
          );
      if (metadataTransfer != null) {
        final systemFolder = await ScraperRepository.getSystemFolderNameById(
          metadataTransfer.appSystemId,
        );
        if (systemFolder != null) {
          await ScrapedMediaMigrationService.useDiscOneMediaForPlaylist(
            systemFolder: systemFolder,
            discFilenames: sourceDiscFilenames,
            playlistFilename: path.basename(playlistTargetPath),
          );
        }
      }

      result.groupsOrganized++;
    }
  }

  static Future<void> _organizeSafRoot(
    String rootUri,
    Set<String> allowedExtensions,
    _MutableResult result,
  ) async {
    final directories = <String, _SafDirectory>{};

    Future<void> collect(String directoryUri, String directoryName) async {
      if (_isM3uDirectory(directoryName)) return;
      final entries = await saf.listFiles(directoryUri);
      directories[directoryUri] = _SafDirectory(
        name: directoryName,
        files: entries.where((entry) => entry['isDirectory'] != true).toList(),
      );

      for (final entry in entries) {
        if (entry['isDirectory'] == true) {
          final childUri = entry['uri']?.toString();
          if (childUri != null && childUri.isNotEmpty) {
            final childName = entry['name']?.toString() ?? '';
            if (!_isM3uDirectory(childName)) {
              await collect(childUri, childName);
            }
          }
        }
      }
    }

    await collect(rootUri, '');
    for (final entry in directories.entries) {
      await _organizeSafDirectory(
        entry.key,
        entry.value.name,
        entry.value.files,
        allowedExtensions,
        result,
      );
    }
  }

  static Future<void> _organizeSafDirectory(
    String directoryUri,
    String directoryName,
    List<Map<String, dynamic>> entries,
    Set<String> allowedExtensions,
    _MutableResult result,
  ) async {
    final groups = <String, _DiscGroup>{};
    final playlistsByGroupKey = <String, Map<String, dynamic>>{};

    for (final entry in entries) {
      final filename = entry['name']?.toString() ?? '';
      final fileUri = entry['uri']?.toString() ?? '';
      if (filename.isEmpty || fileUri.isEmpty) continue;
      final ext = path.extension(filename).toLowerCase();

      if (ext == '.m3u') {
        final key = _normalizeForGrouping(
          path.basenameWithoutExtension(filename),
        );
        if (key.isNotEmpty) playlistsByGroupKey[key] = entry;
        continue;
      }
      if (!_isAllowedRomExtension(filename, allowedExtensions)) continue;

      final discInfo = _extractDiscInfo(filename);
      if (discInfo == null) continue;
      final group = groups.putIfAbsent(
        discInfo.normalizedGroupKey,
        () => _DiscGroup(
          displayBaseName: discInfo.displayBaseName,
          normalizedGroupKey: discInfo.normalizedGroupKey,
        ),
      );
      group.discFiles.add(
        _DiscFile(file: File(fileUri), discNumber: discInfo.discNumber),
      );
    }

    final directoryEntries = await saf.listFiles(directoryUri);
    for (final group in groups.values) {
      final discNumbers = group.discFiles
          .map((file) => file.discNumber)
          .toSet();
      if (discNumbers.length < 2) continue;
      if (_normalizeForGrouping(directoryName) == group.normalizedGroupKey) {
        continue;
      }

      final playlist = playlistsByGroupKey[group.normalizedGroupKey];
      final folderBaseName = _sanitizeFolderName(
        playlist != null
            ? path.basenameWithoutExtension(playlist['name'].toString())
            : group.displayBaseName,
      );
      final matchingDirectories = directoryEntries
          .where(
            (entry) =>
                entry['isDirectory'] == true && entry['name'] == folderBaseName,
          )
          .map((entry) => entry['uri']?.toString())
          .whereType<String>()
          .toList();
      var targetUri = matchingDirectories.isEmpty
          ? null
          : matchingDirectories.first;
      if (targetUri == null) {
        targetUri = await saf.createDirectory(directoryUri, folderBaseName);
        if (targetUri == null) {
          _log.e('[M3U] Could not create SAF folder for $folderBaseName.');
          result.groupsFailed++;
          continue;
        }
        result.foldersCreated++;
      }

      final sortedDiscFiles = [...group.discFiles]
        ..sort((a, b) => a.discNumber.compareTo(b.discNumber));
      final playlistLines = <String>[];
      final sourceDiscPaths = <String>[];
      final sourceDiscFilenames = <String>[];
      var groupFailed = false;
      for (final disc in sortedDiscFiles) {
        final filename = entries
            .firstWhere(
              (entry) => entry['uri'].toString() == disc.file.path,
            )['name']
            .toString();
        final moved = await saf.moveFile(disc.file.path, targetUri, filename);
        if (!moved) {
          _log.e(
            '[M3U] Stopped organizing $folderBaseName because $filename could not be moved.',
          );
          result.groupsFailed++;
          groupFailed = true;
          break;
        }
        result.filesMoved++;
        sourceDiscPaths.add(disc.file.path);
        sourceDiscFilenames.add(filename);
        playlistLines.add(filename);
      }
      if (groupFailed) continue;

      final playlistName = '$folderBaseName.m3u';
      if (playlist != null) {
        final moved = await saf.moveFile(
          playlist['uri'].toString(),
          targetUri,
          playlistName,
        );
        if (!moved) {
          _log.e(
            '[M3U] Stopped organizing $folderBaseName because its existing playlist could not be moved.',
          );
          result.groupsFailed++;
          continue;
        }
        result.filesMoved++;
      }
      if (await saf.writeTextFile(
        targetUri,
        playlistName,
        '${playlistLines.join('\n')}\n',
      )) {
        if (playlist == null) result.playlistsCreated++;
        final metadataTransfer =
            await ScraperRepository.transferMetadataToPlaylist(
              sourceRomPaths: sourceDiscPaths,
              sourceFilenames: sourceDiscFilenames,
              playlistFilename: playlistName,
            );
        if (metadataTransfer != null) {
          final systemFolder = await ScraperRepository.getSystemFolderNameById(
            metadataTransfer.appSystemId,
          );
          if (systemFolder != null) {
            await ScrapedMediaMigrationService.useDiscOneMediaForPlaylist(
              systemFolder: systemFolder,
              discFilenames: sourceDiscFilenames,
              playlistFilename: playlistName,
            );
          }
        }
        result.groupsOrganized++;
      } else {
        _log.e('[M3U] Could not write playlist $playlistName.');
        result.groupsFailed++;
      }
    }
  }

  static _DiscInfo? _extractDiscInfo(String filename) {
    final stem = path.basenameWithoutExtension(filename);
    final match = _discTokenRegex.firstMatch(stem);
    if (match == null) return null;

    final discNumber = int.tryParse(match.group(2) ?? '');
    if (discNumber == null || discNumber <= 0) return null;

    final before = stem.substring(0, match.start).trim();
    final after = stem.substring(match.end).trim();
    var base = '$before $after'
        .replaceAll(RegExp(r'\(\s*\)'), '')
        .replaceAll(RegExp(r'\[\s*\]'), '')
        .replaceAll(RegExp(r'[\s._\-]{2,}'), ' ')
        .trim();

    if (base.isEmpty) {
      base = stem;
    }

    final groupKey = _normalizeForGrouping(base);
    if (groupKey.isEmpty) return null;

    return _DiscInfo(
      displayBaseName: base,
      normalizedGroupKey: groupKey,
      discNumber: discNumber,
    );
  }

  static bool _isAllowedRomExtension(
    String filename,
    Set<String> allowedExtensions,
  ) {
    final extension = path.extension(filename).toLowerCase();
    return extension.length > 1 &&
        allowedExtensions.contains(extension.substring(1));
  }

  static String _normalizeForGrouping(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();
  }

  static String _sanitizeFolderName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return cleaned.isEmpty ? 'multi_disc_game' : cleaned;
  }

  static bool _isM3uDirectory(String value) {
    return path.basename(value).toLowerCase().endsWith('.m3u');
  }

  static bool _containsM3uDirectory(String value) {
    return path.split(value).any(_isM3uDirectory);
  }

  static Future<void> _moveFile(String sourcePath, String targetPath) async {
    final source = File(sourcePath);
    final target = File(targetPath);

    if (!await source.exists()) return;
    await target.parent.create(recursive: true);

    if (await target.exists()) {
      await target.delete();
    }

    try {
      await source.rename(targetPath);
    } catch (e) {
      // Cross-device moves can fail with rename; copy + delete as fallback.
      _log.w(
        'Rename failed ($sourcePath -> $targetPath), trying copy/delete: $e',
      );
      await source.copy(targetPath);
      await source.delete();
    }
  }
}
