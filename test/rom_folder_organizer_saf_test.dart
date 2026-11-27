import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';

import 'database_test_helper.dart';

/// An in-memory Storage Access Framework tree. Like Android's
/// `persistedUriPermissions` check, a grant matches only the exact URI it was
/// taken on: the picked folder's tree URI, never the document URIs of the
/// folders inside it.
class _FakeSaf extends OrganizerSaf {
  final Set<String> granted = {};
  final Map<String, List<Map<String, dynamic>>> children = {};
  final List<String> listed = [];
  final Map<String, String> written = {};
  var _nextId = 0;

  /// Adds a folder [name] to the listing of [parentUri]. Its URI extends
  /// [documentUri] (the parent's own document URI) when the parent is a tree.
  String addDirectory(String parentUri, String name, {String? documentUri}) {
    final uri = '${documentUri ?? parentUri}%2F${Uri.encodeComponent(name)}';
    children.putIfAbsent(parentUri, () => []).add({
      'name': name,
      'uri': uri,
      'isDirectory': true,
    });
    children.putIfAbsent(uri, () => []);
    return uri;
  }

  void addFile(String parentUri, String name) {
    children.putIfAbsent(parentUri, () => []).add({
      'name': name,
      // The suffix keeps a moved file's URI unique; Android's are too.
      'uri': '$parentUri%2F${Uri.encodeComponent(name)}#${_nextId++}',
      'isDirectory': false,
    });
  }

  List<String> namesIn(String uri) => [
    for (final entry in children[uri] ?? const <Map<String, dynamic>>[])
      entry['name'] as String,
  ];

  @override
  Future<List<Map<String, dynamic>>> listFiles(String uri) async {
    listed.add(uri);
    // Without a grant on its tree, Android refuses the listing and
    // SafDirectoryService.listFiles returns an empty list.
    if (!granted.any(uri.startsWith)) return [];
    return [
      for (final entry in children[uri] ?? const []) {...entry},
    ];
  }

  @override
  Future<bool> hasPermission(String uri) async => granted.contains(uri);

  @override
  Future<String?> createDirectory(String parentUri, String name) async =>
      addDirectory(parentUri, name);

  @override
  Future<bool> moveFile(
    String sourceUri,
    String targetDirectoryUri,
    String name,
  ) async {
    for (final entries in children.values) {
      final index = entries.indexWhere((entry) => entry['uri'] == sourceUri);
      if (index < 0) continue;
      entries.removeAt(index);
      addFile(targetDirectoryUri, name);
      return true;
    }
    return false;
  }

  @override
  Future<bool> writeTextFile(
    String parentUri,
    String name,
    String contents,
  ) async {
    addFile(parentUri, name);
    written['$parentUri/$name'] = contents;
    return true;
  }
}

void main() {
  final dbHelper = DatabaseTestHelper();
  late _FakeSaf saf;

  // A ROM folder as the Android picker returns it, and the document URI the
  // provider gives a folder inside it.
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3ANeoUAT%2Froms';
  const treeDocument = '$tree/document/primary%3ANeoUAT%2Froms';

  setUp(() async {
    await dbHelper.setUp();
    saf = _FakeSaf();
    RomFolderOrganizerService.saf = saf;
  });

  tearDown(() async {
    RomFolderOrganizerService.debugReset();
    await dbHelper.tearDown();
  });

  Future<RomFolderOrganizerResult> organize(List<String> roots) =>
      RomFolderOrganizerService.organizeRomFolders(
        roots,
        supportedRomExtensions: {'chd', 'm3u'},
        supportedSystemFolders: {'psx', 'saturn', 'dc'},
      );

  group('RomFolderOrganizerService on Android storage', () {
    test(
      "empty system folders in a granted ROM folder aren't counted as skipped",
      () async {
        saf.granted.add(tree);
        saf.addDirectory(tree, 'saturn', documentUri: treeDocument);
        saf.addDirectory(tree, 'dc', documentUri: treeDocument);

        final result = await organize([tree]);

        expect(result.rootsSkipped, 0);
        expect(result.hasChanges, isFalse);
      },
    );

    test(
      'a ROM folder that has lost its grant is counted as skipped, once',
      () async {
        saf.addDirectory(tree, 'psx', documentUri: treeDocument);

        final result = await organize([tree]);

        expect(result.rootsSkipped, 1);
        expect(saf.listed, isNot(contains(tree)));
      },
    );

    test('only the ungranted folder is skipped when there are two', () async {
      const other =
          'content://com.android.externalstorage.documents/tree/primary%3ANeoUAT%2Fnogrant';
      saf.granted.add(tree);
      saf.addDirectory(tree, 'saturn', documentUri: treeDocument);
      saf.addDirectory(tree, 'dc', documentUri: treeDocument);

      final result = await organize([tree, other]);

      expect(result.rootsSkipped, 1);
    });

    test(
      'a granted ROM folder still has its multi-disc sets organised',
      () async {
        saf.granted.add(tree);
        final psx = saf.addDirectory(tree, 'psx', documentUri: treeDocument);
        saf.addDirectory(tree, 'saturn', documentUri: treeDocument);
        saf.addFile(psx, 'Fake Game (Disc 1).chd');
        saf.addFile(psx, 'Fake Game (Disc 2).chd');

        final result = await organize([tree]);

        expect(result.groupsOrganized, 1);
        expect(result.foldersCreated, 1);
        expect(result.filesMoved, 2);
        expect(result.playlistsCreated, 1);
        expect(result.rootsSkipped, 0);
        final gameFolder = '$psx%2F${Uri.encodeComponent('Fake Game')}';
        expect(
          saf.namesIn(gameFolder),
          containsAll([
            'Fake Game (Disc 1).chd',
            'Fake Game (Disc 2).chd',
            'Fake Game.m3u',
          ]),
        );
        expect(saf.namesIn(psx), ['Fake Game']);
        expect(
          saf.written['$gameFolder/Fake Game.m3u'],
          'Fake Game (Disc 1).chd\nFake Game (Disc 2).chd\n',
        );
      },
    );
  });
}
