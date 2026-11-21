import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';

import '../../providers/retro_achievements_provider.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../repositories/retro_achievements_repository.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../services/sfx_service.dart';
import '../../widgets/custom_notification.dart';
import '../../widgets/core_footer.dart';
import '../../widgets/neo_glass.dart';
import '../../themes/corner_radii.dart';
import '../../responsive.dart';

import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';

import '../../services/game_service.dart' show GamepadNavigationManager;
import '../app_screen.dart' show AppNavigation, AppTabs;

import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';

import '../../utils/login_form_selection.dart';
import '../../models/retro_achievements_dashboard_models.dart';
import '../../models/system_model.dart';
import '../game_screen/my_games_list.dart';
import '../game_screen/game_details_card/detail_tab.dart';
import 'ra_dashboard.dart';
import 'ra_collection_tab.dart';
import 'ra_games_tab.dart';
import 'ra_unlocks_tab.dart';
import 'ra_game_achievements_page.dart';

part 'ra_content/dashboard_host.dart';
part 'ra_content/gamepad_nav.dart';
part 'ra_content/login_form.dart';
part 'ra_content/drill_down_host.dart';

class RAContent extends StatefulWidget {
  const RAContent({super.key});

  @override
  State<RAContent> createState() => _RAContentState();
}

class _RAContentState extends State<RAContent>
    with LoginFormSelection<RAContent> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();
  final ScrollController _dashboardScrollController = ScrollController();
  final GlobalKey _aotwFocusKey = GlobalKey();
  final GlobalKey _recentUnlocksFocusKey = GlobalKey();
  final GlobalKey _gamesPreviewFocusKey = GlobalKey();

  /// The signed-in dashboard's focus: the sidebar menu (its sections, then
  /// logout at [_logoutMenuIndex]) or the panel beside it.
  RaDashboardSection _section = RaDashboardSection.overview;
  int _menuIndex = 0;
  bool _menuFocused = true;

  /// The overview card the D-pad is on while the panel has it: 0 the week's
  /// achievement, 6 the latest unlocks, 7 the latest games.
  int _dashboardActionIndex = 0;

  /// Sections visited so far. They stay mounted once opened so switching back
  /// doesn't reload them; the rest aren't built until asked for.
  final Set<RaDashboardSection> _visitedSections = {};
  final GlobalKey<RaUnlocksTabState> _unlocksKey = GlobalKey();
  final GlobalKey<RaGamesTabState> _gamesKey = GlobalKey();
  final GlobalKey<RaCollectionTabState> _eventsKey = GlobalKey();
  final GlobalKey<RaCollectionTabState> _awardsKey = GlobalKey();
  final GlobalKey<RADashboardHubState> _dashboardKey =
      GlobalKey<RADashboardHubState>();

  /// Set while a row's game page is being pushed, so a double-tap cannot push
  /// duplicate routes.
  bool _gameActivationInFlight = false;

  /// Matches the ScreenScraper login's password field, which the RA card sits
  /// next to: an API key is as worth hiding as a password, and as easy to
  /// mistype without being able to check it.
  bool _obscureApiKey = true;
  GamepadNavigation? _gamepadNav;

  /// Bridges [State.setState] for the part-file extensions: `setState` is
  /// `@protected` and can't be invoked from an extension, but this public
  /// method can.
  void rebuild(VoidCallback fn) => setState(fn);

  @override
  List<FocusNode?> get selectionSlots => [
    _usernameFocus,
    _apiKeyFocus,
    null,
    null,
  ];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _initControllerNavigation();
    _prefillUsername();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('ra_content');
    _gamepadNav?.dispose();
    detachFocusSelectionListeners();
    _usernameController.dispose();
    _apiKeyController.dispose();
    _usernameFocus.dispose();
    _apiKeyFocus.dispose();
    _dashboardScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RetroAchievementsProvider>(
      builder: (context, raProvider, child) {
        return Responsive(
          handheldXS: _buildLandscapeLayout(context, raProvider),
          handheldSmall: _buildLandscapeLayout(context, raProvider),
          handheldMedium: _buildLandscapeLayout(context, raProvider),
          handheldLarge: _buildLandscapeLayout(context, raProvider),
          handheldXL: _buildLandscapeLayout(context, raProvider),
        );
      },
    );
  }

  Widget _buildLandscapeLayout(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    // The same margins as the NeoSync dashboard: clear of the header dock on
    // top, close to the screen's edges elsewhere.
    return Padding(
      padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main content
          if (!raProvider.isConnected) ...[
            Expanded(child: _buildSignedOutPanel(context, raProvider)),
          ] else ...[
            if (raProvider.isOffline) _buildOfflineBanner(context),
            Expanded(
              child: RepaintBoundary(
                child: RADashboardHub(
                  key: _dashboardKey,
                  scrollController: _dashboardScrollController,
                  logoutSelected:
                      _menuFocused && _menuIndex == _logoutMenuIndex,
                  weekCardSelected: _overviewCardSelected(0),
                  recentUnlocksPreviewSelected: _overviewCardSelected(6),
                  gamesPreviewSelected: _overviewCardSelected(7),
                  section: _section,
                  menuFocused: _menuFocused,
                  onSectionTap: _tapSection,
                  sectionContent: _buildSectionContent(),
                  aotwFocusKey: _aotwFocusKey,
                  recentUnlocksFocusKey: _recentUnlocksFocusKey,
                  gamesPreviewFocusKey: _gamesPreviewFocusKey,
                  onDisconnectRequested: _requestDisconnect,
                  onOwnedWeekGameSelected: _openOwnedWeekGame,
                  onUnlockSelected: _activateUnlock,
                  onGameSelected: (gameId, title) =>
                      _openRaGameAchievements(gameId: gameId, gameTitle: title),
                  onOpenRomm: () => AppNavigation.goToTab(AppTabs.romm),
                  active: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
