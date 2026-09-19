import 'package:neostation/providers/menu_app_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/main_screen.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/secondary_apps_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/steam_scraper_service.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/widgets/app_lifecycle_handler.dart';
import 'package:neostation/widgets/back_swipe_zone.dart';
import 'package:neostation/services/startup_theme_cache.dart';
import 'package:neostation/widgets/splash_status_layout.dart';
import 'package:neostation/widgets/permission_check_wrapper.dart';
import 'package:neostation/utils/custom_scroll_behavior.dart';
import 'package:neostation/utils/desktop_window_focus.dart';
import 'package:neostation/utils/display_metrics_log.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/image_cache_budget.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:fvp/fvp.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:window_manager/window_manager.dart';
import 'package:neostation/screens/secondary_screen/secondary_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';

// Politica personalizada para deshabilitar navegacion por teclado
class NoFocusTraversalPolicy extends FocusTraversalPolicy {
  @override
  FocusNode? findFirstFocus(
    FocusNode currentNode, {
    bool ignoreCurrentFocus = false,
  }) => null;

  @override
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) => null;

  @override
  FocusNode findLastFocus(
    FocusNode currentNode, {
    bool ignoreCurrentFocus = false,
  }) => currentNode;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) =>
      false;

  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) => [];
}

// Notifier global para cambios de fullscreen
class FullscreenNotifier extends ChangeNotifier {
  static final FullscreenNotifier _instance = FullscreenNotifier._internal();
  factory FullscreenNotifier() => _instance;
  FullscreenNotifier._internal();

  bool _isFullscreen = false;
  bool get isFullscreen => _isFullscreen;

  void notifyFullscreenChanged(bool isFullscreen) {
    if (_isFullscreen != isFullscreen) {
      _isFullscreen = isFullscreen;
      LoggerService.instance.i(
        'FullscreenNotifier: Fullscreen changed to $isFullscreen',
      );
      notifyListeners();
    }
  }
}

// Intent para toggle fullscreen
class ToggleFullscreenIntent extends Intent {
  const ToggleFullscreenIntent();
}

// Action para toggle fullscreen
class ToggleFullscreenAction extends Action<ToggleFullscreenIntent> {
  @override
  Future<void> invoke(ToggleFullscreenIntent intent) async {
    if (Platform.isWindows || Platform.isLinux) {
      final isFullscreen = FullscreenNotifier().isFullscreen;
      final newState = !isFullscreen;
      LoggerService.instance.i('Toggle fullscreen (Native): $newState');
      FullScreenWindow.setFullScreen(newState);

      // Notificar el cambio de fullscreen
      FullscreenNotifier().notifyFullscreenChanged(newState);
    } else if (Platform.isMacOS) {
      final isFullscreen = await windowManager.isFullScreen();
      LoggerService.instance.i(
        'Toggle fullscreen (macOS): current=$isFullscreen, setting=${!isFullscreen}',
      );
      await windowManager.setFullScreen(!isFullscreen);

      // Notificar el cambio de fullscreen
      await Future.delayed(const Duration(milliseconds: 100));
      final newState = await windowManager.isFullScreen();
      FullscreenNotifier().notifyFullscreenChanged(newState);
    }
    return;
  }
}

/// Physical RAM in whole gigabytes, or null when the platform will not say.
///
/// device_info_plus reports memory on Android, Windows and macOS but not on
/// Linux, which is why that one reads procfs directly.
Future<int?> _physicalRamGb() async {
  try {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      LoggerService.instance.i(
        'Android device detected: ${info.model}, RAM: ${info.physicalRamSize} MB',
      );
      return info.physicalRamSize ~/ 1024;
    }
    if (Platform.isWindows) {
      final info = await DeviceInfoPlugin().windowsInfo;
      return info.systemMemoryInMegabytes ~/ 1024;
    }
    if (Platform.isMacOS) {
      final info = await DeviceInfoPlugin().macOsInfo;
      return info.memorySize ~/ (1024 * 1024 * 1024);
    }
    if (Platform.isLinux) {
      final meminfo = File('/proc/meminfo');
      if (!meminfo.existsSync()) return null;
      for (final line in meminfo.readAsLinesSync()) {
        if (!line.startsWith('MemTotal:')) continue;
        final kb = int.tryParse(
          RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '',
        );
        return kb == null ? null : kb ~/ (1024 * 1024);
      }
    }
  } catch (e) {
    LoggerService.instance.w('Could not read physical RAM: $e');
  }
  return null;
}

/// Sizes the decoded-image cache for the machine this build is running on.
Future<void> _configureImageCache() async {
  final int? ramGb = await _physicalRamGb();
  final budget = ImageCacheBudget.forRam(ramGb);

  LoggerService.instance.i(
    'Image cache: ${budget.maximumSizeMb} MB / ${budget.maximumSize} entries '
    '(physical RAM: ${ramGb == null ? 'unknown' : '$ramGb GB'})',
  );

  PaintingBinding.instance.imageCache
    ..maximumSize = budget.maximumSize
    ..maximumSizeBytes = budget.maximumSizeBytes;
}

/// Global navigator key so overlay notifications can outlive the widget that
/// created them. Used by [AppNotification] for progress notifications.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Render immediately. Cold boots can wait for removable storage before the
  // database opens, and without this lightweight root Android shows only a
  // blank launch surface for that entire interval.
  runApp(const StartupLoadingApp());
  await WidgetsBinding.instance.endOfFrame;

  final log = LoggerService.instance;
  await log.init();
  log.i('Starting NeoStation...');

  // After log.init(): this used to run before it, so the budget it picked was
  // never visible in app.log.
  await _configureImageCache();

  // Resolve the user-data location before anything reads it, so the cold-boot
  // wait happens once (behind the loading screen) rather than once per caller.
  if (Platform.isAndroid) {
    await _awaitUserDataStorage();
  }

  // Inicializar window_manager para desktop con tamano minimo 640x480
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = WindowOptions(
      size: const Size(1280, 720),
      alwaysOnTop: false,
      skipTaskbar: false,
      minimumSize: const Size(640, 480),
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    // Cargar configuracion de fullscreen
    bool isFullscreen = true;
    try {
      final config = await ConfigRepository.getUserConfig();
      if (config != null && config['is_fullscreen'] != null) {
        isFullscreen = config['is_fullscreen'] == 1;
      }
    } catch (e) {
      LoggerService.instance.w('Error loading fullscreen config: $e');
    }

    if (isFullscreen) {
      if (Platform.isWindows || Platform.isLinux) {
        FullScreenWindow.setFullScreen(true);
      } else if (Platform.isMacOS) {
        await windowManager.setFullScreen(true);
      }
      FullscreenNotifier().notifyFullscreenChanged(true);
    } else {
      if (Platform.isWindows || Platform.isLinux) {
        FullScreenWindow.setFullScreen(false);
      } else if (Platform.isMacOS) {
        await windowManager.setFullScreen(false);
      }
      FullscreenNotifier().notifyFullscreenChanged(false);
    }

    // Gamepad input follows window focus from here on. Must come after
    // ensureInitialized() above, which owns the channel it listens on.
    await DesktopWindowFocus.initialize();

    log.i('Window manager initialized');
  }

  // Inicializar fvp para soporte extendido de video (Windows, Linux, etc.)
  registerWith();

  // Configurar manejo global de errores para evitar crashes
  FlutterError.onError = (FlutterErrorDetails details) {
    // Para otros errores, usar el handler por defecto en debug
    if (details.stack != null) {
      FlutterError.dumpErrorToConsole(details);
    }
  };

  // Configure fullscreen for mobile platforms
  if (Platform.isAndroid || Platform.isIOS) {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      //DeviceOrientation.portraitUp,
      //DeviceOrientation.portraitDown,
    ]);
  }

  // Inicializar FileProvider
  final fileProvider = FileProvider();
  try {
    await fileProvider.initialize();
  } catch (e) {
    log.e('Error initializing FileProvider: $e');
  }

  // Inicializar localizacion con idioma persistido
  String initLang = 'en';
  try {
    final rawConfig = await ConfigRepository.getUserConfig();
    if (rawConfig != null && rawConfig['app_language'] != null) {
      initLang = rawConfig['app_language'].toString();
    }
  } catch (e) {
    log.w('Could not load saved language, defaulting to en: $e');
  }
  await FlutterLocalization.instance.ensureInitialized();
  FlutterLocalization.instance.init(
    mapLocales: [
      MapLocale('en', AppLocale.en),
      MapLocale('es', AppLocale.es),
      MapLocale('pt', AppLocale.pt),
      MapLocale('ru', AppLocale.ru),
      MapLocale('zh', AppLocale.zh),
      MapLocale('zh_Hant', AppLocale.zhHant),
      MapLocale('fr', AppLocale.fr),
      MapLocale('de', AppLocale.de),
      MapLocale('it', AppLocale.it),
      MapLocale('id', AppLocale.id),
      MapLocale('ja', AppLocale.ja),
      MapLocale('ko', AppLocale.ko),
    ],
    initLanguageCode: initLang.isNotEmpty ? initLang : 'en',
  );

  // Inicializar AuthService antes de mostrar la app
  final authService = AuthService();
  await authService.initialize();

  // Inicializar providers criticos
  final sqliteConfigProvider = SqliteConfigProvider();
  final sqliteDatabaseProvider = SqliteDatabaseProvider();

  try {
    // 1. Inicializar ConfigProvider primero (sincroniza sistemas)
    await sqliteConfigProvider.initialize();

    // 2. Inicializar DatabaseProvider (carga juegos basandose en sistemas sincronizados)
    await sqliteDatabaseProvider.initialize(
      romFolders: sqliteConfigProvider.config.romFolders,
      availableSystems: sqliteConfigProvider.availableSystems,
    );

    // Background scrape Windows games from Steam
    SteamScraperService.scrapeSteamGames(provider: sqliteDatabaseProvider);
  } catch (e) {
    log.e('Error initializing database providers: $e');
  }

  // Inicializar listener de Android para tracking de tiempo de juego
  if (Platform.isAndroid) {
    try {
      GameService.initializeAndroidGameListener();
      // Verificar si hay una sesion de juego pendiente (app fue matada)
      await GameService.checkPendingGameSession();
    } catch (e) {
      log.e('Error initializing GameService: $e');
    }
  }

  // Resolve the saved theme before the first themed frame. Created lazily,
  // ThemeProvider would paint its platform-brightness fallback until the
  // database read returned — a white flash on any platform that reports a
  // light brightness (the Steam Deck does) for a user on a dark theme.
  final themeProvider = await ThemeProvider.create();

  // Build NeoSync provider graph before runApp so SyncManager can register it.
  final neoSyncService = NeoSyncService();
  final neoSyncProvider = NeoSyncProvider(neoSyncService);
  neoSyncProvider.setAuthService(authService);
  authService.addListener(() {
    neoSyncProvider.setAuthService(authService);
  });

  final neoSyncAdapter = NeoSyncAdapter(neoSyncProvider);
  SyncManager.instance.register(neoSyncAdapter);

  // Nothing reads ScreenScraper credentials on launch, so a legacy base64
  // password would sit in the database until the user next scraped. Sweep it
  // into the credential store instead. Unawaited: it is a no-op after the first
  // run and must not hold up startup. RomM needs no equivalent because
  // RommProvider.initialize() below reads its config on every launch.
  unawaited(ScraperRepository.migrateLegacyPasswordToCredentialStore());

  // Build the RomM browse provider before runApp so the RomM save-sync provider
  // can share its authenticated connection, and so SyncManager can register it.
  final rommProvider = RommProvider()..initialize();
  // After RomM downloads settle (debounced), index the new ROMs and refresh the
  // affected systems' game lists so they appear progressively — even if the
  // user backs out of the browse screen mid-batch.
  //
  // Scan only the affected systems (rescanSystemSilent), not the whole library,
  // so downloading 100 ROMs doesn't trigger 100 full-library rescans. Fall back
  // to a full scan only when a genuinely new (not-yet-detected) system appears,
  // since detecting it needs the full re-detect pass.
  rommProvider.onDownloadsSettled = (systems) async {
    // Read the *scanned* system list, not `config.detectedSystems`. On Android
    // scanSystems() deliberately leaves the config's copy alone while it scans
    // in the background (see scanning.dart), so it is stale here — which made
    // every downloaded system look new (forcing a full rescan each settle) and
    // then look unregistered afterwards, skipping the refresh that puts the
    // games on screen.
    Set<String> detectedFolders() => {
      for (final s in sqliteConfigProvider.detectedSystems) s.folderName,
    };

    final detected = detectedFolders();
    final hasNewSystem = systems.any(
      (s) =>
          !detected.contains(s.folderName) && !s.folders.any(detected.contains),
    );
    if (hasNewSystem) {
      await sqliteConfigProvider.scanSystems();
    }
    // scanSystems dispatches Android storage work in the background. Run the
    // targeted, awaited rescan so the ROM row exists before its RA id is set.
    for (final system in systems) {
      await sqliteConfigProvider.rescanSystemSilent(system);
    }
    // Re-read after the scan: a genuinely new system only becomes known here.
    // A system still missing at this point really didn't register (scanSystems
    // no-ops while another scan is in flight), and refreshing it would load an
    // empty list and silently drop the freshly downloaded games — so skip it
    // and log, leaving the gap diagnosable rather than silent.
    final registered = detectedFolders();
    for (final system in systems) {
      final isKnown =
          registered.contains(system.folderName) ||
          system.folders.any(registered.contains);
      if (isKnown) {
        await sqliteDatabaseProvider.refreshSystem(system.folderName);
      } else {
        LoggerService.instance.w(
          'RomM: downloaded ROMs for "${system.folderName}" but it is not '
          'registered after scan; a manual rescan is needed for them to appear.',
        );
      }
    }
  };
  SyncManager.instance.register(
    RomMSyncProvider(rommProvider, neoSyncProvider),
  );

  // Restore the user's chosen provider only after both are registered.
  SyncManager.instance.restoreActive(
    sqliteConfigProvider.config.activeSyncProvider,
  );

  runApp(
    MyApp(
      fileProvider: fileProvider,
      authService: authService,
      sqliteConfigProvider: sqliteConfigProvider,
      sqliteDatabaseProvider: sqliteDatabaseProvider,
      neoSyncService: neoSyncService,
      neoSyncProvider: neoSyncProvider,
      rommProvider: rommProvider,
      themeProvider: themeProvider,
    ),
  );

  // Background music initialization removed

  // SFX must never reopen the SoLoud engine while the screen is off: an open
  // AAudio stream holds AudioFlinger's 'AudioMix' wakelock and blocks SoC
  // suspend. This engine's screen-power truth is GameService.deviceScreenOn.
  SfxService.isScreenOn = () => GameService.deviceScreenOn.value;

  // Initialize SFX service for navigation sounds (fire-and-forget).
  SfxService().init().then((_) {
    // Apply persisted SFX preferences immediately.
    SfxService().setVolume(sqliteConfigProvider.config.sfxVolume);
    SfxService().setEnabled(sqliteConfigProvider.config.sfxEnabled);
  });
}

/// Startup strings for the current device locale.
///
/// The startup screens run before [FlutterLocalization] is initialized (the
/// saved app language lives in the database, which may still be on a mounting
/// SD card), so they read the raw locale maps directly. Unsupported device
/// locales fall back to English — the same default the app itself uses — and
/// missing keys degrade to an empty string rather than crashing the very
/// first frame.
Map<String, dynamic> _startupStrings() {
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  final languageTag = locale.toLanguageTag().replaceAll('-', '_');
  const translations = <String, Map<String, dynamic>>{
    'en': appLocaleEn,
    'es': appLocaleEs,
    'pt': appLocalePt,
    'ru': appLocaleRu,
    'zh': appLocaleZh,
    'zh_Hant': appLocaleZhHant,
    'fr': appLocaleFr,
    'de': appLocaleDe,
    'it': appLocaleIt,
    'id': appLocaleId,
    'ja': appLocaleJa,
    'ko': appLocaleKo,
  };
  return translations[languageTag] ??
      translations[locale.languageCode] ??
      appLocaleEn;
}

String _startupString(String key) {
  final value = _startupStrings()[key];
  return value is String ? value : '';
}

/// Shared chrome for the pre-initialization screens: logo, wordmark and a
/// caller-supplied status area.
///
/// These screens run before the database is readable, so they cannot ask
/// [ThemeProvider] for the selected theme. They read the palette mirrored into
/// [StartupThemeCache] on the last theme change instead, which keeps the whole
/// intro in the user's theme rather than always-dark chrome.
class _StartupScaffold extends StatefulWidget {
  const _StartupScaffold({
    required this.childrenBuilder,
    this.onKeyEvent,
    this.animatedLogo = false,
  });

  /// Builds the status area, given the resolved startup palette.
  ///
  /// Handed the context so callers can size their text with
  /// [SplashStatusLayout.scaleOf] — these screens run before `ScreenUtilInit`,
  /// so `.r` is not available to them.
  final List<Widget> Function(BuildContext context, StartupThemeColors colors)
  childrenBuilder;

  /// Show the shimmering logo instead of the static one. Used by the loading
  /// screen, where the shine doubles as the activity indicator; the error
  /// screen keeps the static logo (a shine would imply progress).
  final bool animatedLogo;

  /// Raw key handler used by the error screen. The gamepad navigation manager
  /// is not running this early, so gamepad buttons are read straight from the
  /// key events instead.
  final KeyEventResult Function(KeyEvent)? onKeyEvent;

  @override
  State<_StartupScaffold> createState() => _StartupScaffoldState();
}

class _StartupScaffoldState extends State<_StartupScaffold> {
  /// Starts on the dark chrome — the same color the Android splash hands over
  /// — and is replaced once the cache read returns. That read is a fast
  /// preferences lookup, so on a light theme the handoff lands within the
  /// first frames rather than being visible as a change of screen.
  StartupThemeColors _colors = StartupThemeColors.fallback;

  @override
  void initState() {
    super.initState();
    StartupThemeCache.load().then((colors) {
      if (mounted) setState(() => _colors = colors);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Same factor the shimmering splash uses, so the logo and the spacing
    // around it grow instead of being stranded at design size on a desktop
    // window. The wordmark takes the damped text scale — grown by the full
    // factor it reads as a banner rather than a caption under the glyph.
    final scale = SplashStatusLayout.scaleOf(context);
    final textScale = SplashStatusLayout.textScaleOf(context);
    final children = widget.childrenBuilder(context, _colors);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _colors.themeData,
      home: Scaffold(
        // Matches the selected theme's scaffold color so the handoff into the
        // themed splash doesn't read as a background jump.
        backgroundColor: _colors.background,
        body: Focus(
          autofocus: widget.onKeyEvent != null,
          onKeyEvent: widget.onKeyEvent == null
              ? null
              : (_, event) => widget.onKeyEvent!(event),
          // Animated mode pins the logo at the exact screen centre — the same
          // spot the Android 12+ splash icon occupies — with the status text
          // hung below it, so the native→Flutter handoff and the later screens
          // never move the logo. Shared with the scan splash so the
          // text/progress zone is one fixed place all intro. The error screen
          // keeps the simpler centred column with the wordmark.
          child: widget.animatedLogo
              ? SplashStatusLayout(children: children)
              : Center(
                  child: Padding(
                    padding: EdgeInsets.all(32 * scale),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/logo_transparent.png',
                          width: 112 * scale,
                          height: 112 * scale,
                        ),
                        SizedBox(height: 24 * scale),
                        Text(
                          'NeoStation',
                          style: TextStyle(
                            color: _colors.foreground,
                            fontSize: 28 * textScale,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                        SizedBox(height: 24 * scale),
                        ...children,
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Lightweight root displayed while the app waits for its persisted data.
class StartupLoadingApp extends StatefulWidget {
  const StartupLoadingApp({super.key});

  @override
  State<StartupLoadingApp> createState() => _StartupLoadingAppState();
}

class _StartupLoadingAppState extends State<StartupLoadingApp> {
  /// On a healthy device this screen lasts well under a second, so the
  /// "waiting for storage" line would only ever flash. Keep it invisible
  /// (but laid out, so nothing shifts) and fade it in once the wait has
  /// gone on long enough to actually be a wait.
  static const _textDelay = Duration(milliseconds: 1500);

  bool _showText = false;
  Timer? _textTimer;

  @override
  void initState() {
    super.initState();
    _textTimer = Timer(_textDelay, () {
      if (mounted) setState(() => _showText = true);
    });
  }

  @override
  void dispose() {
    _textTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _StartupScaffold(
      animatedLogo: true,
      childrenBuilder: (context, colors) {
        final scale = SplashStatusLayout.scaleOf(context);
        final textScale = SplashStatusLayout.textScaleOf(context);
        return [
          AnimatedOpacity(
            opacity: _showText ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 400),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 440 * scale),
              child: Text(
                _startupString(AppLocale.startupLoading),
                textAlign: TextAlign.center,
                // Same voice as the splash's status line: the app font (Anta),
                // small and dimmed. GoogleFonts falls back gracefully for the
                // first frames if the font isn't warmed up yet.
                style: GoogleFonts.anta(
                  color: colors.foreground.withValues(alpha: 0.6),
                  fontSize: 17 * textScale,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ];
      },
    );
  }
}

/// Shown when the configured user-data volume never appeared. Without this the
/// failure was swallowed by the catch-alls in `main()` and the app booted onto
/// an empty database, looking freshly installed.
class StartupStorageErrorApp extends StatelessWidget {
  const StartupStorageErrorApp({
    super.key,
    required this.storagePath,
    required this.onRetry,
    required this.onUseDefault,
  });

  final String? storagePath;
  final VoidCallback onRetry;
  final VoidCallback onUseDefault;

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space) {
      onRetry();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape) {
      onUseDefault();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return _StartupScaffold(
      onKeyEvent: _handleKey,
      childrenBuilder: (context, colors) {
        final scale = SplashStatusLayout.scaleOf(context);
        final textScale = SplashStatusLayout.textScaleOf(context);
        return [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 520 * scale),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _startupString(AppLocale.startupStorageUnavailable),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.foreground.withValues(alpha: 0.8),
                    fontSize: 16 * textScale,
                  ),
                ),
                if (storagePath != null && storagePath!.isNotEmpty) ...[
                  SizedBox(height: 12 * scale),
                  Text(
                    storagePath!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.foreground.withValues(alpha: 0.55),
                      fontSize: 13 * textScale,
                    ),
                  ),
                ],
                SizedBox(height: 24 * scale),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: onRetry,
                      child: Text(
                        _startupString(AppLocale.startupStorageRetry),
                      ),
                    ),
                    SizedBox(width: 16 * scale),
                    TextButton(
                      onPressed: onUseDefault,
                      child: Text(
                        _startupString(AppLocale.startupStorageUseDefault),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ];
      },
    );
  }
}

/// Resolves the user-data location once, up front, while the loading screen is
/// on screen.
///
/// [ConfigService.getUserDataPath] has a dozen call sites; before this, each
/// one could serially block for the full cold-boot timeout. Doing it here means
/// the wait happens exactly once and its failure is visible to the user
/// instead of being degraded into an empty library by downstream catch-alls.
Future<void> _awaitUserDataStorage() async {
  while (!await ConfigService.ensureUserDataStorageReady()) {
    final decision = Completer<void>();
    var useDefault = false;
    runApp(
      StartupStorageErrorApp(
        storagePath: ConfigService.unavailableStoragePath,
        onRetry: () {
          ConfigService.resetStorageAvailability();
          if (!decision.isCompleted) decision.complete();
        },
        onUseDefault: () {
          useDefault = true;
          if (!decision.isCompleted) decision.complete();
        },
      ),
    );
    await decision.future;
    runApp(const StartupLoadingApp());
    if (useDefault) {
      ConfigService.continueWithDefaultUserDataPath();
      return;
    }
  }
}

@pragma('vm:entry-point')
Future<void> subDisplay() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('--- [SECONDARY ENGINE] subDisplay signal received ---');

  // This engine has its own VideoPlayerPlatform: main()'s registerWith() ran in
  // the other isolate and never reached here, so without this the preview video
  // falls back to the platform default (ExoPlayer on Android) while the main
  // display plays through libmdk. ES-DE fallback videos can be .mkv/.avi/.wmv,
  // none of which ExoPlayer decodes, so the same game would play up top and
  // fail on the bottom screen.
  registerWith();

  // The secondary display runs in its own engine/isolate, so it must set up
  // localization independently — otherwise AppLocale.getString() falls back to
  // raw keys here. Mirror the persisted-language init done in main().
  String initLang = 'en';
  // The main engine only pushes the theme name once it has state to share, so
  // without this the display would open on the brightness fallback (black)
  // even for a user on a light theme. Read it from the same config row.
  String? initThemeName;

  // Same story for the Now Playing corner clock: the shared state carries the
  // 12/24-hour preference, but only once the main engine has pushed it, so seed
  // it here to avoid opening on the wrong format.
  bool initUse12HourClock = false;

  // Same screen-power guard as the main engine, keyed off this engine's own
  // notifier: the two engines share no memory, so GameService's is not live
  // here. Set before the config read below, which can throw — falling back to
  // the always-on default would leave this engine free to reopen the audio
  // device behind a dark screen, which is the whole bug being fixed.
  SfxService.isScreenOn = () => SecondaryAppsService.deviceScreenOn.value;

  try {
    final rawConfig = await ConfigRepository.getUserConfig();
    if (rawConfig != null && rawConfig['app_language'] != null) {
      initLang = rawConfig['app_language'].toString();
    }
    initThemeName = rawConfig?['theme_name']?.toString();
    initUse12HourClock =
        (int.tryParse(rawConfig?['use_12_hour_clock']?.toString() ?? '0') ??
            0) ==
        1;
    // Same story for UI sounds: this engine has its own SfxService singleton,
    // so the main engine's setEnabled/setVolume never reach it. The main engine
    // also pushes these through the shared state, but that can land after the
    // first tap — seed from the same config row so the very first sound already
    // respects the setting.
    SfxService().setEnabled(
      (int.tryParse(rawConfig?['sfx_enabled']?.toString() ?? '1') ?? 1) == 1,
    );
    SfxService().setVolume(
      double.tryParse(rawConfig?['sfx_volume']?.toString() ?? '0.75') ?? 0.75,
    );
  } catch (e) {
    debugPrint('Secondary display could not load saved config: $e');
  }
  await FlutterLocalization.instance.ensureInitialized();
  FlutterLocalization.instance.init(
    mapLocales: [
      MapLocale('en', AppLocale.en),
      MapLocale('es', AppLocale.es),
      MapLocale('pt', AppLocale.pt),
      MapLocale('ru', AppLocale.ru),
      MapLocale('zh', AppLocale.zh),
      MapLocale('zh_Hant', AppLocale.zhHant),
      MapLocale('fr', AppLocale.fr),
      MapLocale('de', AppLocale.de),
      MapLocale('it', AppLocale.it),
      MapLocale('id', AppLocale.id),
      MapLocale('ja', AppLocale.ja),
      MapLocale('ko', AppLocale.ko),
    ],
    initLanguageCode: initLang.isNotEmpty ? initLang : 'en',
  );

  runApp(
    SecondaryScreen(
      initialThemeName: initThemeName,
      initialUse12HourClock: initUse12HourClock,
    ),
  );
}

/// Provides MaterialLocalizations as a fallback for locales that Flutter's
/// global delegates do not support (e.g. zh_Hant). This prevents TextField
/// and other Material widgets from crashing when MaterialLocalizations.of
/// returns null.
class FallbackMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const FallbackMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      GlobalMaterialLocalizations.delegate.load(const Locale('en'));

  @override
  bool shouldReload(
    covariant LocalizationsDelegate<MaterialLocalizations> old,
  ) => false;
}

class MyApp extends StatefulWidget {
  final FileProvider fileProvider;
  final AuthService authService;
  final SqliteConfigProvider sqliteConfigProvider;
  final SqliteDatabaseProvider sqliteDatabaseProvider;
  final NeoSyncService neoSyncService;
  final NeoSyncProvider neoSyncProvider;
  final RommProvider rommProvider;

  /// Built in `main()` with the saved theme already resolved, so the first
  /// frame paints in the user's theme rather than the brightness fallback.
  final ThemeProvider themeProvider;

  const MyApp({
    super.key,
    required this.fileProvider,
    required this.authService,
    required this.sqliteConfigProvider,
    required this.sqliteDatabaseProvider,
    required this.neoSyncService,
    required this.neoSyncProvider,
    required this.rommProvider,
    required this.themeProvider,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    _locale = FlutterLocalization.instance.currentLocale;
    FlutterLocalization.instance.onTranslatedLanguage = (Locale? locale) {
      if (mounted) setState(() => _locale = locale);
    };
    // Once the main UI has painted its first frame, tell the secondary display
    // the app is ready so it can slide the app dock into place (rather than
    // showing it fully-formed while the app is still cold-starting).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.sqliteConfigProvider.markAppReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => MenuAppProvider()),
        ChangeNotifierProvider.value(value: widget.sqliteConfigProvider),
        ChangeNotifierProvider.value(value: widget.sqliteDatabaseProvider),
        ChangeNotifierProvider.value(value: widget.fileProvider),
        ChangeNotifierProvider.value(value: widget.authService),
        ChangeNotifierProvider.value(value: widget.neoSyncService),
        ChangeNotifierProvider.value(value: widget.neoSyncProvider),
        ChangeNotifierProvider.value(value: SyncManager.instance),
        ChangeNotifierProvider(create: (context) => BillingService()),
        ChangeNotifierProvider(create: (context) => NotificationService()),
        ChangeNotifierProvider.value(value: widget.themeProvider),
        ChangeNotifierProvider(create: (context) => ScrapingProvider()),
        ChangeNotifierProvider(
          // Eager (not lazy): auto-login must run at startup so RA is connected
          // regardless of which screen is shown first. Otherwise launching a
          // game straight from the systems/recent screen (which never reads the
          // provider) would find RA disconnected and skip the secondary panel.
          lazy: false,
          create: (context) => RetroAchievementsProvider()..initialize(),
        ),
        ChangeNotifierProvider.value(value: widget.rommProvider),
        ChangeNotifierProvider(create: (context) => SystemBackgroundProvider()),
        ChangeNotifierProvider(
          // Eager: the systems carousel/grid paints the Collections card's game
          // count on the first frame it builds, and that card is on the very
          // first screen. A lazy create would leave the count at zero until
          // something else read the provider.
          lazy: false,
          create: (context) => CollectionsProvider()..load(),
        ),
        ChangeNotifierProvider(
          // Eager: the theme manifest is a network fetch, and during first-run
          // setup the wizard's art-pack step is the ONLY consumer of this
          // provider. A lazy create would not start loadThemes() until that
          // final step renders, leaving `themes` empty if the user advances
          // before the fetch resolves — the art pack then silently fails to
          // apply. Starting at launch gives the fetch the whole wizard to
          // complete.
          lazy: false,
          create: (context) => NeoAssetsProvider()..init(),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return ScreenUtilInit(
            designSize: const Size(640, 480),
            minTextAdapt: true,
            splitScreenMode: true,
            builder: (screenUtilContext, child) {
              logDisplayMetrics(screenUtilContext, 'main');
              return FocusTraversalGroup(
                policy: NoFocusTraversalPolicy(),
                child: Shortcuts(
                  shortcuts: {
                    LogicalKeySet(
                      LogicalKeyboardKey.alt,
                      LogicalKeyboardKey.enter,
                    ): const ToggleFullscreenIntent(),
                  },
                  child: Actions(
                    actions: {ToggleFullscreenIntent: ToggleFullscreenAction()},
                    child: MaterialApp(
                      navigatorKey: rootNavigatorKey,
                      debugShowCheckedModeBanner: false,
                      title: 'NeoStation',
                      locale: _locale,
                      localizationsDelegates: [
                        const FallbackMaterialLocalizationsDelegate(),
                        ...FlutterLocalization.instance.localizationsDelegates,
                      ],
                      supportedLocales:
                          FlutterLocalization.instance.supportedLocales,
                      scrollBehavior: CustomScrollBehavior(),
                      showPerformanceOverlay: false,
                      checkerboardRasterCacheImages: false,
                      checkerboardOffscreenLayers: false,
                      showSemanticsDebugger: false,
                      builder: (context, child) {
                        // The back swipe lives above every route and dialog so
                        // touch users have a way back on any screen whose
                        // navigation layer binds B. Nothing else on screen
                        // offers one: B is a gamepad button and the system
                        // back gesture belongs to the platform.
                        return Stack(children: [child!, const BackSwipeZone()]);
                      },
                      theme: themeProvider.currentTheme.copyWith(
                        textTheme: GoogleFonts.antaTextTheme(
                          themeProvider.currentTheme.textTheme,
                        ),
                        iconTheme: const IconThemeData(fill: 1.0),
                        visualDensity: VisualDensity.adaptivePlatformDensity,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        pageTransitionsTheme: PageTransitionsTheme(
                          builders: {
                            TargetPlatform.android:
                                FadeUpwardsPageTransitionsBuilder(),
                            TargetPlatform.iOS:
                                FadeUpwardsPageTransitionsBuilder(),
                            TargetPlatform.windows:
                                FadeUpwardsPageTransitionsBuilder(),
                            TargetPlatform.macOS:
                                FadeUpwardsPageTransitionsBuilder(),
                            TargetPlatform.linux:
                                FadeUpwardsPageTransitionsBuilder(),
                          },
                        ),
                      ),
                      home: PermissionCheckWrapper(
                        child: AppLifecycleHandler(child: MainScreen()),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
