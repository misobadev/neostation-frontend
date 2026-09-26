import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../repositories/retro_achievements_repository.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/custom_notification.dart';
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
import 'ra_dedicated_pages.dart';
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

  /// Connected dashboard action focus. The D-pad follows the dashboard's
  /// spatial groups: logout, destination rail, AOTW, and the two previews.
  bool _logoutSelected = false;

  /// The dashboard's weekly spotlight selection. Availability changes its
  /// action, but the spotlight remains focusable whenever an event exists.
  bool _weekCardSelected = true;
  bool _eventsSelected = false;
  bool _recentUnlocksSelected = false;
  bool _gamesSelected = false;
  bool _gamesPreviewSelected = false;
  bool _recentUnlocksPreviewSelected = false;
  bool _awardsSelected = false;
  int _dashboardActionIndex = 0;
  int _lastNavigationRailIndex = 1;
  final GlobalKey<RADashboardHubState> _dashboardKey =
      GlobalKey<RADashboardHubState>();

  /// Set while a row's game page is being pushed, so a double-tap cannot push
  /// duplicate routes.
  bool _gameActivationInFlight = false;
  bool _raPageInFlight = false;

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
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 64.r), // Space for header (32.r + margin)
          // Main content
          if (!raProvider.isConnected) ...[
            Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.r),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        constraints: BoxConstraints(maxWidth: 260.r),
                        child: _buildLandscapeConnectionForm(
                          context,
                          raProvider,
                        ),
                      ),
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(context)),
                    ],
                  ),
                ),
              ),
            ),
          ] else ...[
            if (raProvider.isOffline) _buildOfflineBanner(context),
            Expanded(
              child: RepaintBoundary(
                child: RADashboardHub(
                  key: _dashboardKey,
                  scrollController: _dashboardScrollController,
                  logoutSelected: _logoutSelected,
                  weekCardSelected: _weekCardSelected,
                  eventsSelected: _eventsSelected,
                  recentUnlocksSelected: _recentUnlocksSelected,
                  gamesSelected: _gamesSelected,
                  recentUnlocksPreviewSelected: _recentUnlocksPreviewSelected,
                  gamesPreviewSelected: _gamesPreviewSelected,
                  awardsSelected: _awardsSelected,
                  aotwFocusKey: _aotwFocusKey,
                  recentUnlocksFocusKey: _recentUnlocksFocusKey,
                  gamesPreviewFocusKey: _gamesPreviewFocusKey,
                  onDisconnectRequested: _requestDisconnect,
                  onOwnedWeekGameSelected: _openOwnedWeekGame,
                  onUnlockSelected: _activateUnlock,
                  onGameSelected: (gameId, title) =>
                      _openRaGameAchievements(gameId: gameId, gameTitle: title),
                  onOpenUnlocks: _openUnlocks,
                  onOpenGames: _openGames,
                  onOpenEvents: _openEvents,
                  onOpenAwards: _openAwards,
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
