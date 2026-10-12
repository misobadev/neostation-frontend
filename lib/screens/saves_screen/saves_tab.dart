import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/romm_provider.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../app_screen.dart';
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
    final session = context.select<RommProvider, int?>(
      (p) => p.isConnected ? p.service.session : null,
    );
    // B leaves for Systems, as it does from the connected saves.
    if (session == null) return const RommConnectContent(onBack: _toSystems);
    // One per connection, even across a reconnect no frame saw: what it lists
    // and deletes is identified only on the connection it came from.
    return RommSavesContent(key: ValueKey(session));
  }

  static void _toSystems() => AppNavigation.goToTab(AppTabs.systems);
}
