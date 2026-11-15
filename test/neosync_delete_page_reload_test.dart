import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Deleting a cloud save from the save list. The server moves every later save
// up one place, so a page that only dropped the deleted row showed 49 saves
// while the next page started at offset 50: the save that moved up was on
// neither page. With 51 saves the pager went too (50 saves, one page) and the
// 51st couldn't be reached until Refresh.

NeoSyncFile _save(int n) => NeoSyncFile(
  id: 'save-$n',
  fileName: 'game$n.srm',
  filePath: 'snes/game$n.srm',
  fileSize: 8192,
  gameName: 'Game $n',
  uploadedAt: DateTime(2026, 1, 1).add(Duration(minutes: n)),
  userId: 'user',
);

/// A server holding [saves], served 50 a page, that deletes for real.
class _Server extends NeoSyncService {
  _Server(int count) : saves = [for (var n = 1; n <= count; n++) _save(n)];

  final List<NeoSyncFile> saves;
  final offsets = <int>[];

  /// The search text of each listing, in order.
  final queries = <String?>[];
  bool failDeletes = false;
  bool failListings = false;

  @override
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    final offset = filter?.offset ?? 0;
    final limit = filter?.limit ?? 50;
    offsets.add(offset);
    queries.add(filter?.query);
    if (failListings) return {'success': false, 'message': 'offline'};
    return {
      'success': true,
      'files': saves.skip(offset).take(limit).toList(),
      'total': saves.length,
    };
  }

  @override
  Future<Map<String, dynamic>> deleteFile(String fileId) async {
    if (failDeletes) return {'success': false, 'message': 'refused'};
    saves.removeWhere((s) => s.id == fileId);
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> getQuota() async => {'success': false};
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late _Server server;
  late NeoSyncProvider neoSync;

  Future<void> open(int count, {int page = 1}) async {
    server = _Server(count);
    neoSync = NeoSyncProvider(server)..setAuthService(_SignedIn());
    await neoSync.loadOnlineFiles();
    if (page > 1) await neoSync.goOnlinePage(page);
    server.offsets.clear();
  }

  List<String> ids() => neoSync.onlineFiles.map((s) => s.id).toList();

  test('a delete on a page that is not the last shows a full page again, '
      'with the save that moved up', () async {
    await open(60);

    expect(await neoSync.deleteOnlineFile('save-3'), isTrue);

    expect(server.offsets, [0], reason: 'the page is fetched again');
    expect(neoSync.onlineFiles, hasLength(50));
    expect(ids().last, 'save-51');
    expect(ids(), isNot(contains('save-3')));
    expect(neoSync.onlineTotal, 59);

    await neoSync.nextOnlinePage();
    expect(ids().first, 'save-52', reason: 'nothing skipped between pages');
  });

  test('with 51 saves, a delete on page 1 keeps the 51st in view', () async {
    await open(51);

    await neoSync.deleteOnlineFile('save-10');

    expect(ids(), contains('save-51'));
    expect(neoSync.onlineFiles, hasLength(50));
    expect(neoSync.onlineTotalPages, 1);
  });

  test('deleting the only save on the last page steps back a page', () async {
    await open(51, page: 2);
    expect(ids(), ['save-51']);

    await neoSync.deleteOnlineFile('save-51');

    expect(neoSync.onlinePage, 1);
    expect(server.offsets, [0]);
    expect(neoSync.onlineFiles, hasLength(50));
  });

  test('a page turned while the delete was on its way, left empty by it, '
      'steps back', () async {
    // 51 saves: page 2 holds save-51 alone. The user deletes save-3 on page 1
    // and turns to page 2 before the delete answers.
    await open(51);
    final delete = neoSync.deleteOnlineFile('save-3');
    await neoSync.nextOnlinePage();
    await delete;

    expect(neoSync.onlinePage, 1);
    expect(ids(), contains('save-51'));
  });

  test('a delete from a search keeps the search', () async {
    server = _Server(60);
    neoSync = NeoSyncProvider(server)..setAuthService(_SignedIn());
    await neoSync.setOnlineFilter(const NeoSyncFileFilter(query: 'Game'));
    server.queries.clear();

    await neoSync.deleteOnlineFile('save-3');

    expect(server.queries, ['Game']);
  });

  test('a failed delete changes nothing and fetches nothing', () async {
    await open(60);
    server.failDeletes = true;

    expect(await neoSync.deleteOnlineFile('save-3'), isFalse);

    expect(server.offsets, isEmpty);
    expect(ids(), contains('save-3'));
    expect(neoSync.onlineTotal, 60);
  });

  test('a reload that fails after the delete shows the list as failed to '
      'load', () async {
    await open(60);
    server.failListings = true;

    expect(
      await neoSync.deleteOnlineFile('save-3'),
      isTrue,
      reason: 'the save was deleted',
    );

    expect(neoSync.onlineFilesLoadFailed, isTrue);
    expect(neoSync.onlineFiles, isEmpty);
  });
}
