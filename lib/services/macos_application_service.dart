import 'dart:io';

import 'package:path/path.dart' as path;

/// Resolves macOS application bundles to the executable stored inside them.
///
/// Emulator configuration commonly deals in `.app` bundles, while
/// [Process.start] requires the bundle's `Contents/MacOS` executable.
class MacOsApplicationService {
  MacOsApplicationService._();

  static const _applicationCacheLifetime = Duration(seconds: 2);
  static Future<List<_InstalledApplication>>? _applicationCache;
  static DateTime? _applicationCacheUpdatedAt;

  static Future<String?> resolveExecutable(
    String configuredPath, {
    String? applicationName,
    String? bundleIdentifierHint,
    String? homePath,
    List<String>? applicationRoots,
  }) async {
    final value = configuredPath.trim();
    if (value.isEmpty) return null;

    final expandedPath = _expandHome(value, homePath);
    final file = File(expandedPath);
    if (await file.exists()) return file.path;

    final directory = Directory(expandedPath);
    if (await directory.exists() &&
        path.extension(expandedPath).toLowerCase() == '.app') {
      return _resolveBundleExecutable(directory);
    }

    // A missing absolute/relative path is not an application name to search.
    if (path.isAbsolute(expandedPath) ||
        expandedPath.contains('/') ||
        expandedPath.contains(r'\')) {
      return null;
    }

    return findInstalledApplication(
      applicationNames: [?applicationName, configuredPath],
      bundleIdentifierHint: bundleIdentifierHint,
      homePath: homePath,
      applicationRoots: applicationRoots,
    );
  }

  /// Finds the application bundle containing an executable resolved from a
  /// `.app` path. Launch Services needs the bundle rather than its inner
  /// `Contents/MacOS` binary.
  ///
  /// Expects the absolute executable path returned by [resolveExecutable]: a
  /// bare name has no parent to walk up to, so it returns null.
  static String? bundlePathForExecutable(String executablePath) {
    var current = Directory(executablePath).parent;
    while (current.path != current.parent.path) {
      if (path.extension(current.path).toLowerCase() == '.app') {
        return current.path;
      }
      current = current.parent;
    }
    return null;
  }

  static Future<String?> findInstalledApplication({
    required List<String> applicationNames,
    String? bundleIdentifierHint,
    String? homePath,
    List<String>? applicationRoots,
  }) async {
    final names = applicationNames
        .map(_normalizedApplicationName)
        .where((name) => name.isNotEmpty)
        .toSet();
    if (names.isEmpty && bundleIdentifierHint == null) return null;

    final resolvedHome = homePath ?? Platform.environment['HOME'] ?? '';
    final roots =
        applicationRoots ??
        <String>[
          '/Applications',
          '/System/Applications',
          if (resolvedHome.isNotEmpty) path.join(resolvedHome, 'Applications'),
        ];

    final applications = await _installedApplications(
      roots,
      cache: applicationRoots == null,
    );
    for (final application in applications) {
      final identifierMatches =
          bundleIdentifierHint != null &&
          application.bundleIdentifier != null &&
          bundleIdentifierHint.toLowerCase().contains(
            application.bundleIdentifier!.toLowerCase(),
          );

      if (identifierMatches ||
          names.contains(application.bundleName) ||
          names.contains(application.executableName)) {
        return application.executablePath;
      }
    }

    return null;
  }

  static Future<List<_InstalledApplication>> _installedApplications(
    List<String> roots, {
    required bool cache,
  }) {
    final cached = _applicationCache;
    final cacheUpdatedAt = _applicationCacheUpdatedAt;
    if (cache &&
        cached != null &&
        (cacheUpdatedAt == null ||
            DateTime.now().difference(cacheUpdatedAt) <
                _applicationCacheLifetime)) {
      return cached;
    }

    final scan = _scanInstalledApplications(roots);
    if (!cache) return scan;
    _applicationCache = scan.then((applications) {
      _applicationCacheUpdatedAt = DateTime.now();
      return applications;
    });
    return _applicationCache!;
  }

  static Future<List<_InstalledApplication>> _scanInstalledApplications(
    List<String> roots,
  ) async {
    final applications = <_InstalledApplication>[];
    for (final root in roots) {
      final directory = Directory(root);
      if (!await directory.exists()) continue;

      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } on FileSystemException {
        continue;
      }

      for (final entry in entries.whereType<Directory>()) {
        if (path.extension(entry.path).toLowerCase() != '.app') continue;

        final metadata = await _readBundleMetadata(entry);
        final bundleName = _normalizedApplicationName(
          path.basenameWithoutExtension(entry.path),
        );
        final executableName = _normalizedApplicationName(
          metadata.executableName ?? '',
        );
        final executable = await _resolveBundleExecutable(
          entry,
          executableName: metadata.executableName,
        );
        if (executable == null) continue;
        applications.add(
          _InstalledApplication(
            bundleName: bundleName,
            executableName: executableName,
            bundleIdentifier: metadata.bundleIdentifier,
            executablePath: executable,
          ),
        );
      }
    }
    return applications;
  }

  static Future<String?> _resolveBundleExecutable(
    Directory bundle, {
    String? executableName,
  }) async {
    final macOsDirectory = Directory(
      path.join(bundle.path, 'Contents', 'MacOS'),
    );
    if (!await macOsDirectory.exists()) return null;

    final metadata = executableName == null
        ? await _readBundleMetadata(bundle)
        : null;
    final declaredName = executableName ?? metadata?.executableName;
    if (declaredName != null && declaredName.isNotEmpty) {
      final declaredExecutable = File(
        path.join(macOsDirectory.path, declaredName),
      );
      if (await declaredExecutable.exists()) return declaredExecutable.path;
    }

    final bundleName = _normalizedApplicationName(
      path.basenameWithoutExtension(bundle.path),
    );
    final files = await macOsDirectory.list(followLinks: false).toList();
    final executables = files.whereType<File>().toList();
    for (final candidate in executables) {
      if (_normalizedApplicationName(path.basename(candidate.path)) ==
          bundleName) {
        return candidate.path;
      }
    }

    // Well-formed emulator bundles normally contain one top-level launcher.
    return executables.length == 1 ? executables.single.path : null;
  }

  static Future<_BundleMetadata> _readBundleMetadata(Directory bundle) async {
    final plist = File(path.join(bundle.path, 'Contents', 'Info.plist'));
    if (!await plist.exists()) return const _BundleMetadata();

    try {
      final contents = await plist.readAsString();
      final metadata = _BundleMetadata(
        executableName: _readXmlPlistString(contents, 'CFBundleExecutable'),
        bundleIdentifier: _readXmlPlistString(contents, 'CFBundleIdentifier'),
      );
      if (metadata.executableName != null ||
          metadata.bundleIdentifier != null) {
        return metadata;
      }
    } on FileSystemException {
      return const _BundleMetadata();
    } on FormatException {
      // Binary plists are handled by plutil below on macOS.
    }

    if (!Platform.isMacOS || !File('/usr/bin/plutil').existsSync()) {
      return const _BundleMetadata();
    }
    return _BundleMetadata(
      executableName: await _readPlistValue(plist.path, 'CFBundleExecutable'),
      bundleIdentifier: await _readPlistValue(plist.path, 'CFBundleIdentifier'),
    );
  }

  static Future<String?> _readPlistValue(String plistPath, String key) async {
    try {
      final result = await Process.run('/usr/bin/plutil', [
        '-extract',
        key,
        'raw',
        '-o',
        '-',
        plistPath,
      ]);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
    } on ProcessException {
      return null;
    }
  }

  static String? _readXmlPlistString(String contents, String key) {
    final match = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]+)</string>',
      caseSensitive: false,
    ).firstMatch(contents);
    return match?.group(1)?.trim();
  }

  static String _expandHome(String value, String? homePath) {
    if (value != '~' && !value.startsWith('~/')) return value;
    final home = homePath ?? Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return value;
    return value == '~' ? home : path.join(home, value.substring(2));
  }

  static String _normalizedApplicationName(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\b(standalone|emulator|application|app)\b'), '')
      .replaceAll(RegExp('[^a-z0-9]'), '');
}

class _BundleMetadata {
  final String? executableName;
  final String? bundleIdentifier;

  const _BundleMetadata({this.executableName, this.bundleIdentifier});
}

class _InstalledApplication {
  final String bundleName;
  final String executableName;
  final String? bundleIdentifier;
  final String executablePath;

  const _InstalledApplication({
    required this.bundleName,
    required this.executableName,
    required this.bundleIdentifier,
    required this.executablePath,
  });
}
