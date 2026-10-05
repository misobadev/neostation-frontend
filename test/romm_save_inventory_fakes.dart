import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';

class InventoryService extends RommService {
  Future<List<RommAsset>> Function() load = () async => [];
  int calls = 0;

  @override
  Future<List<RommAsset>> listSaveAssets() {
    calls++;
    return load();
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

RommAsset inventoryAsset(String name, {bool state = false, int time = 0}) =>
    RommAsset(
      id: 1,
      fileName: name,
      fileSizeBytes: 1024,
      isState: state,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(time),
    );
