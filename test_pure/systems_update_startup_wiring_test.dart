import 'dart:io';

import 'package:test/test.dart';

/// The launch check goes through [SystemsUpdateFlow] as a start-up run, which
/// stays silent unless there is an update. Wired as a manual run instead,
/// every offline launch would post "Couldn't check for systems updates".
void main() {
  final source = File('lib/screens/app_screen.dart').readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  test('the launch check runs the flow as a start-up run', () {
    final body = method('Future<void> _performUpdateSequence(');
    final call = body.indexOf('SystemsUpdateFlow.run(');
    expect(call, isNot(-1), reason: 'the launch no longer runs the flow');

    final args = body.substring(call, body.indexOf(');', call));
    expect(args, contains('trigger: SystemsUpdateTrigger.startup'));
    expect(source, isNot(contains('SystemsUpdateTrigger.manual')));
  });

  test('the launch check still honours the auto-update setting', () {
    final body = method('Future<void> _performUpdateSequence(');
    final gate = body.indexOf('config.autoUpdateSystems');
    final call = body.indexOf('SystemsUpdateFlow.run(');

    expect(gate, isNot(-1));
    expect(gate, lessThan(call));
  });
}
