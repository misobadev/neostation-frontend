import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the extension list every multi-disc system depends on.
///
/// A PS2 game split across two CHDs listed itself twice, once per disc: the
/// scan only collapses a disc set into its `.m3u` when the system's extension
/// list names `m3u` (`SqliteDatabaseService._filterM3uReferencedFiles` is
/// gated on exactly that), and `ps2.json` did not name it — so the playlist was
/// never even indexed, whether the user wrote it by hand or with the built-in
/// multi-disc organizer. The flag saying PS2 *has* multi-disc games lives in
/// the same file and is easy to set without its other half, so pin both.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> loadSystem(String name) async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/systems/$name'),
    ) as Map<String, dynamic>;
    return json['system'] as Map<String, dynamic>;
  }

  /// Systems that organize disc sets into a folder plus a playlist. Each one
  /// has to index that playlist, or the discs it lists stay separate entries.
  const multiDiscSystemsIndexingPlaylists = [
    '3do.json',
    'amiga.json',
    'dc.json',
    'dos.json',
    'gc.json',
    'pccd.json',
    'ps1.json',
    'ps2.json',
    'sat.json',
    'scd.json',
    'tgcd.json',
    'wii.json',
  ];

  for (final file in multiDiscSystemsIndexingPlaylists) {
    test('$file indexes .m3u playlists alongside its disc images', () async {
      final system = await loadSystem(file);

      expect(system['multidisc'], isTrue, reason: '$file is multi-disc');
      expect(
        (system['extensions'] as List).map((e) => e.toString().toLowerCase()),
        contains('m3u'),
        reason: '$file must index the playlists the organizer writes',
      );
    });
  }
}
