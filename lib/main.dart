import 'package:neostation/providers/menu_app_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/palette_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/main_screen.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/steam_scraper_service.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/widgets/app_lifecycle_handler.dart';
import 'package:neostation/widgets/permission_check_wrapper.dart';
import 'package:neostation/utils/custom_scroll_behavior.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:fvp/fvp.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:window_manager/window_manager.dart';
import 'package:neostation/screens/secondary_screen/secondary_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';

// Política personalizada para deshabilitar navegación por teclado
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
        '🖥️ Toggle fullscreen (macOS): current=$isFullscreen, setting=${!isFullscreen}',
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

/// Configures the Flutter [ImageCache] based on platform and available RAM.
///
/// Android: reads total memory via [DeviceInfoPlugin] and applies tiered limits.
/// Desktop (Windows/macOS/Linux): applies generous defaults.
Future<void> _configureImageCache() async {
  try {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      LoggerService.instance.i(
        'Android device detected: ${info.model}, RAM: ${info.physicalRamSize} MB',
      );
      final ramGb = info.physicalRamSize ~/ 1024;
      LoggerService.instance.i(
        'Configuring image cache for Android device with $ramGb GB RAM',
      );
      int maxBytes;
      int maxSize;

      if (ramGb <= 2) {
        maxBytes = 40 * 1024 * 1024;
        maxSize = 300;
      } else if (ramGb <= 4) {
        maxBytes = 80 * 1024 * 1024;
        maxSize = 600;
      } else if (ramGb <= 8) {
        maxBytes = 200 * 1024 * 1024;
        maxSize = 1000;
      } else {
        maxBytes = 400 * 1024 * 1024;
        maxSize = 1500;
      }

      LoggerService.instance.i(
        'Setting image cache limits: maxSize=$maxSize, maxBytes=${maxBytes ~/ (1024 * 1024)} MB',
      );

      PaintingBinding.instance.imageCache.maximumSize = maxSize;
      PaintingBinding.instance.imageCache.maximumSizeBytes = maxBytes;
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      PaintingBinding.instance.imageCache.maximumSize = 2000;
      PaintingBinding.instance.imageCache.maximumSizeBytes = 400 * 1024 * 1024;
    } else {
      PaintingBinding.instance.imageCache.maximumSize = 1000;
      PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * 1024 * 1024;
    }
  } catch (_) {
    PaintingBinding.instance.imageCache.maximumSize = 1000;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * 1024 * 1024;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _configureImageCache();

  final log = LoggerService.instance;
  await log.init();
  log.i('Starting NeoStation...');

  // Inicializar window_manager para desktop (solo Windows y macOS)
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // Cargar configuración de fullscreen
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
        LoggerService.instance.i('Initializing window manager...');
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = WindowOptions(
          size: const Size(1280, 720),
          alwaysOnTop: false,
          skipTaskbar: false,
          minimumSize: const Size(640, 480),
          fullScreen: isFullscreen,
        );

        windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setFullScreen(true);
        });
      }
      FullscreenNotifier().notifyFullscreenChanged(true);
    } else {
      if (Platform.isWindows || Platform.isLinux) {
        FullScreenWindow.setFullScreen(false);
      } else if (Platform.isMacOS) {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = WindowOptions(
          size: const Size(1280, 720),
          alwaysOnTop: false,
          skipTaskbar: false,
          minimumSize: const Size(640, 480),
          fullScreen: isFullscreen,
        );

        windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setFullScreen(false);
        });
      }
      FullscreenNotifier().notifyFullscreenChanged(false);
    }

    log.i('Window manager initialized');
  }

  // Inicializar fvp para soporte extendido de video (Windows, Linux, etc.)
  registerWith();

  // Configurar manejo global de errores para evitar crashesß
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

  // Inicializar localización con idioma persistido
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
    ],
    initLanguageCode: initLang.isNotEmpty ? initLang : 'en',
  );

  // Inicializar AuthService antes de mostrar la app
  final authService = AuthService();
  await authService.initialize();

  // Inicializar providers críticos
  final sqliteConfigProvider = SqliteConfigProvider();
  final sqliteDatabaseProvider = SqliteDatabaseProvider();

  try {
    // 1. Inicializar ConfigProvider primero (sincroniza sistemas)
    await sqliteConfigProvider.initialize();

    // 2. Inicializar DatabaseProvider (carga juegos basándose en sistemas sincronizados)
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
      // Verificar si hay una sesión de juego pendiente (app fue matada)
      await GameService.checkPendingGameSession();
    } catch (e) {
      log.e('Error initializing GameService: $e');
    }
  }

  // Build NeoSync provider graph before runApp so SyncManager can register it.
  final neoSyncService = NeoSyncService();
  final neoSyncProvider = NeoSyncProvider(neoSyncService);
  neoSyncProvider.setAuthService(authService);
  authService.addListener(() {
    neoSyncProvider.setAuthService(authService);
  });

  final neoSyncAdapter = NeoSyncAdapter(neoSyncProvider);
  SyncManager.instance.register(neoSyncAdapter);
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
    ),
  );

  // Background music initialization removed

  // Initialize SFX service for navigation sounds (fire-and-forget).
  SfxService().init().then((_) {
    // Apply the persisted enabled/disabled preference immediately.
    SfxService().setEnabled(sqliteConfigProvider.config.sfxEnabled);
  });
}

@pragma('vm:entry-point')
void subDisplay() {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('--- [SECONDARY ENGINE] subDisplay signal received ---');
  runApp(const SecondaryScreen());
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

  const MyApp({
    super.key,
    required this.fileProvider,
    required this.authService,
    required this.sqliteConfigProvider,
    required this.sqliteDatabaseProvider,
    required this.neoSyncService,
    required this.neoSyncProvider,
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
        ChangeNotifierProvider(create: (context) => PaletteProvider()),
        ChangeNotifierProvider(create: (context) => ScrapingProvider()),
        ChangeNotifierProvider(
          // Eager (not lazy): auto-login must run at startup so RA is connected
          // regardless of which screen is shown first. Otherwise launching a
          // game straight from the systems/recent screen (which never reads the
          // provider) would find RA disconnected and skip the secondary panel.
          lazy: false,
          create: (context) => RetroAchievementsProvider()..initialize(),
        ),
        ChangeNotifierProvider(create: (context) => SystemBackgroundProvider()),
        ChangeNotifierProvider(
          create: (context) => NeoAssetsProvider()..init(),
        ),
      ],
      child: Consumer<PaletteProvider>(
        builder: (context, paletteProvider, child) {
          return ScreenUtilInit(
            designSize: const Size(640, 480),
            minTextAdapt: true,
            splitScreenMode: true,
            builder: (_, child) {
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
                        return MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            textScaler: MediaQuery.of(context).textScaler.clamp(
                              minScaleFactor: 0.6,
                              maxScaleFactor: 1.4,
                            ),
                          ),
                          child: child!,
                        );
                      },
                      theme: paletteProvider.currentPalette.copyWith(
                        textTheme: GoogleFonts.antaTextTheme(
                          paletteProvider.currentPalette.textTheme,
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
