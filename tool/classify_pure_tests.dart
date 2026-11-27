import 'dart:io';

/// Lists test files whose production imports are Flutter-free, so they can move
/// to `test_pure/` and run with `dart test`.
///
/// Usage:
///   dart tool/classify_pure_tests.dart
///
/// The list is conservative: a test is only reported when every import it
/// reaches (test helpers included) avoids Flutter, dart:ui and plugin packages.
void main() {
  final testFiles =
      Directory('test')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('_test.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final candidates = <String>[];
  for (final file in testFiles) {
    if (_isPureTest(file)) candidates.add(file.path);
  }

  for (final candidate in candidates) {
    stdout.writeln(candidate);
  }
  stderr.writeln('${candidates.length} pure candidates of ${testFiles.length}');
}

const _flutterMarkers = <String>[
  'testWidgets(',
  'TestWidgetsFlutterBinding',
  'WidgetTester',
  'TestDefaultBinaryMessenger',
  'SharedPreferences',
  'MethodChannel',
  'rootBundle',
  'AssetImage',
  'Image.asset',
  'pumpWidget',
  'tester.',
  'FlutterLocalization',
  'ScreenUtilInit',
  'findsOneWidget',
  'findsNothing',
  'findsWidgets',
  'find.by',
];

const _purePackages = <String>{
  'args',
  'async',
  'audio_metadata_reader',
  'boolean_selector',
  'clock',
  'collection',
  'convert',
  'crypto',
  'csslib',
  'fake_async',
  'ffi',
  'file',
  'glob',
  'html',
  'http',
  'http_parser',
  'intl',
  'logger',
  'matcher',
  'meta',
  'mime',
  'mocktail',
  'package_config',
  'path',
  'petitparser',
  'platform',
  'pointycastle',
  'posix',
  'process',
  'pub_semver',
  'source_span',
  'sqlite3',
  'stack_trace',
  'stream_channel',
  'string_scanner',
  'term_glyph',
  'test',
  'test_api',
  'typed_data',
  'uuid',
  'web_socket',
  'web_socket_channel',
  'xml',
  'yaml',
};

final _importPattern = RegExp('''import\\s+['"]([^'"]+)['"]''');

bool _isPureTest(File file) {
  final source = file.readAsStringSync();
  if (_flutterMarkers.any(source.contains)) return false;
  return _importsArePure(file, source, <String>{});
}

bool _importsArePure(File file, String source, Set<String> seen) {
  if (!seen.add(file.path)) return true;

  for (final match in _importPattern.allMatches(source)) {
    final import = match.group(1)!;
    if (import.startsWith('dart:')) {
      if (import == 'dart:ui') return false;
      continue;
    }
    if (import == 'package:flutter_test/flutter_test.dart') {
      // The migration rewrites this import to package:test.
      continue;
    }
    if (import.startsWith('package:flutter') ||
        import.startsWith('package:shared_preferences') ||
        import.startsWith('package:file_picker') ||
        import.startsWith('package:permission_handler') ||
        import.startsWith('package:window_manager') ||
        import.startsWith('package:flutter_secure_storage') ||
        import.startsWith('package:flutter_soloud') ||
        import.startsWith('package:video_player') ||
        import.startsWith('package:google_fonts') ||
        import.startsWith('package:material_symbols_icons') ||
        import.startsWith('package:flutter_screenutil') ||
        import.startsWith('package:provider') ||
        import.startsWith('package:sub_screen') ||
        import.startsWith('package:gamepads')) {
      return false;
    }
    if (import.startsWith('package:neostation/')) {
      final path = 'lib/${import.substring('package:neostation/'.length)}';
      final target = File(path);
      if (!target.existsSync()) return false;
      if (!_importsArePure(target, target.readAsStringSync(), seen)) {
        return false;
      }
      continue;
    }
    if (import.startsWith('package:')) {
      final package = import.substring(8).split('/').first;
      if (!_purePackages.contains(package)) return false;
      continue;
    }
    // Relative test helpers drag Flutter imports into the suite; skip them for
    // the first migration pass.
    return false;
  }
  return true;
}
