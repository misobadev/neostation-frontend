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

  /// `save:<id>` / `state:<id>` for every successful delete.
  final List<String> deleted = [];
  Future<void> Function() beforeDelete = () async {};

  @override
  Future<void> deleteSaves(List<int> assetIds) => _delete('save', assetIds);

  @override
  Future<void> deleteStates(List<int> assetIds) => _delete('state', assetIds);

  Future<void> _delete(String kind, List<int> assetIds) async {
    await beforeDelete();
    deleted.addAll([for (final id in assetIds) '$kind:$id']);
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
