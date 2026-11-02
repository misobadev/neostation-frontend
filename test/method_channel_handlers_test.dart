import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every platform method the Dart code under lib/ calls must exist on the
/// Android side. An unhandled name only fails at run time, on a device, as a
/// MissingPluginException the callers don't expect.
///
/// The check is by name: a `"name" ->` branch anywhere in the app's or the
/// vendored plugins' Android sources counts, on any channel and even in a
/// `when` that isn't a channel handler. It still catches a typo or a handler
/// that was never written, which is how the two sides drift apart.
void main() {
  List<File> sources(String root, bool Function(String path) keep) =>
      Directory(root)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => keep(file.path))
          .toList();

  test('every invokeMethod name has an Android handler', () {
    final anyCall = RegExp(r'\binvoke(?:Map|List)?Method\b');
    // invokeMethod('name' / invokeMethod<T>(\n 'name'
    final literalCall = RegExp(
      r'''\binvoke(?:Map|List)?Method(?:<[^(]*>)?\(\s*['"]([^'"]+)['"]''',
    );
    final called = <String>{};
    final unreadable = <String>[];
    for (final file in sources('lib', (path) => path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      final names = literalCall.allMatches(source).map((m) => m[1]!).toList();
      // A name this test can't read (a variable, a wrapper) can't be checked.
      if (anyCall.allMatches(source).length != names.length) {
        unreadable.add(file.path);
      }
      called.addAll(names);
    }
    expect(called, isNotEmpty, reason: 'no invokeMethod calls found in lib/');
    expect(
      unreadable,
      isEmpty,
      reason: 'invokeMethod with a name that is not a string literal',
    );

    bool isJvmSource(String path) =>
        path.endsWith('.kt') || path.endsWith('.java');
    // Plugin sources only, not their build output (.cxx, build, .dart_tool).
    final sep = Platform.pathSeparator;
    final pluginSource = '${sep}android${sep}src${sep}main$sep';
    final android = [
      ...sources('android/app/src/main', isJvmSource),
      ...sources(
        'packages',
        (path) => isJvmSource(path) && path.contains(pluginSource),
      ),
    ].map((file) => file.readAsStringSync()).join('\n');
    // "name" ->, "a", "name" -> or call.method == "name"
    bool handled(String name) {
      final quoted = RegExp.escape('"$name"');
      return RegExp(
        '$quoted(\\s*,\\s*"[^"]+")*\\s*->'
        '|"[^"]+"(\\s*,\\s*"[^"]+")*\\s*,\\s*$quoted\\s*->'
        '|call\\.method\\s*==\\s*$quoted',
      ).hasMatch(android);
    }

    final missing = called.where((name) => !handled(name)).toList()..sort();
    expect(missing, isEmpty, reason: 'no Android handler for $missing');
  });
}
