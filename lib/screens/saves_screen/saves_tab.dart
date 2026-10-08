import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/romm_provider.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../neo_sync_screen/login_screen/neo_sync_content.dart';
import '../romm_screen/romm_connect_content.dart';
import 'romm_saves_content.dart';

/// Keeps the tab's identity stable while following the persisted save provider.
/// Connection failures stay in RomM so they cannot silently switch save owners.
class SavesTab extends StatelessWidget {
  const SavesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final providerId = context.select<SyncManager, String>(
      (manager) => manager.activeProviderId,
    );
    if (providerId != RomMSyncProvider.kProviderId) {
      return const NeoSyncContent();
    }
    final connected = context.select<RommProvider, bool>((p) => p.isConnected);
    return connected ? const RommSavesContent() : const RommConnectContent();
  }
}
