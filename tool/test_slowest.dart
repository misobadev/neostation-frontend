import 'dart:convert';
import 'dart:io';

/// Prints the slowest suites from one or more `flutter test --file-reporter
/// json:...` files.
///
/// Usage:
///   dart tool/test_slowest.dart test-results.json
void main(List<String> args) {
  final suitePaths = <int, String>{};
  final testSuite = <int, int>{};
  final testStart = <int, int>{};
  final suiteTime = <int, int>{};
  final suiteTests = <int, int>{};

  for (final path in args) {
    final file = File(path);
    if (!file.existsSync()) continue;

    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;

      switch (decoded['type']) {
        case 'suite':
          final suite = decoded['suite'];
          if (suite is Map<String, dynamic>) {
            final id = suite['id'];
            if (id is int) {
              suitePaths[id] = suite['path'] as String? ?? 'unknown';
            }
          }
        case 'testStart':
          final test = decoded['test'];
          if (test is Map<String, dynamic>) {
            final testId = test['id'];
            final suiteId = test['suiteID'];
            if (testId is int && suiteId is int) {
              testSuite[testId] = suiteId;
              final time = decoded['time'];
              if (time is num) testStart[testId] = time.toInt();
            }
          }
        case 'testDone':
          final testId = decoded['testID'];
          if (testId is! int) continue;
          final suiteId = testSuite[testId];
          if (suiteId == null) continue;
          final end = decoded['time'];
          final start = testStart[testId];
          final duration = end is num
              ? (end.toInt() - (start ?? end.toInt())).clamp(0, 1 << 62)
              : 0;
          suiteTime[suiteId] = (suiteTime[suiteId] ?? 0) + duration;
          suiteTests[suiteId] = (suiteTests[suiteId] ?? 0) + 1;
      }
    }
  }

  if (suitePaths.isEmpty) {
    stdout.writeln('No test results found.');
    return;
  }

  final rows =
      suitePaths.entries
          .map(
            (entry) => (
              path: entry.value,
              time: suiteTime[entry.key] ?? 0,
              tests: suiteTests[entry.key] ?? 0,
            ),
          )
          .toList()
        ..sort((a, b) => b.time.compareTo(a.time));

  final total = rows.fold<int>(0, (sum, row) => sum + row.time);
  stdout.writeln(
    'Slowest suites (${(total / 1000).toStringAsFixed(1)}s across '
    '${rows.length} suites):',
  );
  for (final row in rows.take(20)) {
    stdout.writeln(
      '${(row.time / 1000).toStringAsFixed(2).padLeft(8)}s '
      '${row.tests.toString().padLeft(4)} tests  ${row.path}',
    );
  }
}
