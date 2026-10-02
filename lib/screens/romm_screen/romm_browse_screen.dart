import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_collection.dart';
import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../providers/file_provider.dart';
import '../../providers/romm_bulk_sync.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../services/game_service.dart';
import '../../services/logger_service.dart';
import '../../services/romm_service.dart';
import '../../services/sfx_service.dart';
import '../../sync/providers/neo_sync_adapter.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/debounced_search.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/romm_search_message.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/core_footer.dart' show kCoreFooterHeight;
import '../../widgets/custom_notification.dart';
import '../../utils/count_label.dart';
import '../../widgets/romm_browse_footer.dart';
import '../../widgets/romm_sync_banner.dart';
import '../app_screen.dart';
import 'romm_rom_card.dart';
import 'romm_rom_grid.dart';
import 'romm_rom_list.dart';

/// Gamepad/touch-navigable browser for a connected RomM server.
///
/// Flow: source menu (Collections / Platforms) → platform/collection list →
/// ROM grid → per-ROM download. Downloads land in a configured ROM folder under
/// the mapped system subfolder, after which the normal scan indexes them so they
/// become launchable.
class RommBrowseScreen extends StatefulWidget {
  const RommBrowseScreen({super.key});

  /// Where the browser was when the tab was last left. See
  /// [RommBrowsePosition] for why this outlives the widget.
  static final RommBrowsePosition position = RommBrowsePosition();

  @override
  State<RommBrowseScreen> createState() => _RommBrowseScreenState();
}

/// Which top-level list is showing when not drilled into a ROM grid.
enum RommBrowseView { source, platforms, collections }

/// The browser's cursor, kept somewhere that survives the screen.
///
/// [AppScreen] builds only the selected tab, so leaving RomM with L1/R1
/// disposes this screen outright and coming back builds a new one — which
/// without this would land on the source menu with everything at index 0, no
/// matter how deep in the library the user was. The open platform/collection
/// already survives on [RommProvider]; this is the rest of what "where I was"
/// means.
///
/// [owner] is the account the position was recorded under, so a disconnect, a
/// different login, or a different server starts from the top rather than
/// restoring indices into somebody else's library. The parked header button is
/// deliberately not kept: returning to the tab with the cursor down in the grid
/// is the sane place to resume.
class RommBrowsePosition {
  String owner = '';
  RommBrowseView view = RommBrowseView.source;
  int sourceIndex = 0;
  int platformIndex = 0;
  int collectionIndex = 0;
  int romIndex = 0;
  RommRomLayout layout = RommRomLayout.grid;

  /// Identity of the connected account, used to match a saved position to the
  /// library it was taken in.
  static String ownerOf(RommProvider provider) =>
      provider.isConnected ? '${provider.serverUrl}|${provider.username}' : '';
}

/// A card on the intermediate source menu. [collections]/[platforms] open their
/// list. Searching the library is handled outside this screen.
enum _SourceCard { collections, platforms }

/// Signature shared by the four [GridNavUtils] directional helpers, so the
/// active top-level card grid can be moved with any of them.
typedef _GridNavFn =
    int Function({
      required int currentIndex,
      required int crossAxisCount,
      required int maxItems,
    });

class _RommBrowseScreenState extends State<RommBrowseScreen> {
  // The intermediate source menu sits ahead of the platform/collection lists.
  RommBrowseView _view = RommBrowseView.source;
  int _sourceIndex = 0;

  // ROM view layout, cycled with X. Session-local rather than shared with the
  // local library's `gameViewMode`, so changing how the remote library reads
  // doesn't silently reshuffle the user's own game list. Defaults to the
  // artwork-forward grid.
  RommRomLayout _romLayout = RommRomLayout.grid;

  /// Source-menu cards, in display order.
  List<_SourceCard> get _sourceCards => [
    _SourceCard.collections,
    _SourceCard.platforms,
  ];

  /// Total selectable cards in the source menu.
  int get _sourceCount => _sourceCards.length;

  int _collectionIndex = 0;

  // Captured in initState so it's usable from dispose() (context is defunct by
  // then). App-level provider that outlives this screen.
  late final RommProvider _rommProvider;

  // ── Gamepad navigation ──────────────────────────────────────────────────────
  late final GamepadNavigation _gamepadNav;
  // Selection index per phase (platform list vs. ROM grid). Highlight + the
  // confirm/back actions key off whichever phase is active.
  int _platformIndex = 0;
  // Focused ROM, kept here only so the selection survives a view-mode switch
  // and a drill out-and-back. The ROM views own it while they are mounted.
  int _romIndex = 0;

  // The platform list is rebuilt from scratch each time we drill out of a
  // platform, so its scroll offset is restored explicitly via this controller.
  // A fixed item extent lets us jump to any index even when it isn't built yet.
  final ScrollController _sourceScroll = ScrollController();
  final ScrollController _platformScroll = ScrollController();
  final ScrollController _collectionScroll = ScrollController();

  // Grid geometry per top-level card grid (source menu, platforms, collections),
  // recomputed in each grid's LayoutBuilder so gamepad navigation moves the
  // selection by exactly one visual row/column and can scroll a not-yet-built
  // off-screen cell into view arithmetically.
  final _GridGeom _sourceGeom = _GridGeom();
  final _GridGeom _platformGeom = _GridGeom();
  final _GridGeom _collectionGeom = _GridGeom();

  /// True while a platform or collection is open (i.e. the ROM grid is showing).
  bool get _inRomGrid =>
      _rommProvider.currentPlatform != null ||
      _rommProvider.currentCollection != null;

  /// Which account-header button the cursor is parked on — 0 save-sync, 1
  /// disconnect — or null while it is down in the card grid.
  ///
  /// Right off the end of the grid's last column parks here and walks the
  /// buttons; Left walks back and drops into the grid; Up/Down leave outright.
  /// This is how the RetroAchievements dashboard reaches its logout button, and
  /// the two buttons are otherwise touch-only.
  int? _headerSlot;

  /// Whether the account header is on screen to be parked on. It rides the
  /// title bar, which only the source menu shows (see [_buildTitleBar]).
  bool get _headerShowing =>
      !_inRomGrid &&
      _view == RommBrowseView.source &&
      _rommProvider.isConnected;

  /// The parked button, or null when the header isn't showing — so drilling
  /// into a list can't strand the cursor on a button that is no longer drawn.
  int? get _parkedSlot => _headerShowing ? _headerSlot : null;

  /// Header buttons, in cursor order.
  static const int _headerSlotCount = 2;

  // ── In-platform search ──────────────────────────────────────────────────────

  static final _log = LoggerService.instance;

  /// How long typing has to settle before the term is searched.
  static const Duration _searchDebounce = Duration(milliseconds: 400);

  static const String _searchLayerId = 'romm_search_field';

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Input layer for the search row. The ROM views push their own layer on
  /// mount, so the row needs one of its own to take the controller back.
  late final GamepadNavigation _searchNav;
  late final DebouncedSearch<void> _search;

  /// Whether the cursor is on the search row rather than down in the grid.
  bool _searchSelected = false;

  /// Which control on the search row the cursor is on — see
  /// [_romSearchSlots], whose length changes with the field's text.
  int _searchSlot = 0;

  @override
  void initState() {
    super.initState();
    _rommProvider = context.read<RommProvider>();
    _restorePosition();
    // The term lives on the provider so it survives this screen being rebuilt
    // (leaving the tab with L1/R1 disposes it); the field only mirrors it.
    _searchController.text = _rommProvider.searchTerm;
    _searchFocus.addListener(_onSearchFocusChanged);
    _search = DebouncedSearch<void>(
      delay: _searchDebounce,
      run: _rommProvider.searchRoms,
      // searchRoms records its own failures on the provider (see
      // RommProvider.romsError, drawn under the field); this only catches a
      // throw that escaped it, so nothing goes unlogged.
      onError: (term, error, _) =>
          _log.w('RomM search failed: term="$term" error=$error'),
    );
    _searchNav = GamepadNavigation(
      onNavigateUp: _searchStay,
      onNavigateDown: _enterGridFromSearch,
      onNavigateLeft: () => _moveSearchSlot(-1),
      onNavigateRight: () => _moveSearchSlot(1),
      onSelectItem: _confirmSearchSlot,
      onBack: _handleBack,
      onXButton: _toggleRomLayout,
      // Y opens a confirm dialog, which pushes a plain (non-modal) layer; it
      // has to go above the ROM view's layer, not under this modal one.
      onFavorite: () {
        _leaveSearchField();
        _syncFocusedSource();
      },
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      // While typing, the D-pad belongs to the field (soft keyboard on
      // Android); B is still the way out.
      isTextFieldFocused: () => _searchFocus.hasFocus,
      allowRepeat: false,
    );
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _confirmSelection,
      onXButton: _toggleRomLayout,
      onFavorite: _syncFocusedSource, // Y — sync a whole platform/collection.
      onBack: _handleBack,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      // The search navigator needs its input subscription too; it stays
      // deactivated until its layer is pushed.
      _searchNav.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_browse_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      // The library may have changed since the last visit — games deleted here
      // unlink themselves, but a ROM removed outside the app leaves the cached
      // download state claiming it's still there. Re-read from disk.
      _rommProvider.invalidateDownloadedCache();
      if (_rommProvider.isConnected) {
        // Both lists are fetched up front (and cached by the provider): the
        // source menu previews each one as a cover/icon montage, so the data is
        // needed before the user drills into either.
        _rommProvider.loadPlatforms();
        _rommProvider.loadCollections();
      }
      // A restored selection can be well down the list, and the grid it lives
      // in was just built at offset 0. Both lists are already cached from the
      // previous visit, so the grid exists by now and can be scrolled to it.
      if (!_inRomGrid) {
        _scrollGridTo(_activeScroll, _activeGeom, _activeIndex);
      }
    });
  }

  /// Picks the cursor back up where the tab was left, provided the saved
  /// position belongs to the account that is connected now.
  ///
  /// Every index is clamped by the view that draws it, so a library that has
  /// shrunk since (or a list that hasn't loaded yet) heals itself rather than
  /// restoring a selection past the end.
  void _restorePosition() {
    final saved = RommBrowseScreen.position;
    if (saved.owner != RommBrowsePosition.ownerOf(_rommProvider)) return;
    _view = saved.view;
    _sourceIndex = saved.sourceIndex.clamp(0, _sourceCount - 1);
    _platformIndex = saved.platformIndex;
    _collectionIndex = saved.collectionIndex;
    _romIndex = saved.romIndex;
    _romLayout = saved.layout;
  }

  /// Records the cursor for the next time the tab is opened.
  void _savePosition() {
    RommBrowseScreen.position
      ..owner = RommBrowsePosition.ownerOf(_rommProvider)
      ..view = _view
      ..sourceIndex = _sourceIndex
      ..platformIndex = _platformIndex
      ..collectionIndex = _collectionIndex
      ..romIndex = _romIndex
      ..layout = _romLayout;
  }

  @override
  void dispose() {
    _savePosition();
    _search.cancel();
    if (_searchSelected) GamepadNavigationManager.popLayer(_searchLayerId);
    _searchNav.dispose();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _searchController.dispose();
    GamepadNavigationManager.popLayer('romm_browse_screen');
    _gamepadNav.dispose();
    _sourceScroll.dispose();
    _platformScroll.dispose();
    _collectionScroll.dispose();
    // The post-download rescan + per-system list refresh is handled by
    // RommProvider's debounced settle (see RommProvider.onDownloadsSettled,
    // wired in main.dart). It fires independently of this screen's lifecycle,
    // so downloads that are still transferring when the user backs out are
    // still indexed and shown — no scan is triggered from dispose (running
    // scanSystems() here throws mid-disposal and would leave the scanning flag
    // stuck, freezing input).
    super.dispose();
  }

  /// Handles a controller confirm on a ROM tile. Mirrors the on-tile control:
  /// an in-flight download cancels; a ROM downloaded this session is a no-op
  /// with an info toast rather than a duplicate download; a ROM already on
  /// disk from before is linked to its RomM entry (see [_linkLocalCopy]);
  /// otherwise the download starts.
  Future<void> _confirmRom(RommRom rom) async {
    final active = _rommProvider.downloadFor(rom.id);
    if (active != null && active.status == RommDownloadStatus.downloading) {
      _rommProvider.cancelDownload(rom.id);
      return;
    }
    // A download that finished this session already wrote its mapping row.
    if (active != null && active.status == RommDownloadStatus.completed) {
      _showDownloadedToast();
      return;
    }

    final romFolders = context.read<SqliteConfigProvider>().config.romFolders;
    final copy = await _rommProvider.findLocalCopy(rom, romFolders);
    if (!mounted) return;
    if (copy != null) {
      await _linkLocalCopy(rom, copy);
      return;
    }
    _startDownload(rom);
  }

  /// Links a ROM that is already on disk to its RomM entry.
  ///
  /// The file predates RomM (or was copied over by hand), so it has no
  /// `app_romm_rom_map` row and save sync, playtime and the cloud badge all
  /// treat it as a non-RomM game. Writing the row is what the user's confirm
  /// most plausibly means here — there is nothing to download. When a row is
  /// written the user is told so, the game's cached sync status is dropped so
  /// the badge recomputes without a restart, and RomM's metadata and art are
  /// imported if the game has none. When the row already existed this is the
  /// same "already downloaded" no-op it always was.
  Future<void> _linkLocalCopy(RommRom rom, RommLocalCopy copy) async {
    final fileProvider = context.read<FileProvider>();
    final linked = await _rommProvider.linkLocalCopy(rom, copy);
    if (!mounted) return;
    switch (linked) {
      case RommMappingWriteResult.written:
        break;
      case RommMappingWriteResult.kept:
        _showDownloadedToast();
        return;
      case RommMappingWriteResult.failed:
        // A failed write is not "already downloaded": the row the whole
        // feature hangs off is missing, and saying so is the only way the
        // user learns the link they asked for did not happen.
        AppNotification.showNotification(
          context,
          AppLocale.rommLinkFailed.getString(context),
          type: NotificationType.error,
        );
        return;
    }
    AppNotification.showNotification(
      context,
      AppLocale.rommLinked.getString(context),
      type: NotificationType.success,
    );
    _invalidateSyncState(copy.romname);
    // Best-effort and last: a metadata fetch is network work the link itself
    // doesn't depend on, and the toast has already said what happened.
    await _rommProvider.importMetadataIfMissing(rom, copy, fileProvider);
  }

  void _showDownloadedToast() {
    AppNotification.showNotification(
      context,
      AppLocale.rommDownloaded.getString(context),
      type: NotificationType.info,
    );
  }

  /// Drops the RomM sync provider's cached status for the game called
  /// [romname] (extension-stripped, as `GameModel.romname`), so the cloud
  /// badge re-asks now that a mapping row exists. Reaches the provider by id
  /// rather than through [SyncManager.active]: the cache lives on the RomM
  /// provider whether or not it is the one doing the saves.
  void _invalidateSyncState(String romname) {
    final sync = SyncManager.instance.provider(RomMSyncProvider.kProviderId);
    if (sync is RomMSyncProvider) sync.invalidateGameSyncState(romname);
  }

  Future<void> _startDownload(RommRom rom) async {
    final romFolders = context.read<SqliteConfigProvider>().config.romFolders;
    final result = await _rommProvider.downloadRom(
      rom,
      romFolders: romFolders,
      fileProvider: context.read<FileProvider>(),
    );

    if (!mounted) return;
    switch (result.status) {
      case RommDownloadStatus.completed:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadComplete.getString(context),
          type: NotificationType.success,
        );
        break;
      case RommDownloadStatus.cancelled:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadCancelled.getString(context),
          type: NotificationType.info,
        );
        break;
      case RommDownloadStatus.failed:
        AppNotification.showNotification(
          context,
          _errorMessage(result.error),
          type: NotificationType.error,
        );
        break;
      case RommDownloadStatus.downloading:
        break;
    }
  }

  // ── Bulk sync ───────────────────────────────────────────────────────────────

  /// Y — syncs the whole source the cursor is on: the open platform/collection
  /// in the ROM view, or the focused card in either list. While a sync is
  /// running the same button cancels it, so Y is the only control the feature
  /// needs.
  ///
  /// The source menu has no source to sync, so Y does nothing there.
  Future<void> _syncFocusedSource() async {
    final sync = _rommProvider.bulkSync;
    if (sync.isRunning) {
      sync.cancel();
      return;
    }

    RommPlatform? platform;
    RommCollection? collection;
    if (_inRomGrid) {
      platform = _rommProvider.currentPlatform;
      collection = _rommProvider.currentCollection;
    } else {
      switch (_view) {
        case RommBrowseView.platforms:
          final platforms = _rommProvider.platforms;
          if (platforms.isEmpty || _platformIndex >= platforms.length) return;
          platform = platforms[_platformIndex];
          break;
        case RommBrowseView.collections:
          final collections = _rommProvider.collections;
          if (collections.isEmpty || _collectionIndex >= collections.length) {
            return;
          }
          collection = collections[_collectionIndex];
          break;
        case RommBrowseView.source:
          return;
      }
    }
    final label = platform?.name ?? collection?.name;
    if (label == null) return;

    // Y is one press away from pulling an entire console down over the network,
    // so it always asks first — but only once the enumeration has priced the
    // job, so the question comes with a count, a size and the free space to
    // weigh them against. The band shows "Preparing…" in the meantime and Y
    // cancels it, so a slow server doesn't leave the user stuck.
    await _rommProvider.syncSource(
      platform: platform,
      collection: collection,
      romFolders: context.read<SqliteConfigProvider>().config.romFolders,
      fileProvider: context.read<FileProvider>(),
      onLinked: _invalidateSyncState,
      confirm: (plan) => _confirmSyncPlan(label, plan),
    );
    if (!mounted) return;
    _reportSyncOutcome(sync);
  }

  /// Asks the user to approve a priced sync.
  ///
  /// A plan that doesn't fit is flagged rather than refused. The space figures
  /// are as honest as the app can make them — resolved per volume, so a queue
  /// spread across internal storage and an SD card is checked against each
  /// separately (see `RommProvider.syncDestinationProbe`) — but a destination is
  /// still resolved without creating it, so the user remains better placed than
  /// this check to know whether a shortfall is really a problem.
  Future<bool> _confirmSyncPlan(String label, RommBulkSyncPlan plan) async {
    if (!mounted) return false;

    final lines = <String>[
      AppLocale.rommSyncConfirmPlan
          .getString(context)
          .replaceFirst('{count}', '${plan.romCount}')
          .replaceFirst('{size}', rommFormatBytes(plan.downloadBytes)),
    ];
    if (plan.skipped > 0) {
      lines.add(
        AppLocale.rommSyncConfirmSkipped
            .getString(context)
            .replaceFirst('{count}', '${plan.skipped}'),
      );
    }
    if (plan.linked > 0) {
      lines.add(
        AppLocale.rommSyncConfirmLinked
            .getString(context)
            .replaceFirst('{count}', '${plan.linked}'),
      );
    }
    lines.addAll(_spaceLines(plan));

    final scheme = Theme.of(context).colorScheme;
    return ConfirmActionDialog.show(
      context,
      title: AppLocale.rommSyncConfirmTitle
          .getString(context)
          .replaceFirst('{name}', label),
      body: lines.join('\n'),
      confirmLabel: AppLocale.rommSyncAll.getString(context),
      icon: plan.fits
          ? Symbols.cloud_download_rounded
          : Symbols.warning_rounded,
      accentColor: plan.fits ? scheme.primary : scheme.error,
    );
  }

  /// The free-space part of the pre-flight body.
  ///
  /// One line while the queue lands on a single volume — the overwhelmingly
  /// common case, and the number needs no qualifying. Once it spans volumes the
  /// totals stop being answerable in one figure, so each volume gets its own
  /// line naming itself: "which drive is full" is the only actionable thing to
  /// say, and a bare "not enough space" next to a healthy total would send the
  /// user looking in the wrong place.
  List<String> _spaceLines(RommBulkSyncPlan plan) {
    if (plan.volumes.length <= 1) {
      if (plan.spaceUnknown) return const [];
      final free = rommFormatBytes(plan.freeBytes!);
      if (plan.fits) {
        return [
          AppLocale.rommSyncConfirmFree
              .getString(context)
              .replaceFirst('{free}', free),
        ];
      }
      return [
        AppLocale.rommSyncConfirmNoSpace
            .getString(context)
            .replaceFirst('{size}', rommFormatBytes(plan.requiredBytes))
            .replaceFirst('{free}', free),
      ];
    }

    return [
      for (final volume in plan.volumes)
        if (volume.spaceUnknown)
          AppLocale.rommSyncConfirmVolumeUnknown
              .getString(context)
              .replaceFirst('{volume}', volume.volume)
              .replaceFirst('{size}', rommFormatBytes(volume.requiredBytes))
        else
          (volume.fits
                  ? AppLocale.rommSyncConfirmVolumeFree
                  : AppLocale.rommSyncConfirmVolumeNoSpace)
              .getString(context)
              .replaceFirst('{volume}', volume.volume)
              .replaceFirst('{size}', rommFormatBytes(volume.requiredBytes))
              .replaceFirst('{free}', rommFormatBytes(volume.freeBytes!)),
    ];
  }

  /// Summarises a finished sync in a single toast. The band showed the detail
  /// while it ran; this is the "what did I end up with" line.
  void _reportSyncOutcome(RommBulkSync sync) {
    // Turning down the confirmation is its own answer — a toast repeating what
    // the user just declined is noise.
    if (sync.declined) return;
    if (sync.cancelRequested) {
      AppNotification.showNotification(
        context,
        AppLocale.rommSyncCancelled.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    if (sync.failed > 0) {
      AppNotification.showNotification(
        context,
        AppLocale.rommSyncFailedCount
            .getString(context)
            .replaceFirst('{count}', '${sync.failed}'),
        type: NotificationType.error,
      );
      return;
    }
    if (sync.lastError != null) {
      // Nothing failed per ROM but an error was recorded: the enumeration pass
      // itself couldn't reach the server, so there was never a queue. Saying
      // "already downloaded" here would be a plain lie.
      AppNotification.showNotification(
        context,
        _errorMessage(sync.lastError!),
        type: NotificationType.error,
      );
      return;
    }
    if (sync.completed == 0) {
      // Nothing was queued: every ROM in the source was already on disk. If
      // the pass linked some of them to RomM, that is the news worth telling.
      if (sync.linked > 0) {
        AppNotification.showNotification(
          context,
          AppLocale.rommSyncLinkedCount
              .getString(context)
              .replaceFirst('{count}', '${sync.linked}'),
          type: NotificationType.success,
        );
        return;
      }
      AppNotification.showNotification(
        context,
        AppLocale.rommSyncNothingToDo.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    AppNotification.showNotification(
      context,
      AppLocale.rommSyncComplete
          .getString(context)
          .replaceFirst('{count}', '${sync.completed}'),
      type: NotificationType.success,
    );
  }

  String _errorMessage(RommDownloadError error) {
    switch (error) {
      case RommDownloadError.noSystemMatch:
        return AppLocale.rommNoSystemMatch.getString(context);
      case RommDownloadError.noWritableFolder:
        return AppLocale.rommNoWritableFolder.getString(context);
      case RommDownloadError.network:
      case RommDownloadError.none:
        return AppLocale.rommDownloadFailed.getString(context);
    }
  }

  // ── Gamepad navigation handlers ─────────────────────────────────────────────

  // The ROM view owns its own gamepad layer (pushed on top of this screen's),
  // so these only ever drive the source menu and the platform/collection lists.
  void _navigateUp() {
    if (_releaseHeader()) return;
    _moveTopSelection(GridNavUtils.navigateUp);
  }

  void _navigateDown() {
    if (_releaseHeader()) return;
    _moveTopSelection(GridNavUtils.navigateDown);
  }

  void _navigateLeft() {
    final parked = _parkedSlot;
    if (parked != null) {
      // Off the first button is the way back down into the grid, which keeps
      // whichever card it was on.
      setState(() => _headerSlot = parked == 0 ? null : parked - 1);
      return;
    }
    _moveTopSelection(GridNavUtils.navigateLeft);
  }

  void _navigateRight() {
    final parked = _parkedSlot;
    if (parked != null) {
      if (parked >= _headerSlotCount - 1) return;
      setState(() => _headerSlot = parked + 1);
      return;
    }
    // Right off the grid's last column reaches the header rather than wrapping
    // back to the first card, which with two cards was a move to nowhere.
    if (_headerShowing && _atRowEnd) {
      setState(() => _headerSlot = 0);
      return;
    }
    _moveTopSelection(GridNavUtils.navigateRight);
  }

  /// Whether the grid cursor is on the last card of its row, i.e. there is no
  /// card to its right for Right to move to.
  bool get _atRowEnd {
    final count = _activeCount;
    if (count == 0) return true;
    final columns = _activeGeom.columns;
    final rowEnd = (_activeIndex ~/ columns + 1) * columns - 1;
    return _activeIndex >= (rowEnd < count ? rowEnd : count - 1);
  }

  /// Drops the header parking if the cursor is up there. Returns whether it
  /// did, so Up/Down can leave the header without also moving the grid.
  bool _releaseHeader() {
    if (_parkedSlot == null) return false;
    setState(() => _headerSlot = null);
    return true;
  }

  /// Item count of whichever top-level card grid is showing.
  int get _activeCount {
    switch (_view) {
      case RommBrowseView.source:
        return _sourceCount;
      case RommBrowseView.platforms:
        return _rommProvider.platforms.length;
      case RommBrowseView.collections:
        return _rommProvider.collections.length;
    }
  }

  int get _activeIndex {
    switch (_view) {
      case RommBrowseView.source:
        return _sourceIndex;
      case RommBrowseView.platforms:
        return _platformIndex;
      case RommBrowseView.collections:
        return _collectionIndex;
    }
  }

  set _activeIndex(int value) {
    switch (_view) {
      case RommBrowseView.source:
        _sourceIndex = value;
        break;
      case RommBrowseView.platforms:
        _platformIndex = value;
        break;
      case RommBrowseView.collections:
        _collectionIndex = value;
        break;
    }
  }

  _GridGeom get _activeGeom {
    switch (_view) {
      case RommBrowseView.source:
        return _sourceGeom;
      case RommBrowseView.platforms:
        return _platformGeom;
      case RommBrowseView.collections:
        return _collectionGeom;
    }
  }

  ScrollController get _activeScroll {
    switch (_view) {
      case RommBrowseView.source:
        return _sourceScroll;
      case RommBrowseView.platforms:
        return _platformScroll;
      case RommBrowseView.collections:
        return _collectionScroll;
    }
  }

  /// Moves the selection within whichever top-level card grid is showing using
  /// [fn] (one of the [GridNavUtils] directional helpers), then scrolls the new
  /// cell into view. Column count comes from the grid's last layout pass.
  void _moveTopSelection(_GridNavFn fn) {
    // The ROM view's grid or list owns the top layer whenever it is mounted,
    // so a direction reaching this screen's own handlers while a platform or
    // collection is open means nothing is mounted to own it — the ROM body is
    // standing in for an empty result set (a search that matched nothing, or
    // an empty platform). The only thing still on screen is the search row, so
    // take the cursor up to it. Moving the platform/collection cursor instead
    // would be invisible, and would quietly change what B backs out to.
    if (_inRomGrid) {
      _selectSearchField();
      return;
    }
    final n = _activeCount;
    if (n == 0) return;
    final next = fn(
      currentIndex: _activeIndex,
      crossAxisCount: _activeGeom.columns,
      maxItems: n,
    );
    setState(() => _activeIndex = next);
    _scrollGridTo(_activeScroll, _activeGeom, next);
  }

  /// Cycles the ROM view between grid and list. No-op unless the ROM view is
  /// showing (the X hint / gamepad button only applies there).
  ///
  /// The carousel that sat between them is gone for now; when it comes back it
  /// rejoins [RommRomLayout] and this cycles through it again.
  void _toggleRomLayout() {
    if (!_inRomGrid) return;
    SfxService().playNavSound();
    const order = RommRomLayout.values;
    setState(
      () => _romLayout = order[(order.indexOf(_romLayout) + 1) % order.length],
    );
  }

  void _confirmSelection() {
    final parked = _parkedSlot;
    if (parked != null) {
      if (parked == 0) {
        _toggleSaveSync();
      } else {
        _disconnect(_rommProvider);
      }
      return;
    }
    if (_inRomGrid) {
      final roms = _rommProvider.roms;
      if (roms.isEmpty || _romIndex >= roms.length) return;
      _confirmRom(roms[_romIndex]);
      return;
    }
    switch (_view) {
      case RommBrowseView.source:
        if (_sourceIndex >= 0 && _sourceIndex < _sourceCount) {
          _activateSourceCard(_sourceCards[_sourceIndex]);
        }
        break;
      case RommBrowseView.platforms:
        final platforms = _rommProvider.platforms;
        if (platforms.isEmpty || _platformIndex >= platforms.length) return;
        setState(() => _romIndex = 0);
        _rommProvider.selectPlatform(platforms[_platformIndex]);
        break;
      case RommBrowseView.collections:
        final collections = _rommProvider.collections;
        if (collections.isEmpty || _collectionIndex >= collections.length) {
          return;
        }
        setState(() => _romIndex = 0);
        _rommProvider.selectCollection(collections[_collectionIndex]);
        break;
    }
  }

  /// Dispatches a source-menu card selection to its destination.
  void _activateSourceCard(_SourceCard card) {
    switch (card) {
      case _SourceCard.collections:
        _openSource(RommBrowseView.collections);
        break;
      case _SourceCard.platforms:
        _openSource(RommBrowseView.platforms);
        break;
    }
  }

  /// Opens one of the source-menu destinations, loading its data on demand.
  void _openSource(RommBrowseView target) {
    setState(() => _view = target);
    if (target == RommBrowseView.platforms) {
      _rommProvider.loadPlatforms();
    } else if (target == RommBrowseView.collections) {
      _rommProvider.loadCollections();
    }
  }

  /// Steps back one level within the browser: ROM view → its list → the source
  /// menu, where back stops.
  ///
  /// The source menu is a dead end on purpose. The RomM library is a top-level
  /// tab (see [RommTab]), not a pushed route, so there is nothing above it to
  /// pop — and asking the navigator to pop anyway re-enters this method through
  /// the PopScope callback in [build], which spins the UI thread forever. Tabs
  /// are left with L1/R1, exactly as on the systems and games tabs.
  void _handleBack() {
    // B leaves a focused search field first, keeping what was typed — the
    // app-wide way out of a text field, as on the search tab.
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
      return;
    }
    // B is the way out of the header, before it is the way out of a view.
    if (_releaseHeader()) return;
    if (_inRomGrid) {
      _returnToList();
    } else if (_view != RommBrowseView.source) {
      // From a platform/collection list, step back to the source menu.
      setState(() => _view = RommBrowseView.source);
    }
  }

  /// Drops back from the ROM grid to the list it was opened from, restoring that
  /// list's scroll to the drilled-into row (the list is rebuilt fresh, so the
  /// offset is set explicitly).
  void _returnToList() {
    final wasCollection = _rommProvider.currentCollection != null;
    // Backing out of a platform drops its search with it: reopening one shows
    // the full list, matching the provider, whose backToPlatforms clears the
    // term.
    _search.cancel();
    _leaveSearchField();
    setState(() {
      _searchController.clear();
      _romIndex = 0;
      _view = wasCollection
          ? RommBrowseView.collections
          : RommBrowseView.platforms;
    });
    _rommProvider.backToPlatforms();
    if (wasCollection) {
      _scrollGridTo(_collectionScroll, _collectionGeom, _collectionIndex);
    } else {
      _scrollGridTo(_platformScroll, _platformGeom, _platformIndex);
    }
  }

  /// Scrolls a top-level card grid so the cell at [index] is centred, computed
  /// from the grid's cached geometry (see [_GridGeom]) so it works even for a
  /// not-yet-built off-screen cell.
  void _scrollGridTo(ScrollController controller, _GridGeom geom, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final pos = controller.position;
      final row = index ~/ geom.columns;
      final target =
          geom.topPadding +
          row * geom.rowStride -
          (pos.viewportDimension - geom.cellHeight) / 2;
      pos.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();
    return PopScope(
      // Never pop, matching MySystemsGrid and the AppScreen shell: this is a
      // top-level tab, so back steps *within* the browser and stops at the
      // source menu. Deriving canPop from "am I at the root?" deadlocks the UI
      // thread — AppScreen wraps every tab in its own canPop:false PopScope, so
      // the route's disposition is always doNotPop, which makes Flutter notify
      // EVERY PopEntry on the route. This callback then ran at the root and
      // called maybePop() again, and since maybePop is async that recursion is
      // an endless microtask chain: 100% CPU, no frames, no exception.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        // No AppBar: the global neostation nav header (46.r) owns the top strip,
        // so the browser content is inset below it and carries its own compact
        // title/back bar rather than a second, colliding app bar.
        body: Padding(
          padding: EdgeInsets.only(top: 46.r),
          child: Column(
            children: [
              if (_showTitleBar(provider)) _buildTitleBar(theme, provider),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Builder(
                        builder: (context) {
                          if (!provider.isConnected) {
                            return _centeredMessage(
                              theme,
                              Symbols.cloud_off_rounded,
                              AppLocale.rommNotConnected.getString(context),
                            );
                          }
                          if (_inRomGrid) {
                            return _buildRomView(theme, provider);
                          }
                          switch (_view) {
                            case RommBrowseView.source:
                              return _buildSourceMenu(theme, provider);
                            case RommBrowseView.platforms:
                              return _buildPlatformList(theme, provider);
                            case RommBrowseView.collections:
                              return _buildCollectionList(theme, provider);
                          }
                        },
                      ),
                    ),
                    // Bulk-sync progress, floated just above whichever footer
                    // the current view draws. It sits here rather than in each
                    // view so a sync stays visible while the user moves
                    // between the lists and the ROM grid — and deliberately
                    // *not* in an app-wide overlay, which is what stalled the
                    // Thor's primary display over the video PlatformViews.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: kCoreFooterHeight.r,
                      child: RommSyncBanner(sync: provider.bulkSync),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether the compact title/back bar is worth its vertical space.
  ///
  /// Wherever a footer is showing it already carries the view's context and a
  /// B-back hint, making the bar a redundant second header — so the ROM,
  /// platform and collection views drop it and give the row back to the grid.
  /// The list views keep the bar while empty or still loading, since there is
  /// no footer yet to take over the back affordance.
  bool _showTitleBar(RommProvider provider) {
    if (_inRomGrid) return false;
    switch (_view) {
      case RommBrowseView.platforms:
        return provider.platforms.isEmpty;
      case RommBrowseView.collections:
        return provider.collections.isEmpty;
      case RommBrowseView.source:
        return true;
    }
  }

  /// Compact in-content header (below the global nav header): a back affordance
  /// and the current view's title. Back is hidden at the source-menu root, where
  /// there is nowhere left to step back to within the browser.
  Widget _buildTitleBar(ThemeData theme, RommProvider provider) {
    final atRoot = !_inRomGrid && _view == RommBrowseView.source;
    // At the library root, mirror the RetroAchievements dashboard header: show
    // who's logged in and a red disconnect affordance.
    final showAccount = atRoot && provider.isConnected;
    return SizedBox(
      // The list views get a tight bar so their grid starts as high as
      // possible; only the account header needs the taller two-line strip.
      height: showAccount ? 48.r : 28.r,
      child: Row(
        children: [
          if (!atRoot)
            IconButton(
              icon: const Icon(Symbols.arrow_back_rounded),
              iconSize: 18.r,
              // Default IconButton padding is a 48px tap target, which alone is
              // taller than this bar — inset it manually instead.
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              onPressed: _handleBack,
            )
          else
            SizedBox(width: 12.r),
          Expanded(
            child: showAccount
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _appBarTitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        AppLocale.rommConnectedAs
                                .getString(context)
                                .replaceAll('{user}', provider.username) +
                            _saveSyncOwnerSuffix(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(
                    _appBarTitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
          if (showAccount) ...[
            _syncToggle(theme),
            _headerButton(
              theme,
              slot: 1,
              icon: Icon(
                Symbols.logout_rounded,
                color: theme.colorScheme.error,
                size: 20.r,
              ),
              tooltip: AppLocale.rommDisconnect.getString(context),
              onPressed: () => _disconnect(provider),
            ),
          ],
        ],
      ),
    );
  }

  /// One account-header button, wearing the same parked-selection border the
  /// Save-sync switch for the library header.
  ///
  /// Deliberately a labelled pill rather than the bare cloud icon it replaced:
  /// that icon carried its whole state in fill-vs-outline, which reads as
  /// decoration, and an enabled sync was easily mistaken for a disabled one.
  /// The name and the word Enabled/Disabled are both on screen now.
  Widget _syncToggle(ThemeData theme) {
    final on = _isSaveSyncActive;
    final accent = on
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.only(right: 6.r),
      child: Semantics(
        toggled: on,
        button: true,
        label: AppLocale.rommUseForSaveSync.getString(context),
        child: InkWell(
          onTap: _toggleSaveSync,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 5.r),
            decoration: BoxDecoration(
              color: on
                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                // The parked-slot ring stays the focus cue, exactly as the
                // icon buttons beside it show it.
                color: _parkedSlot == 0
                    ? theme.colorScheme.primary
                    : accent.withValues(alpha: on ? 0.5 : 0.3),
                width: _parkedSlot == 0 ? 2.r : 1.r,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.cloud_sync_rounded,
                  fill: on ? 1 : 0,
                  color: accent,
                  size: 16.r,
                ),
                SizedBox(width: 6.r),
                Text(
                  '${AppLocale.rommSaveSyncLabel.getString(context)} · '
                  '${(on ? AppLocale.enabled : AppLocale.disabled).getString(context)}',
                  style: TextStyle(
                    fontSize: 11.r,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// RetroAchievements dashboard puts on its logout button.
  Widget _headerButton(
    ThemeData theme, {
    required int slot,
    required Icon icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: _parkedSlot == slot
              ? theme.colorScheme.primary
              : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: IconButton(
        icon: icon,
        tooltip: tooltip,
        // The bar is 48.r tall and the default 48px tap target overflows it
        // once the border above is added.
        padding: EdgeInsets.all(6.r),
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }

  /// Disconnects from the RomM server. RommTab watches connection state and
  /// swaps this browser back to the connect form once disconnected.
  Future<void> _disconnect(RommProvider provider) async {
    // Capture before the await: the context can't be read across the gap.
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    await provider.disconnect();
    // If RomM was the active save-sync provider, hand save sync back to
    // NeoSync. Leaving "romm" active against a server we just forgot would
    // silently stop ALL save sync — RomM errors out, NeoSync sits idle —
    // until the user thought to re-toggle it.
    await SyncManager.instance.releaseIfActive(
      RomMSyncProvider.kProviderId,
      persist: persist,
    );
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      AppLocale.rommDisconnect.getString(context),
      type: NotificationType.info,
    );
  }

  /// Whether RomM (vs NeoSync) is the active save-sync provider.
  bool get _isSaveSyncActive =>
      SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId;

  /// Names the provider that owns save sync, appended to the account line when
  /// it is not RomM.
  ///
  /// A connected server, its downloads and its playtime all keep working while
  /// another provider holds save sync — connecting to RomM deliberately does
  /// not take it off a NeoSync account that is still signed in — so without
  /// this the screen reads as "RomM is syncing everything". Empty when RomM
  /// owns it: the toggle beside this line already says so.
  String _saveSyncOwnerSuffix() {
    if (_isSaveSyncActive) return '';
    final owner = SyncManager.instance.active;
    // Signed out, it is not handling save sync either — so say that nothing
    // is, rather than naming a second provider that also isn't syncing. This
    // is the state where a connected server, its downloads and its playtime
    // all look healthy while no save leaves the device.
    if (owner == null || !owner.isAuthenticated) {
      return ' · ${AppLocale.saveSyncNoneActive.getString(context)}';
    }
    return ' · '
        '${AppLocale.saveSyncHandledBy.getString(context).replaceFirst('{provider}', owner.meta.name)}';
  }

  /// Toggles whether RomM is the active save-sync provider (vs NeoSync).
  Future<void> _toggleSaveSync() async {
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final target = _isSaveSyncActive
        ? NeoSyncAdapter.kProviderId
        : RomMSyncProvider.kProviderId;
    await SyncManager.instance.setActive(target, persist: persist);
    if (!mounted) return;
    // Name the provider that just took over rather than echoing the toggle's
    // own label: only one provider syncs saves, and which one it now is the
    // only thing the toast can usefully confirm. When that provider is signed
    // out it took over nothing, and the honest confirmation is that save sync
    // is now off entirely.
    final owner = SyncManager.instance.active;
    final signedIn = owner != null && owner.isAuthenticated;
    AppNotification.showNotification(
      context,
      signedIn
          ? AppLocale.saveSyncHandledBy
                .getString(context)
                .replaceFirst('{provider}', owner.meta.name)
          : AppLocale.saveSyncNoneActive.getString(context),
      type: NotificationType.info,
    );
    setState(() {});
  }

  /// Title for the in-content header. Only the source/list views show it — the
  /// ROM view drops the bar entirely and carries its name in the footer.
  String _appBarTitle() {
    switch (_view) {
      case RommBrowseView.platforms:
        return AppLocale.rommPlatforms.getString(context);
      case RommBrowseView.collections:
        return AppLocale.rommCollections.getString(context);
      case RommBrowseView.source:
        return AppLocale.rommLibrary.getString(context);
    }
  }

  // ── Source menu ─────────────────────────────────────────────────────────────

  /// The two entry cards, centred in the viewport rather than packed into the
  /// top-left of a grid — with only Collections and Platforms left, a grid
  /// stranded them in a corner of an otherwise empty screen.
  Widget _buildSourceMenu(ThemeData theme, RommProvider provider) {
    final scheme = theme.colorScheme;
    final cards = _sourceCards;
    final spacing = 16.r;
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth = constraints.maxWidth - 24.r;
        final usableHeight = constraints.maxHeight - 24.r;
        // Side by side when the screen is wide enough for two readable cards,
        // stacked otherwise (portrait / very narrow panels).
        final columns = usableWidth >= 320.r ? cards.length : 1;
        final rows = (cards.length / columns).ceil();
        // Square cards, bounded by both axes so nothing overflows on a short
        // viewport, and capped so they don't balloon on a large display.
        final cell = [
          (usableWidth - (columns - 1) * spacing) / columns,
          (usableHeight - (rows - 1) * spacing) / rows,
          240.r,
        ].reduce((a, b) => a < b ? a : b);
        // Gamepad navigation and scroll-into-view read this geometry back.
        _sourceGeom
          ..columns = columns
          ..cellHeight = cell
          ..rowStride = cell + spacing
          ..topPadding = 12.r;
        return SingleChildScrollView(
          controller: _sourceScroll,
          child: SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Wrap(
                spacing: spacing,
                runSpacing: spacing,
                alignment: WrapAlignment.center,
                children: [
                  for (var index = 0; index < cards.length; index++)
                    SizedBox(
                      width: cell,
                      height: cell,
                      child: _buildSourceCard(
                        cards[index],
                        index,
                        scheme,
                        provider,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSourceCard(
    _SourceCard card,
    int index,
    ColorScheme scheme,
    RommProvider provider,
  ) {
    return _SourceMenuCard(
      icon: _sourceCardIcon(card),
      title: _sourceCardTitle(card),
      tiles: _sourceCardTiles(card, scheme, provider),
      // Parked in the header there is one cursor on screen, up there — leaving
      // a card lit as well would read as two selections.
      isFocused: _parkedSlot == null && _sourceIndex == index,
      scheme: scheme,
      onTap: () {
        setState(() {
          _sourceIndex = index;
          _headerSlot = null;
        });
        _activateSourceCard(card);
      },
    );
  }

  /// Montage tiles previewing what a source card opens: cover art for
  /// Collections, platform icons for Platforms. Empty until the corresponding
  /// list has loaded, which drops the card back to its plain icon.
  List<Widget> _sourceCardTiles(
    _SourceCard card,
    ColorScheme scheme,
    RommProvider provider,
  ) {
    switch (card) {
      case _SourceCard.collections:
        return [
          for (final url in _collectionMontageCovers(provider))
            _coverTile(url, scheme, provider.service.imageHeadersFor),
        ];
      case _SourceCard.platforms:
        return [
          for (final platform in _montagePlatforms(provider))
            // Each icon sits on its own panel so the mosaic reads as four
            // tiles, the way the collection covers do.
            ColoredBox(
              color: scheme.surface.withValues(alpha: 0.5),
              child: _PlatformIcon(
                key: ValueKey(platform.id),
                platform: platform,
                service: provider.service,
                fill: true,
              ),
            ),
        ];
    }
  }

  /// Up to four cover URLs for the Collections montage — one per collection
  /// first, so the mosaic samples across the library rather than showing four
  /// covers from the same collection; topped up from the collections' remaining
  /// covers when the user has fewer than four collections.
  List<String> _collectionMontageCovers(RommProvider provider) {
    final service = provider.service;
    final urls = <String>{};
    for (final collection in provider.collections) {
      urls.addAll(service.collectionCovers(collection, limit: 1));
      if (urls.length == 4) return urls.toList();
    }
    for (final collection in provider.collections) {
      urls.addAll(service.collectionCovers(collection));
      if (urls.length >= 4) break;
    }
    return urls.take(4).toList();
  }

  /// The four biggest platforms by ROM count — the ones the user is most likely
  /// to recognise their own library by.
  List<RommPlatform> _montagePlatforms(RommProvider provider) {
    final sorted = [...provider.platforms]
      ..sort((a, b) => b.romCount.compareTo(a.romCount));
    return sorted.take(4).toList();
  }

  IconData _sourceCardIcon(_SourceCard card) {
    switch (card) {
      case _SourceCard.collections:
        return Symbols.collections_bookmark_rounded;
      case _SourceCard.platforms:
        return Symbols.dashboard_rounded;
    }
  }

  String _sourceCardTitle(_SourceCard card) {
    switch (card) {
      case _SourceCard.collections:
        return AppLocale.rommCollections.getString(context);
      case _SourceCard.platforms:
        return AppLocale.rommPlatforms.getString(context);
    }
  }

  /// Shared square-card grid backing the platform and collection lists. Records
  /// its computed layout into [geom] so gamepad navigation and scroll-into-view
  /// can work off exact geometry.
  Widget _buildCardGrid({
    required ScrollController controller,
    required _GridGeom geom,
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
    double cellExtent = 150,
    double aspectRatio = 1.0,
    // The title bar directly above already separates the grid from the nav
    // header, so by default the first row sits close under it rather than
    // repeating that gap — the screen is short and every row of cards counts.
    // Views with no title bar pass a slightly larger gap of their own.
    double? topInset,
    // Extra bottom padding for views that float their footer over the grid, so
    // the last row can still scroll clear of it.
    double bottomInset = 0,
  }) {
    final spacing = 10.r;
    final topPadding = topInset ?? 4.r;
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth =
            constraints.maxWidth - 24.r; // 12.r padding each side
        geom.columns = ((usableWidth + spacing) / (cellExtent.r + spacing))
            .floor()
            .clamp(1, 99);
        final cellWidth =
            (usableWidth - (geom.columns - 1) * spacing) / geom.columns;
        geom.cellHeight = cellWidth / aspectRatio;
        geom.rowStride = geom.cellHeight + spacing;
        geom.topPadding = topPadding;
        return GridView.builder(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            12.r,
            topPadding,
            12.r,
            12.r + bottomInset,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: geom.columns,
            childAspectRatio: aspectRatio,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: count,
          itemBuilder: itemBuilder,
        );
      },
    );
  }

  // ── Collection list ─────────────────────────────────────────────────────────

  Widget _buildCollectionList(ThemeData theme, RommProvider provider) {
    if (provider.loadingCollections && provider.collections.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.collections.isEmpty) {
      return _centeredMessage(
        theme,
        Symbols.collections_bookmark_rounded,
        AppLocale.rommNoCollections.getString(context),
      );
    }
    _collectionIndex = _collectionIndex.clamp(
      0,
      provider.collections.length - 1,
    );
    final scheme = theme.colorScheme;
    final focused = provider.collections[_collectionIndex];
    return Stack(
      children: [
        Positioned.fill(
          child: _buildCardGrid(
            controller: _collectionScroll,
            geom: _collectionGeom,
            count: provider.collections.length,
            // No title bar in this view — keep a little air under the nav
            // header instead of butting the first row against it.
            topInset: 10.r,
            bottomInset: kCoreFooterHeight.r,
            itemBuilder: (context, index) {
              final collection = provider.collections[index];
              return _CollectionCard(
                collection: collection,
                covers: provider.service.collectionCovers(collection),
                headersFor: provider.service.imageHeadersFor,
                isFocused: _collectionIndex == index,
                scheme: scheme,
                onTap: () {
                  setState(() {
                    _collectionIndex = index;
                    _romIndex = 0;
                  });
                  provider.selectCollection(collection);
                },
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // The sync affordance rebuilds off the sync itself, not the RomM
          // provider, so its label flips without the whole list repainting.
          child: ListenableBuilder(
            listenable: provider.bulkSync,
            builder: (context, _) => RommBrowseFooter(
              label: focused.name,
              countText: gamesCountLabel(context, focused.romCount),
              confirmLabel: AppLocale.enter.getString(context),
              onConfirm: _confirmSelection,
              onBack: _handleBack,
              onSyncAll: _syncFocusedSource,
              isSyncing: provider.bulkSync.isRunning,
            ),
          ),
        ),
      ],
    );
  }

  Widget _centeredMessage(ThemeData theme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          SizedBox(height: 12.r),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32.r),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Platform list ───────────────────────────────────────────────────────────

  Widget _buildPlatformList(ThemeData theme, RommProvider provider) {
    if (provider.loadingPlatforms && provider.platforms.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.platforms.isEmpty) {
      return _centeredMessage(
        theme,
        Symbols.videogame_asset_off_rounded,
        AppLocale.rommNoPlatforms.getString(context),
      );
    }
    _platformIndex = _platformIndex.clamp(0, provider.platforms.length - 1);
    final scheme = theme.colorScheme;
    final focused = provider.platforms[_platformIndex];
    final focusedUnsupported = !provider.isPlatformSupported(focused.id);
    return Stack(
      children: [
        Positioned.fill(
          child: _buildCardGrid(
            controller: _platformScroll,
            geom: _platformGeom,
            count: provider.platforms.length,
            cellExtent: 116,
            // No title bar in this view — keep a little air under the nav
            // header instead of butting the first row against it.
            topInset: 10.r,
            bottomInset: kCoreFooterHeight.r,
            itemBuilder: (context, index) {
              final platform = provider.platforms[index];
              final unsupported = !provider.isPlatformSupported(platform.id);
              return _MenuCard(
                leading: _PlatformIcon(
                  platform: platform,
                  service: provider.service,
                  fill: true,
                ),
                title: platform.name,
                // The count gives way to the reason the card is dimmed: on a
                // 116px tile there is room for one line under the title, and
                // "how many ROMs" matters less than "these cannot be placed".
                subtitle: unsupported
                    ? AppLocale.rommPlatformUnsupported.getString(context)
                    : '${platform.romCount}',
                isUnsupported: unsupported,
                isFocused: _platformIndex == index,
                scheme: scheme,
                onTap: () {
                  setState(() {
                    _platformIndex = index;
                    _romIndex = 0;
                  });
                  provider.selectPlatform(platform);
                },
              );
            },
          ),
        ),
        // Same footer the local systems grid/carousel wears, carrying the
        // focused platform rather than the focused system. Floated over the
        // grid rather than stacked under it so the cards run to the bottom of
        // the screen instead of stopping short in an empty band.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // The sync affordance rebuilds off the sync itself, not the RomM
          // provider, so its label flips without the whole list repainting.
          child: ListenableBuilder(
            listenable: provider.bulkSync,
            builder: (context, _) => RommBrowseFooter(
              label: focused.name,
              countText: focusedUnsupported
                  ? AppLocale.rommPlatformUnsupported.getString(context)
                  : gamesCountLabel(context, focused.romCount),
              confirmLabel: AppLocale.enter.getString(context),
              onConfirm: _confirmSelection,
              onBack: _handleBack,
              // Y would queue a whole platform that cannot be placed: every ROM
              // in it fails the same way. Drop the affordance rather than let a
              // sync start that is guaranteed to fail wholesale.
              onSyncAll: focusedUnsupported ? null : _syncFocusedSource,
              isSyncing: provider.bulkSync.isRunning,
            ),
          ),
        ),
      ],
    );
  }

  // ── ROM view ────────────────────────────────────────────────────────────────

  /// The ROM view, in whichever layout is currently selected.
  ///
  /// Each layout is a self-contained view that owns its own selection, scroll
  /// position, gamepad layer, vertical legend and footer — mirroring how the
  /// local library's list / grid / carousel are built. This screen keeps only
  /// the pieces they can't know about: the ROM set, the download actions, and
  /// what the footer should say about the open platform or collection.
  Widget _buildRomView(ThemeData theme, RommProvider provider) {
    // The search row is row 0 of the ROM view: it stays put while the grid
    // below it loads, empties or remounts, so a search that found nothing can
    // still be cleared.
    _syncSearchSlot();
    return Column(
      children: [
        _buildSearchRow(theme, provider),
        Expanded(child: _buildRomBody(theme, provider)),
      ],
    );
  }

  /// The grid or list under the search row, or the state standing in for it.
  Widget _buildRomBody(ThemeData theme, RommProvider provider) {
    if (provider.loadingRoms && provider.roms.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.roms.isEmpty) {
      // With a term active the line under the field already says nothing
      // matched; repeating "No ROMs found" would read as the platform being
      // empty.
      if (provider.searchTerm.trim().isNotEmpty) return const SizedBox();
      return _centeredMessage(
        theme,
        Symbols.search_off_rounded,
        AppLocale.rommNoRoms.getString(context),
      );
    }

    final romFolders = context.watch<SqliteConfigProvider>().config.romFolders;
    final roms = provider.roms;
    _romIndex = _romIndex.clamp(0, roms.length - 1);

    // Re-keyed per source so opening a different platform/collection remounts
    // the view with a fresh selection and layout, rather than carrying the
    // previous library's state (and index) into it.
    final sourceKey = ValueKey(
      'romm_roms_${provider.currentPlatform?.id}_${provider.currentCollection?.id}',
    );
    Widget footerBuilder(RommRom? focused) =>
        _buildRomFooter(provider, focused);
    void onIndexChanged(int index) {
      _romIndex = index;
      // A tap on a tile while the cursor is up on the search row moves the
      // cursor down to it, as the D-pad would.
      _leaveSearchField();
    }

    void onConfirm(RommRom rom) => _confirmRom(rom);
    void onCancel(RommRom rom) => provider.cancelDownload(rom.id);

    switch (_romLayout) {
      case RommRomLayout.grid:
        return RommRomGrid(
          key: sourceKey,
          provider: provider,
          roms: roms,
          romFolders: romFolders,
          initialIndex: _romIndex,
          onIndexChanged: onIndexChanged,
          onConfirm: onConfirm,
          onCancel: onCancel,
          onBack: _handleBack,
          onExitTop: _selectSearchField,
          onToggleView: _toggleRomLayout,
          onSyncAll: _syncFocusedSource,
          footerBuilder: footerBuilder,
        );
      case RommRomLayout.list:
        return RommRomList(
          key: sourceKey,
          provider: provider,
          roms: roms,
          romFolders: romFolders,
          initialIndex: _romIndex,
          onIndexChanged: onIndexChanged,
          onConfirm: onConfirm,
          onCancel: onCancel,
          onBack: _handleBack,
          onExitTop: _selectSearchField,
          onToggleView: _toggleRomLayout,
          onSyncAll: _syncFocusedSource,
          footerBuilder: footerBuilder,
        );
    }
  }

  // ── Search row ──────────────────────────────────────────────────────────────

  /// The search row's controls, in cursor order. The clear button only exists
  /// while there is something to clear.
  List<_SearchSlot> get _romSearchSlots => [
    _SearchSlot.field,
    if (_searchController.text.isNotEmpty) _SearchSlot.clear,
  ];

  /// The control the cursor is on, or null while it is down in the grid.
  _SearchSlot? get _selectedSearchSlot {
    if (!_searchSelected) return null;
    final slots = _romSearchSlots;
    if (_searchSlot < 0 || _searchSlot >= slots.length) return null;
    return slots[_searchSlot];
  }

  /// Keeps the cursor inside the row when the clear button comes or goes
  /// underneath it. Runs during build, so the `setState` is deferred.
  void _syncSearchSlot() {
    if (!_searchSelected) return;
    final parked = _searchSlot;
    final next = parked.clamp(0, _romSearchSlots.length - 1);
    if (next == parked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchSelected) return;
      // Re-check: the cursor may have moved between the build and this
      // callback, and writing the index computed from the older one would
      // drag it back.
      if (_searchSlot != parked) return;
      setState(() => _searchSlot = next);
    });
  }

  /// Moves the cursor up onto the search row, taking the controller off the
  /// ROM view. Up from the grid's first row lands here, as does a tap or
  /// click on the field.
  void _selectSearchField() {
    if (_searchSelected) return;
    setState(() {
      _searchSelected = true;
      _searchSlot = 0;
    });
    SfxService().playNavSound();
    // Modal on purpose: the ROM view unmounts for the spinner while a search
    // loads and mounts again with the results, pushing a fresh layer each
    // time. A modal layer keeps those remounts beneath it, so the cursor
    // stays on the field until the user moves it. The one thing opened from
    // here that pushes its own layer — the Y sync confirm — leaves the field
    // first (see the search navigator in initState).
    GamepadNavigationManager.pushLayer(
      _searchLayerId,
      modal: true,
      onActivate: _searchNav.activate,
      onDeactivate: _searchNav.deactivate,
    );
  }

  /// Hands the controller back to the ROM view. Its layer, if mounted, picks
  /// up where its cursor was; otherwise this screen's own layer does.
  void _leaveSearchField() {
    if (!_searchSelected) return;
    _searchFocus.unfocus();
    setState(() => _searchSelected = false);
    GamepadNavigationManager.popLayer(_searchLayerId);
  }

  /// Down from the search row drops into the grid — unless there is nothing
  /// in it, or the field is being typed in (desktop gamepads still deliver
  /// directions while a field has focus).
  bool _enterGridFromSearch() {
    if (_searchFocus.hasFocus || _rommProvider.roms.isEmpty) return false;
    _leaveSearchField();
    return true;
  }

  /// Up has nowhere to go from the top row.
  bool _searchStay() => false;

  /// Left/Right walk the row's controls.
  bool _moveSearchSlot(int delta) {
    if (_searchFocus.hasFocus) return false;
    final next = _searchSlot + delta;
    if (next < 0 || next >= _romSearchSlots.length) return false;
    SfxService().playNavSound();
    setState(() => _searchSlot = next);
    return true;
  }

  /// A on the focused control: the field opens for typing, the clear button
  /// empties it.
  void _confirmSearchSlot() {
    switch (_selectedSearchSlot) {
      case _SearchSlot.clear:
        _clearSearch();
      case _SearchSlot.field:
      case null:
        _searchFocus.requestFocus();
    }
  }

  /// Keeps the cursor and the styling in step with the platform's focus: a
  /// tap or click focuses the field directly, without going through
  /// [_selectSearchField].
  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocus.hasFocus) _selectSearchField();
    setState(() {});
  }

  /// Every keystroke restarts the debounce; the settled term goes to the
  /// provider's scoped search. The grid starts over at its first row for a
  /// new result set.
  void _onSearchChanged(String text) {
    _romIndex = 0;
    // The clear button appears with the first character and goes with the
    // last, which reshapes the row mid-typing (see [_syncSearchSlot]).
    setState(() {});
    _search.submit(text);
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) return;
    _searchController.clear();
    _onSearchChanged('');
  }

  /// The field, and under it the line reporting what the term matched.
  Widget _buildSearchRow(ThemeData theme, RommProvider provider) {
    final scheme = theme.colorScheme;
    final focused = _searchFocus.hasFocus;
    final fieldSelected = _selectedSearchSlot == _SearchSlot.field;
    final clearSelected = _selectedSearchSlot == _SearchSlot.clear;
    final message = rommSearchMessageFor(
      term: provider.searchTerm,
      count: provider.roms.length,
      hasMore: provider.romsHasMore,
      loading: provider.loadingRoms,
    );
    // Scoped to the ROM query, not the provider's global lastError: the
    // screen re-runs loadPlatforms/loadCollections on every entry, and one of
    // those failing must not replace the caption of a search that worked.
    final error = provider.romsError;
    final hint =
        (provider.currentCollection != null
                ? AppLocale.rommSearchCollectionHint
                : AppLocale.rommSearchHint)
            .getString(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(12.r, 6.r, 12.r, 4.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(theme, hint, fieldSelected, focused, clearSelected),
          if (error != null || message != null)
            Padding(
              padding: EdgeInsets.only(top: 4.r, left: 4.r),
              child: Text(
                error ?? message!.format((key) => key.getString(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.r,
                  color: error != null
                      ? scheme.error
                      : scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField(
    ThemeData theme,
    String hint,
    bool fieldSelected,
    bool focused,
    bool clearSelected,
  ) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: fieldSelected || focused ? scheme.primary : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 12.r),
        onTap: _selectSearchField,
        onChanged: _onSearchChanged,
        // Enter / the keyboard's search key: search now rather than after the
        // pause, and give the D-pad back.
        onSubmitted: (_) {
          _search.flush();
          _searchFocus.unfocus();
        },
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            fontSize: 12.r,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          prefixIcon: Icon(Symbols.search_rounded, size: 18.r),
          prefixIconConstraints: BoxConstraints(
            minWidth: 36.r,
            minHeight: 18.r,
          ),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : _buildClearSearchButton(scheme, clearSelected),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(
            alpha: focused ? 0.7 : 0.5,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.r),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// Clears the field. Wears the same selection ring the field does, since it
  /// is a cursor stop of its own — every control here is reachable by D-pad
  /// as well as by touch.
  Widget _buildClearSearchButton(ColorScheme scheme, bool selected) {
    return Semantics(
      button: true,
      label: AppLocale.rommSearchClear.getString(context),
      child: InkWell(
        onTap: () {
          _selectSearchField();
          final index = _romSearchSlots.indexOf(_SearchSlot.clear);
          if (index >= 0) setState(() => _searchSlot = index);
          _clearSearch();
        },
        borderRadius: BorderRadius.circular(10.r),
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
          padding: EdgeInsets.all(3.r),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2.r,
            ),
          ),
          child: Icon(
            Symbols.close_rounded,
            size: 16.r,
            color: scheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  /// Footer for the ROM view. Same [RommBrowseFooter] the platform view uses,
  /// which in turn matches the local systems footer — but the pill names the
  /// *focused ROM*, as the local game views do, with the open platform or
  /// collection demoted to the chip beside it. The grid's cards are artwork
  /// only, so this is where the focused game is named.
  Widget _buildRomFooter(RommProvider provider, RommRom? focused) {
    final platform = provider.currentPlatform;
    final collection = provider.currentCollection;
    final source = platform?.name ?? collection?.name ?? '';
    return RommBrowseFooter(
      label: focused?.name ?? source,
      countText: focused == null ? null : source,
      confirmLabel: AppLocale.download.getString(context),
      onConfirm: () {
        if (focused != null) _confirmRom(focused);
      },
      onBack: _handleBack,
      onSyncAll: _syncFocusedSource,
      // The ROM views memoize this footer against their own sync flag, so
      // reading the live value here stays in step with their repaints.
      isSyncing: provider.bulkSync.isRunning,
      // X used to live on the vertical rail; this footer is now the only
      // on-screen route to the list/grid switch.
      onToggleView: _toggleRomLayout,
    );
  }
}

/// The controls on the ROM view's search row, in cursor order.
enum _SearchSlot { field, clear }

/// Platform list-tile icon: RomM's bundled SVG when available, falling back to
/// the IGDB raster logo, then a generic gamepad icon. Fetched SVGs are cached
/// process-wide so scrolling/rebuilds don't refetch.
class _PlatformIcon extends StatefulWidget {
  final RommPlatform platform;
  final RommService service;

  /// When true the icon fills whatever space its parent gives it (platform
  /// cards, montage cells) instead of sitting at a fixed size.
  final bool fill;

  const _PlatformIcon({
    super.key,
    required this.platform,
    required this.service,
    this.fill = false,
  });

  @override
  State<_PlatformIcon> createState() => _PlatformIconState();
}

class _PlatformIconState extends State<_PlatformIcon> {
  static final Map<String, String?> _svgCache = {};

  String? _svg;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = widget.service.platformIconUrl(widget.platform);
    if (_svgCache.containsKey(url)) {
      setState(() {
        _svg = _svgCache[url];
        _loaded = true;
      });
      return;
    }
    final svg = await widget.service.fetchSvg(url);
    _svgCache[url] = svg;
    if (!mounted) return;
    setState(() {
      _svg = svg;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Icon(
      Symbols.sports_esports_rounded,
      color: theme.colorScheme.primary,
    );

    if (_svg != null) {
      // RomM's platform icons are full-colour illustrations (their <style> class
      // fills are inlined in RommService.fetchSvg). Render the art as-is, with
      // no white backing, so it sits cleanly on the dark UI.
      return _frame(SvgPicture.string(_svg!, fit: BoxFit.contain));
    }

    // No SVG (yet or 404): try the IGDB raster logo before the generic icon.
    final logoUrl = widget.service.platformLogoUrl(widget.platform);
    if (_loaded && logoUrl != null) {
      return _frame(
        Image.network(
          logoUrl,
          fit: BoxFit.contain,
          headers: widget.service.imageHeadersFor(logoUrl),
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : fallback,
        ),
      );
    }

    return fallback;
  }

  /// Frames an icon at a consistent size with no background — the artwork
  /// (colour SVG or logo) carries its own colours on the dark surface. In
  /// [_PlatformIcon.fill] mode it instead expands into whatever space it was
  /// given, inset slightly so it doesn't run into the tile's edge.
  Widget _frame(Widget child) {
    if (widget.fill) {
      // SizedBox.expand (not a bare Padding) so the artwork gets *tight*
      // constraints: an SvgPicture/Image handed loose ones falls back to its
      // intrinsic size and would sit small in the middle of the tile.
      return SizedBox.expand(
        child: Padding(padding: EdgeInsets.all(4.r), child: child),
      );
    }
    return SizedBox(width: 40.r, height: 40.r, child: child);
  }
}

/// Cached layout of a top-level card grid, written during its LayoutBuilder
/// pass and read by gamepad navigation / scroll-into-view so both operate on
/// the exact geometry currently on screen (a lazy GridView doesn't build
/// off-screen cells, so index math must stand in for measuring real widgets).
class _GridGeom {
  int columns = 1;
  double cellHeight = 1;
  double rowStride = 1;
  double topPadding = 12;
}

/// Square selectable card for the platform grid: a centred [leading] widget
/// (the platform's icon), a title, and an optional [subtitle] (e.g. ROM count).
class _MenuCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final bool isFocused;

  /// Dims the card and colours its subtitle: this platform has no local system,
  /// so its ROMs cannot be placed here. Still selectable — browsing costs
  /// nothing, and only the download is impossible.
  final bool isUnsupported;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _MenuCard({
    required this.leading,
    required this.title,
    this.subtitle,
    required this.isFocused,
    this.isUnsupported = false,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: rommFocusDecoration(scheme, isFocused),
        padding: EdgeInsets.all(6.r),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The icon takes every pixel the label and count don't need, so the
            // artwork rather than the card padding is what fills the tile.
            // Unsupported platforms fade the artwork rather than the whole card
            // so the focus ring keeps its full contrast when one is selected.
            Expanded(
              child: Center(
                child: isUnsupported
                    ? Opacity(opacity: 0.4, child: leading)
                    : leading,
              ),
            ),
            SizedBox(height: 4.r),
            Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w600,
                color: isFocused
                    ? scheme.primary
                    : scheme.onSurface.withValues(
                        alpha: isUnsupported ? 0.5 : 1,
                      ),
              ),
            ),
            if (subtitle != null) ...[
              SizedBox(height: 2.r),
              Text(
                subtitle!,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.r,
                  color: isUnsupported
                      ? scheme.error.withValues(alpha: 0.85)
                      : scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Source-menu tile: a montage previewing what the card opens (collection
/// covers / platform icons) above its title, so the two entry points read as
/// the library they lead into rather than as bare icons. Falls back to [icon]
/// until the lists have loaded, or when the server has no artwork to show.
class _SourceMenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> tiles;
  final bool isFocused;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _SourceMenuCard({
    required this.icon,
    required this.title,
    required this.tiles,
    required this.isFocused,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: rommFocusDecoration(scheme, isFocused),
        padding: EdgeInsets.all(8.r),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.r),
                child: tiles.isEmpty
                    ? _montagePlaceholder(scheme, icon)
                    : _buildTileMontage(tiles, scheme),
              ),
            ),
            SizedBox(height: 8.r),
            Text(
              title,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w600,
                color: isFocused ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collection browse tile: a cover-art montage (mirroring RomM's own web
/// `/collections` grid) with the collection name and ROM count beneath. Falls
/// back to a bookmark icon when the server reports no covers.
class _CollectionCard extends StatelessWidget {
  final RommCollection collection;
  final List<String> covers;
  final Map<String, String> Function(String url) headersFor;
  final bool isFocused;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _CollectionCard({
    required this.collection,
    required this.covers,
    required this.headersFor,
    required this.isFocused,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: rommFocusDecoration(scheme, isFocused),
        padding: EdgeInsets.all(8.r),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.r),
                child: _buildMontage(),
              ),
            ),
            SizedBox(height: 6.r),
            Text(
              collection.name,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w600,
                color: isFocused ? scheme.primary : scheme.onSurface,
              ),
            ),
            SizedBox(height: 2.r),
            Text(
              '${collection.romCount}',
              style: TextStyle(
                fontSize: 10.r,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMontage() {
    if (covers.isEmpty) {
      return _montagePlaceholder(
        scheme,
        collection.isVirtual
            ? Symbols.auto_awesome_motion_rounded
            : Symbols.collections_bookmark_rounded,
      );
    }
    return _buildTileMontage([
      for (final url in covers) _coverTile(url, scheme, headersFor),
    ], scheme);
  }
}

/// Arranges up to four [tiles] the way RomM's own web UI arranges a collection
/// thumbnail: one fills the frame, two split it side by side, and three or four
/// form a 2×2 mosaic (the empty corner is filled with a blank panel). Shared by
/// the collection tiles and the source-menu cards.
Widget _buildTileMontage(List<Widget> tiles, ColorScheme scheme) {
  if (tiles.isEmpty) return _montageBlank(scheme);
  if (tiles.length == 1) return tiles[0];
  if (tiles.length == 2) {
    return Row(
      children: [
        Expanded(child: tiles[0]),
        SizedBox(width: 2.r),
        Expanded(child: tiles[1]),
      ],
    );
  }
  Widget cell(int i) => i < tiles.length ? tiles[i] : _montageBlank(scheme);
  Widget row(int a, int b) => Expanded(
    child: Row(
      children: [
        Expanded(child: cell(a)),
        SizedBox(width: 2.r),
        Expanded(child: cell(b)),
      ],
    ),
  );
  return Column(
    children: [
      row(0, 1),
      SizedBox(height: 2.r),
      row(2, 3),
    ],
  );
}

Widget _montageBlank(ColorScheme scheme) =>
    ColoredBox(color: scheme.surface.withValues(alpha: 0.5));

/// Stand-in for a montage that has no artwork to show (nothing loaded yet, or a
/// server that reports no covers): the card's own icon on a blank panel.
Widget _montagePlaceholder(ColorScheme scheme, IconData icon) {
  return Container(
    color: scheme.surface.withValues(alpha: 0.5),
    child: Center(
      child: Icon(icon, color: scheme.primary, size: 34.r),
    ),
  );
}

/// A single cover-art tile in a montage, cropped to fill its cell.
Widget _coverTile(
  String url,
  ColorScheme scheme,
  Map<String, String> Function(String url) headersFor,
) {
  return Image.network(
    url,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    headers: headersFor(url),
    gaplessPlayback: true,
    errorBuilder: (context, error, stackTrace) => _montageBlank(scheme),
  );
}
