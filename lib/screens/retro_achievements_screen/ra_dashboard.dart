import '../../widgets/ra_earned_badge.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../services/game_service.dart';
import '../../models/retro_achievements_dashboard_models.dart';
import '../../models/retro_achievements_gotw.dart';
import '../../models/romm_rom.dart';
import '../../providers/file_provider.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../widgets/custom_notification.dart';

part 'ra_dashboard/profile_header.dart';
part 'ra_dashboard/section_lists.dart';
part 'ra_dashboard/shared_helpers.dart';
part 'ra_dashboard/week_card.dart';

class RADashboardHub extends StatefulWidget {
  final ScrollController? scrollController;
  final bool logoutSelected;
  final bool weekCardSelected;
  final bool eventsSelected;
  final bool recentUnlocksSelected;
  final bool gamesSelected;
  final bool awardsSelected;
  final bool recentUnlocksPreviewSelected;
  final bool gamesPreviewSelected;
  final GlobalKey? aotwFocusKey;
  final GlobalKey? recentUnlocksFocusKey;
  final GlobalKey? gamesPreviewFocusKey;
  final VoidCallback onDisconnectRequested;
  final ValueChanged<OwnedWeekGameResolution> onOwnedWeekGameSelected;
  final ValueChanged<RetroAchievementRecentUnlockItem>? onUnlockSelected;
  final void Function(int gameId, String title)? onGameSelected;
  final VoidCallback? onOpenUnlocks;
  final VoidCallback? onOpenGames;
  final VoidCallback? onOpenEvents;
  final VoidCallback? onOpenAwards;
  final VoidCallback? onOpenRomm;
  final VoidCallback? onBack;
  final VoidCallback? onSelect;

  /// Whether the dashboard is currently visible. Dedicated collection pages
  /// mount separately, so this flag gates dashboard refresh work.
  final bool active;

  const RADashboardHub({
    super.key,
    this.scrollController,
    required this.logoutSelected,
    required this.weekCardSelected,
    this.eventsSelected = false,
    this.recentUnlocksSelected = false,
    this.gamesSelected = false,
    this.awardsSelected = false,
    this.recentUnlocksPreviewSelected = false,
    this.gamesPreviewSelected = false,
    this.aotwFocusKey,
    this.recentUnlocksFocusKey,
    this.gamesPreviewFocusKey,
    required this.onDisconnectRequested,
    required this.onOwnedWeekGameSelected,
    this.onUnlockSelected,
    this.onGameSelected,
    this.onOpenUnlocks,
    this.onOpenGames,
    this.onOpenEvents,
    this.onOpenAwards,
    this.onOpenRomm,
    this.onBack,
    this.onSelect,
    this.active = true,
  });

  @override
  State<RADashboardHub> createState() => RADashboardHubState();
}

class RADashboardHubState extends State<RADashboardHub> {
  bool _requestedInitialLoad = false;

  /// Timer used to avoid starting heavy dashboard network loads when the user
  /// is just quickly passing through this tab.
  Timer? _dashboardLoadTimer;

  /// Re-check while the offline banner is up, as well as on tab entry.
  ///
  /// Entering the tab is the app's refresh gesture, which covers the player
  /// who opens RetroAchievements after the network is back. It does nothing
  /// for the player already sitting on the tab when it comes back — and on a
  /// handheld that is the normal case, because the tab is where they were when
  /// they powered the device on. Observed on an AYN Thor: Wi-Fi associated
  /// four and a half minutes after boot, long after every startup retry had
  /// given up, and the banner stayed until the tab was left and re-entered.
  ///
  /// Armed only while [RetroAchievementsProvider.isOffline] — a state the
  /// player wants resolved — so a healthy session never polls.
  ///
  /// The interval widens after each failed check. A flat 30s would be right
  /// for a Wi-Fi outage that lasts a minute and wrong for everything else:
  /// RetroAchievements answering 5xx (an outage) marks the key stale just as a
  /// dropped network does, and a 4xx — 429 rate limiting included — leaves an
  /// already-stale key marked, so a fixed interval would have every open tab
  /// asking twice a minute for as long as the outage lasted. Reset on success.
  static const List<Duration> _offlineRecheckBackoff = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  int _offlineRecheckStep = 0;
  Timer? _offlineRecheckTimer;

  /// The provider this hub is subscribed to, and the invalidation generation
  /// it has already acted on. Watching the generation is what makes a refresh
  /// work while the hub is mounted: [didChangeDependencies] runs once, so a
  /// finished game session (or the refresh button) would otherwise drop the
  /// loaded flags with nothing left to notice.
  RetroAchievementsProvider? _provider;
  int _seenCacheGeneration = 0;
  String? _rommLookupKey;
  RommRom? _rommWeekGame;
  bool _rommWeekGameLoading = false;
  bool _rommWeekGameLookupFailed = false;
  bool _forceRommWeekLookup = false;
  RommDownload? _weekDownload;
  bool _weekDownloadIndexing = false;
  int _seenRommLibraryRevision = 0;

  /// Bridges [State.setState] for the part-file extensions: `setState` is
  /// `@protected` and can't be invoked from an extension, but this public
  /// method can.
  void rebuild(VoidCallback fn) => setState(fn);

  /// Invoked by the parent gamepad navigator when the AOTW card has focus.
  /// A local game opens its library entry; a matched RomM game downloads.
  void selectWeekCard() {
    final raProvider = context.read<RetroAchievementsProvider>();
    final owned = raProvider.ownedWeekGame;
    if (owned != null) {
      widget.onOwnedWeekGameSelected(owned);
      return;
    }
    if (_weekDownloadIndexing) return;
    final remote = _rommWeekGame;
    if (remote != null) {
      _downloadWeekGame(remote, raProvider);
    } else if (!context.read<RommProvider>().isConnected) {
      widget.onOpenRomm?.call();
    }
  }

  bool get weekCardSelectable =>
      context.read<RetroAchievementsProvider>().gotw != null;

  bool get gamesSelectable =>
      context.read<RetroAchievementsProvider>().recentlyPlayedGames.isNotEmpty;

  void selectRecentUnlockPreview() {
    widget.onOpenUnlocks?.call();
  }

  Future<void> _loadDashboard(RetroAchievementsProvider provider) async {
    // Stamped up front, not on completion: the five fetches below take a while
    // and the stamp is what stops a second entry starting a duplicate run
    // while this one is still going.
    provider.markDashboardAttempted();
    // Only while the session itself is stale, so this costs two extra requests
    // on a cold-boot launch and none afterwards. Without it the profile and
    // summary read at sign-in stay marked as served-from-cache for the life of
    // the process — nothing else re-reads them — and the offline banner
    // survived long after the network came back (issue #482).
    if (provider.isOffline) await provider.revalidateSession();
    // Load sequentially rather than with Future.wait: firing every RA endpoint
    // at once trips the rate limiter (HTTP 429). AOTW goes first because it is
    // the dashboard's primary task; each section still resolves independently.
    await provider.fetchGOTW();
    await provider.fetchRecentUnlocks();
    await provider.fetchRecentlyPlayedGames();
    await provider.fetchUserAwards();
    await provider.fetchCompletionProgress();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<RetroAchievementsProvider>();
    if (!identical(provider, _provider)) {
      _provider?.removeListener(_onProviderChanged);
      _provider = provider;
      _seenCacheGeneration = provider.cacheGeneration;
      provider.addListener(_onProviderChanged);
      GameService.deviceScreenOn.removeListener(_onScreenPowerChanged);
      GameService.deviceScreenOn.addListener(_onScreenPowerChanged);
    }
    _resolveRommWeekGame(provider);
    _syncOfflineRecheck(provider);
    // Entering the tab re-reads anything past its staleness window, which is
    // what stands in for a refresh control: leaving and coming back is the
    // gesture. Without it the dashboard was a once-per-app-session snapshot —
    // a section that failed, an unlock earned on another device, or the
    // offline banner from a launch with no network, all stuck until restart.
    if (!_requestedInitialLoad &&
        provider.isConnected &&
        (!provider.dashboardLoaded || provider.dashboardIsStale) &&
        !provider.isDashboardLoading) {
      _requestedInitialLoad = true;
      _dashboardLoadTimer?.cancel();
      _dashboardLoadTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _loadDashboard(provider);
      });
    }
  }

  /// Reloads when the cached reads have been invalidated under us — after a
  /// game session, or when the user pressed refresh. Deliberately keyed to the
  /// generation counter and not to `dashboardLoaded`: a section that failed
  /// leaves that flag false too, and retrying on it would loop.
  void _onProviderChanged() {
    final provider = _provider;
    if (provider == null || !mounted) return;
    _resolveRommWeekGame(provider);
    _syncOfflineRecheck(provider);
    if (provider.cacheGeneration == _seenCacheGeneration) return;
    _seenCacheGeneration = provider.cacheGeneration;
    if (!provider.isConnected) return;
    _dashboardLoadTimer?.cancel();
    _dashboardLoadTimer = Timer(const Duration(milliseconds: 300), () {
      // A route change while the dwell is still running must not let a hidden
      // dashboard fire its load off-stage; the next activation retries it.
      if (mounted && widget.active) _loadDashboard(provider);
    });
  }

  /// Arms the re-check while the session is stale and disarms it once it is
  /// live, so the timer exists only for as long as it has something to fix.
  void _syncOfflineRecheck(RetroAchievementsProvider provider) {
    if (provider.isOffline) {
      _armOfflineRecheck();
    } else {
      _offlineRecheckStep = 0;
      _cancelOfflineRecheck();
    }
  }

  /// Schedules the next check, unless the screen is off.
  ///
  /// NeoStation runs as a HOME launcher, so the activity is never paused when
  /// the device locks: without this gate a tab left open with the banner up
  /// would poll RetroAchievements all night behind a dark screen, which is the
  /// regression #451 fixed for the in-game poll. Nothing is missed by waiting
  /// — the player cannot see the banner either — and [_onScreenPowerChanged]
  /// rearms on wake.
  void _armOfflineRecheck() {
    _offlineRecheckTimer?.cancel();
    if (!GameService.deviceScreenOn.value) {
      _offlineRecheckTimer = null;
      return;
    }
    final delay =
        _offlineRecheckBackoff[_offlineRecheckStep.clamp(
          0,
          _offlineRecheckBackoff.length - 1,
        )];
    _offlineRecheckTimer = Timer(delay, _recheckOffline);
  }

  void _cancelOfflineRecheck() {
    _offlineRecheckTimer?.cancel();
    _offlineRecheckTimer = null;
  }

  void _onScreenPowerChanged() {
    if (!mounted) return;
    final provider = _provider;
    if (provider == null) return;
    if (GameService.deviceScreenOn.value && provider.isOffline) {
      // Waking up is itself a moment worth checking: the network may have come
      // back while the screen was off.
      _offlineRecheckStep = 0;
      _armOfflineRecheck();
    } else {
      _cancelOfflineRecheck();
    }
  }

  Future<void> _recheckOffline() async {
    final provider = _provider;
    if (provider == null || !mounted) return;
    if (!provider.isOffline) {
      _offlineRecheckStep = 0;
      return;
    }
    if (provider.isDashboardLoading) {
      _armOfflineRecheck();
      return;
    }

    if (!await provider.revalidateSession()) {
      if (!mounted) return;
      // Still stale: wait longer before the next one.
      if (_offlineRecheckStep < _offlineRecheckBackoff.length - 1) {
        _offlineRecheckStep++;
      }
      _armOfflineRecheck();
      return;
    }

    if (!mounted) return;
    _offlineRecheckStep = 0;
    // The session is live again, but every section on screen is still the copy
    // that was replayed from disk, so re-read them too.
    await _loadDashboard(provider);
  }

  @override
  void dispose() {
    _dashboardLoadTimer?.cancel();
    _cancelOfflineRecheck();
    GameService.deviceScreenOn.removeListener(_onScreenPowerChanged);
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RetroAchievementsProvider>(
      builder: (context, raProvider, child) {
        final user = raProvider.user;
        if (user == null) return const SizedBox.shrink();

        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: widget.scrollController,
                padding: EdgeInsets.only(bottom: 16.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context, raProvider),
                    SizedBox(height: 8.r),
                    _buildDestinationRail(context),
                    SizedBox(height: 8.r),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        // constraints.maxWidth is already in logical pixels (the same
                        // space .r resolves to), so the breakpoint is a raw value — a
                        // .r here double-scales it and forces stacked mode on wide
                        // landscape screens, wasting the right half of every card.
                        final twoColumn = constraints.maxWidth >= 720;
                        final weekCard = KeyedSubtree(
                          key: widget.aotwFocusKey,
                          child: _buildWeekCard(context, raProvider),
                        );
                        final unlocksCard = KeyedSubtree(
                          key: widget.recentUnlocksFocusKey,
                          child: _buildRecentUnlocksCard(context, raProvider),
                        );
                        final playedCard = KeyedSubtree(
                          key: widget.gamesPreviewFocusKey,
                          child: _buildRecentlyPlayedSection(
                            context,
                            raProvider,
                          ),
                        );

                        if (!twoColumn) {
                          return Column(
                            children: [
                              weekCard,
                              SizedBox(height: 12.r),
                              unlocksCard,
                              SizedBox(height: 12.r),
                              playedCard,
                            ],
                          );
                        }
                        return Column(
                          children: [
                            weekCard,
                            SizedBox(height: 12.r),
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: unlocksCard),
                                  SizedBox(width: 12.r),
                                  Expanded(child: playedCard),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
