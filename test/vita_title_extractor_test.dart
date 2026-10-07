import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/vita_title_extractor.dart';

/// A `.psvita` file's contents become a launch argument, so only a plain title
/// ID is accepted.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vita_title_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<String?> extract(String contents) {
    final f = File('${dir.path}/game.psvita')..writeAsStringSync(contents);
    return VitaTitleExtractor.extractTitleId(f.path);
  }

  test('a plain title ID is read, trimmed', () async {
    expect(await extract('PCSE00000\n'), 'PCSE00000');
    expect(await extract('  VITASHELL_01 '), 'VITASHELL_01');
  });

  for (final contents in [
    'PCSE00000,PCSE00001',
    'PCSE00000 -x',
    'PCSE"00000',
    'PCSE00000\nsecond line',
    'x' * 33,
  ]) {
    test('"${contents.replaceAll('\n', r'\n')}" is not accepted', () async {
      expect(await extract(contents), isNull);
    });
  }
}
