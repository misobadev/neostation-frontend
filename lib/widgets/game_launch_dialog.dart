import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'dart:io';
import 'dart:async';
import '../sync/i_sync_provider.dart';
import '../providers/file_provider.dart';
import '../models/system_model.dart';
import '../models/game_model.dart';
import '../models/neo_sync_models.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/logger_service.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../utils/gamepad_nav.dart';

class GameLaunchDialog extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final FileProvider fileProvider;
  final ISyncProvider syncProvider;
  final VoidCallback onGameClosed;

  const GameLaunchDialog({
    super.key,
    required this.game,
    required this.system,
    required this.fileProvider,
    required this.syncProvider,
    required this.onGameClosed,
  });

  @override
  State<GameLaunchDialog> createState() => _GameLaunchDialogState();
}

class _GameLaunchDialogState extends State<GameLaunchDialog> {
  late GamepadNavigation _dialogGamepadNav;
  static final _log = LoggerService.instance;

  bool _closeCalled = false;
  bool _onGameClosedFired = false;
  bool _postSyncStarted = false;
  bool _postSyncComplete = false;
  String _neoSyncStatus = '';
  String _gameStatus = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_neoSyncStatus.isEmpty) {
      _neoSyncStatus = AppLocale.neoSyncSynchronizing.getString(context);
    }
    if (_gameStatus.isEmpty) {
      _gameStatus = AppLocale.launchingGame.getString(context);
    }
  }

  @override
  void initState() {
    super.initState();
    GameLaunchManager().addListener(_onManagerChanged);

    _dialogGamepadNav = GamepadNavigation(
      onBack: () => GameLaunchManager().userDismiss(),
      onSelectItem: () => GameLaunchManager().userDismiss(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dialogGamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'game_launch_dialog',
        onActivate: () => _dialogGamepadNav.activate(),
        onDeactivate: () => _dialogGamepadNav.deactivate(),
      );
      _performPreSync();
    });
  }

  @override
  void dispose() {
    GameLaunchManager().removeListener(_onManagerChanged);
    GamepadNavigationManager.popLayer('game_launch_dialog');
    _dialogGamepadNav.dispose();
    // Always finalize manager: idempotent, ensures music/SFX restore even if
    // the dialog was dismissed externally (barrier tap) or timer hadn't fired yet.
    GameLaunchManager().onDialogDisposed();
    if (!_onGameClosedFired) {
      // onGameClosed was not yet fired — covers two cases:
      // 1. Normal emergency: dialog disposed before close sequence started.
      // 2. Race: _closeDialog() set _closeCalled=true (timer started) but
      //    barrier tap dismissed the dialog before the 1s timer fired.
      //    The timer will see mounted=false and skip onGameClosed, so we
      //    must call it here to restore the UI.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onGameClosed(),
      );
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Manager listener
  // ---------------------------------------------------------------------------

  void _onManagerChanged() {
    if (!mounted) return;
    final phase = GameLaunchManager().phase;

    if (phase == GameLaunchPhase.syncing && !_postSyncStarted) {
      _postSyncStarted = true;
      _performPostSync();
    }

    if (phase == GameLaunchPhase.closed) {
      _closeDialog();
    }

    if (mounted) {
      setState(() {
        switch (phase) {
          case GameLaunchPhase.launching:
            _gameStatus = AppLocale.launchingGame.getString(context);
            break;
          case GameLaunchPhase.playing:
            _gameStatus = AppLocale.gameExecuting.getString(context);
            break;
          case GameLaunchPhase.syncing:
          case GameLaunchPhase.closed:
            _gameStatus = AppLocale.closingGame.getString(context);
            break;
          default:
            break;
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------

  Future<void> _performPreSync() async {
    if (!widget.syncProvider.isAuthenticated) {
      if (mounted) {
        setState(
          () =>
              _neoSyncStatus = AppLocale.neoSyncNotConnected.getString(context),
        );
      }
      return;
    }
    try {
      await widget.syncProvider.syncGameSavesBeforeLaunch(widget.game);
      if (mounted) setState(() => _neoSyncStatus = _getNeoSyncStatusText());
    } catch (e) {
      _log.e('GameLaunchDialog: Pre-sync failed: $e');
      if (mounted) {
        setState(
          () =>
              _neoSyncStatus = AppLocale.neoSyncSynchronized.getString(context),
        );
      }
    }
  }

  Future<void> _performPostSync() async {
    // End game session (saves playtime, unblocks Android native gamepad, clears state).
    await GameService.endGameSession();

    if (mounted) {
      setState(
        () =>
            _neoSyncStatus = AppLocale.neoSyncSynchronizing.getString(context),
      );
    }

    try {
      await widget.syncProvider.syncGameSavesAfterClose(widget.game);
    } catch (e) {
      _log.e('GameLaunchDialog: Post-sync failed: $e');
    }

    if (mounted) {
      setState(() {
        _neoSyncStatus = _getNeoSyncStatusText();
        _postSyncComplete = true;
      });
    }

    // Signal manager that everything is done → triggers closed phase → _closeDialog.
    GameLaunchManager().completeClose();
  }

  // ---------------------------------------------------------------------------
  // Close
  // ---------------------------------------------------------------------------

  void _closeDialog() {
    if (_closeCalled || !mounted) return;
    _closeCalled = true;
    Timer(const Duration(seconds: 1), () {
      if (mounted) {
        _onGameClosedFired = true;
        Navigator.of(context).pop();
        widget.onGameClosed();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // NeoSync text helper
  // ---------------------------------------------------------------------------

  String _getNeoSyncStatusText() {
    if (!widget.syncProvider.isAuthenticated) {
      return AppLocale.neoSyncNotConnected.getString(context);
    }

    final gameState = widget.syncProvider.getGameSyncState(widget.game.romname);
    if (gameState != null) {
      switch (gameState.status) {
        case GameSyncStatus.upToDate:
          return AppLocale.neoSyncSynchronized.getString(context);
        case GameSyncStatus.localOnly:
          return AppLocale.neoSyncLocalSavesOnly.getString(context);
        case GameSyncStatus.cloudOnly:
          return AppLocale.neoSyncCloudSavesOnly.getString(context);

        case GameSyncStatus.noSaveFound:
          return AppLocale.neoSyncNoSave.getString(context);
        case GameSyncStatus.disabled:
          return AppLocale.neoSyncCloudSyncDisabled.getString(context);
        case GameSyncStatus.quotaExceeded:
          return AppLocale.neoSyncQuotaExceeded.getString(context);
        default:
          return AppLocale.neoSyncSynchronized.getString(context);
      }
    }
    return AppLocale.neoSyncSynchronized.getString(context);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final systemFolderName =
        widget.system.folderName == 'all' &&
            widget.game.systemFolderName != null
        ? widget.game.systemFolderName!
        : widget.system.primaryFolderName;
    final wheelPath = widget.game.getImagePath(
      systemFolderName,
      'wheels',
      widget.fileProvider,
    );

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (KeyEvent event) {
        if (event is KeyDownEvent) {
          final isCloseKey =
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.keyZ ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA ||
              event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.backspace ||
              event.logicalKey == LogicalKeyboardKey.keyX ||
              event.logicalKey == LogicalKeyboardKey.gameButtonB;
          if (isCloseKey) GameLaunchManager().userDismiss();
        }
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 320.r,
          padding: EdgeInsets.all(16.r),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(16.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 100.r,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7.w),
                  child: Image.file(
                    File(wheelPath),
                    fit: BoxFit.contain,
                    cacheWidth: 400,
                    errorBuilder: (context, error, stackTrace) {
                      final systemLogoPath =
                          'assets/images/systems/logos/${widget.system.folderName}.webp';
                      return Container(
                        padding: EdgeInsets.all(12.r),
                        child: Image.asset(
                          systemLogoPath,
                          fit: BoxFit.contain,
                          cacheWidth: 300,
                          errorBuilder: (context, err, stack) {
                            return Icon(
                              Symbols.videogame_asset_rounded,
                              size: 40.r,
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.5),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),

              SizedBox(height: 4.r),

              Text(
                _gameStatus,
                style: TextStyle(
                  fontSize: 24.r,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                  letterSpacing: 0.5.r,
                ),
              ),

              SizedBox(height: 4.r),

              Text(
                widget.game.name.isNotEmpty
                    ? widget.game.name
                    : widget.game.romname,
                style: TextStyle(
                  fontSize: 16.r,
                  fontWeight: FontWeight.w400,
                  color: Theme.of(context).colorScheme.onSurface,
                  letterSpacing: 0.3.r,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              SizedBox(height: 4.r),

              if (widget.syncProvider.isAuthenticated)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_neoSyncStatus ==
                            AppLocale.neoSyncSynchronizing.getString(context) &&
                        !_postSyncComplete)
                      SizedBox(
                        width: 16.r,
                        height: 16.r,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.r,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      )
                    else
                      Icon(
                        _neoSyncStatus == AppLocale.error.getString(context)
                            ? Symbols.error_outline_rounded
                            : _neoSyncStatus ==
                                  AppLocale.neoSyncNotConnected.getString(
                                    context,
                                  )
                            ? Symbols.cloud_off_rounded
                            : Symbols.check_circle_rounded,
                        size: 24.r,
                        color:
                            _neoSyncStatus == AppLocale.error.getString(context)
                            ? Colors.red
                            : _neoSyncStatus ==
                                  AppLocale.neoSyncNotConnected.getString(
                                    context,
                                  )
                            ? Colors.orange
                            : Colors.green,
                      ),

                    SizedBox(width: 4.r),

                    Text(
                      _neoSyncStatus,
                      style: TextStyle(
                        fontSize: 14.r,
                        fontWeight: FontWeight.w400,
                        color: Theme.of(context).colorScheme.onSurface,
                        letterSpacing: 0.2.r,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
