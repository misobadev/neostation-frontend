import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_asset.dart';
import '../../providers/romm_provider.dart';
import '../../providers/romm_saves_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../sync/sync_manager.dart';
import '../../themes/corner_radii.dart';
import '../../utils/gamepad_nav.dart';
import '../app_screen.dart';

/// RomM's inventory and manual upload retry, using the existing sync policy.
class RommSavesContent extends StatefulWidget {
  const RommSavesContent({super.key});

  @override
  State<RommSavesContent> createState() => _RommSavesContentState();
}

class _RommSavesContentState extends State<RommSavesContent> {
  late final RommSavesProvider _saves;
  late final GamepadNavigation _navigation;
  final ScrollController _scroll = ScrollController();
  int _selected = 0;
  // All, saves, states. The first three navigation slots are the toolbar.
  int _filter = 0;
  static const _toolbarCount = 3;
  static const _rowHeight = 76.0;

  List<RommAsset> get _visible => _saves.assets.where((asset) {
    return _filter == 0 || asset.isState == (_filter == 2);
  }).toList();

  bool get _busy => _saves.loading || _saves.syncing;

  @override
  void initState() {
    super.initState();
    _saves = RommSavesProvider(
      context.read<RommProvider>(),
      context.read<SyncManager>(),
    );
    _navigation = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onNavigateLeft: () => _move(-1),
      onNavigateRight: () => _move(1),
      onSelectItem: _activate,
      onXButton: _refresh,
      onFavorite: _retryUploads,
      onBack: () => AppNavigation.goToTab(AppTabs.systems),
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigation.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_saves',
        onActivate: _navigation.activate,
        onDeactivate: _navigation.deactivate,
      );
      _saves.refresh();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_saves');
    _navigation.dispose();
    _saves.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final count = _toolbarCount + _visible.length;
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
    if (_selected >= _toolbarCount && _scroll.hasClients) {
      final top = (_selected - _toolbarCount) * _rowHeight.r;
      final bottom = top + _rowHeight.r;
      final offset = top < _scroll.offset
          ? top
          : bottom > _scroll.offset + _scroll.position.viewportDimension
          ? bottom - _scroll.position.viewportDimension
          : _scroll.offset;
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    }
  }

  void _activate() {
    switch (_selected) {
      case 0:
        _refresh();
      case 1:
        _retryUploads();
      case 2:
        _cycleFilter();
    }
  }

  void _refresh() {
    if (!_busy) _saves.refresh();
  }

  void _retryUploads() {
    if (!_busy) _saves.retryUploads();
  }

  void _cycleFilter() {
    setState(() {
      _filter = (_filter + 1) % 3;
      _selected = 2;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _saves,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final files = _visible;
      _selected = _selected.clamp(0, _toolbarCount + files.length - 1);
      final filterLabel = [
        AppLocale.filterAll,
        AppLocale.statSaves,
        AppLocale.statStates,
      ][_filter].getString(context);
      return Padding(
        padding: EdgeInsets.all(24.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocale.rommSaveSyncActive.getString(context),
              style: TextStyle(fontSize: 24.sp, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.rommSavesHelp.getString(context),
              style: TextStyle(fontSize: 14.sp, color: scheme.onSurfaceVariant),
            ),
            SizedBox(height: 16.r),
            Wrap(
              spacing: 12.r,
              runSpacing: 8.r,
              children: [
                _action(
                  0,
                  Icons.refresh,
                  AppLocale.refresh.getString(context),
                  _refresh,
                  enabled: !_busy,
                ),
                _action(
                  1,
                  Icons.cloud_upload_outlined,
                  (_saves.syncing
                          ? AppLocale.syncing
                          : AppLocale.rommRetryUploads)
                      .getString(context),
                  _retryUploads,
                  enabled: !_busy,
                ),
                _action(2, Icons.filter_list, filterLabel, _cycleFilter),
              ],
            ),
            SizedBox(height: 12.r),
            if (_saves.syncResult case final result?)
              Padding(
                padding: EdgeInsets.only(bottom: 8.r),
                child: Text(
                  (result.success
                          ? AppLocale.rommUploadsChecked
                          : AppLocale.rommUploadsFailed)
                      .getString(context),
                  style: TextStyle(
                    fontSize: 14.sp,
                    color: result.success ? scheme.onSurface : scheme.error,
                  ),
                ),
              ),
            Expanded(
              child: _saves.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _saves.loadError != null
                  ? Center(
                      child: Text(
                        AppLocale.failedToRefreshCloud.getString(context),
                        style: TextStyle(fontSize: 16.sp, color: scheme.error),
                      ),
                    )
                  : files.isEmpty
                  ? Center(
                      child: Text(
                        AppLocale.noOnlineSavesFound.getString(context),
                        style: TextStyle(fontSize: 16.sp),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: _rowHeight.r,
                      itemCount: files.length,
                      itemBuilder: (context, index) =>
                          _fileRow(files[index], index),
                    ),
            ),
          ],
        ),
      );
    },
  );

  Widget _action(
    int index,
    IconData icon,
    String label,
    VoidCallback action, {
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: enabled
          ? () {
              setState(() => _selected = index);
              action();
            }
          : null,
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: _selected == index ? scheme.primary : scheme.outline,
          width: _selected == index ? 2.r : 1.r,
        ),
        backgroundColor: _selected == index ? scheme.primaryContainer : null,
        padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
        textStyle: TextStyle(fontSize: 14.sp),
      ),
      icon: Icon(icon, size: 20.r),
      label: Text(label),
    );
  }

  Widget _fileRow(RommAsset file, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected == index + _toolbarCount;
    final date = file.updatedAt ?? file.createdAt;
    final localizations = MaterialLocalizations.of(context);
    final details = [
      (file.isState ? AppLocale.statStates : AppLocale.statSaves).getString(
        context,
      ),
      '${(file.fileSizeBytes / 1024).toStringAsFixed(1)} KB',
      if (file.emulator?.isNotEmpty == true) file.emulator!,
      if (file.slot != null) file.slot!,
      if (date != null)
        '${localizations.formatShortDate(date.toLocal())} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date.toLocal()))}',
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
        borderRadius: CornerRadii.of(context).radiusInternal,
        child: InkWell(
          borderRadius: CornerRadii.of(context).radiusInternal,
          onTap: () => setState(() => _selected = index + _toolbarCount),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            child: Row(
              children: [
                Icon(
                  file.isState
                      ? Icons.pause_circle_outline
                      : Icons.save_outlined,
                  size: 24.r,
                ),
                SizedBox(width: 12.r),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.sp),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
