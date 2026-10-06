import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';

class InventoryService extends RommService {
  Future<List<RommAsset>> Function() load = () async => [];
  int calls = 0;
  final List<int> detailCalls = [];
  Future<RommRom> Function(int) loadRom = (id) async =>
      RommRom.fromJson({'id': id, 'name': 'Game', 'platform_slug': 'gba'});

  /// `save:<id>` / `state:<id>` for every successful delete.
  final List<String> deleted = [];

  /// Every delete request, as `save:<ids>` / `state:<ids>`.
  final List<String> deleteRequests = [];

  /// `save:<id>` / `state:<id>` for files no longer on the server. As RomM
  /// does, a request deletes its files in order and stops with a 404 at the
  /// first of these.
  final Set<String> gone = {};
  Future<void> Function() beforeDelete = () async {};

  @override
  Future<RommRom> getRom(int id) {
    detailCalls.add(id);
    return loadRom(id);
  }

  @override
  Future<List<RommAsset>> listSaveAssets() {
    calls++;
    return load();
  }

  @override
  Future<void> deleteSaves(List<int> assetIds) => _delete('save', assetIds);

  @override
  Future<void> deleteStates(List<int> assetIds) => _delete('state', assetIds);

  Future<void> _delete(String kind, List<int> assetIds) async {
    deleteRequests.add('$kind:${assetIds.join(',')}');
    await beforeDelete();
    for (final id in assetIds) {
      if (!gone.add('$kind:$id')) {
        throw RommException('Delete failed (404)', statusCode: 404);
      }
      deleted.add('$kind:$id');
    }
  }
}

class InventoryConnection extends RommProvider {
  final inventory = InventoryService();
  bool connected = true;
  @override
  bool get isConnected => connected;
  @override
  RommService get service => inventory;

  void disconnectForTest() {
    connected = false;
    notifyListeners();
  }
}

class InventorySync implements ISyncProvider {
  InventorySync(this.providerId);
  @override
  final String providerId;
  int calls = 0;
  Future<SyncResult> Function() run = () async => SyncResult.ok();
  @override
  Future<SyncResult> fullSync() {
    calls++;
    return run();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RommAsset inventoryAsset(
  String name, {
  bool state = false,
  int time = 0,
  int id = 1,
  int? romId = 1,
}) => RommAsset(
  id: id,
  romId: romId,
  fileName: name,
  fileSizeBytes: 1024,
  isState: state,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(time),
);
