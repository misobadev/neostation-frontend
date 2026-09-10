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
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../services/logger_service.dart';
import '../utils/gamepad_nav.dart';
import '../constants/system_folder_names.dart';

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

  bool _closeCalled = false;
  bool _onGameClosedFired = false;
  bool _navLayerReleased = false;
  bool _postSyncStarted = false;
  String _gameStatus = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      if (!mounted || _navLayerReleased) return;
      _dialogGamepadNav.initialize();
      // Modal: launching frees memory and clears caches, so background screens
      // remount while this dialog is up. Without the flag they push their own
      // layer on top of it and take the controller off the dialog — including
      // its own dismiss buttons — for the rest of the session.
      GamepadNavigationManager.pushLayer(
        'game_launch_dialog',
        onActivate: () => _dialogGamepadNav.activate(),
        onDeactivate: () => _dialogGamepadNav.deactivate(),
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GameLaunchManager().removeListener(_onManagerChanged);
    _releaseNavLayer();
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
  // Post-game cleanup
  // ---------------------------------------------------------------------------

  Future<void> _performPostSync() async {
    // End game session (saves playtime, unblocks Android native gamepad, clears state).
    //
    // The teardown runs in a try/finally because this dialog is the only thing
    // that can close itself: if [GameService.endGameSession] throws, the
    // `completeClose()` below never runs, the dialog never reaches its closed
    // phase, and the user is left staring at "Closing game" with no way out
    // but dismissing it by hand. Nothing surfaces either — an unhandled async
    // error here does not reach `FlutterError.onError`. Whatever happens to
    // the session, the dialog must still be able to go away.
    try {
      await GameService.endGameSession();
    } catch (e, stack) {
      LoggerService.instance.e('Error ending game session: $e\n$stack');
    } finally {
      // Signal manager that everything is done → triggers closed phase → _closeDialog.
      GameLaunchManager().completeClose();
    }
  }

  // ---------------------------------------------------------------------------
  // Close
  // ---------------------------------------------------------------------------

  /// Gives up the dialog's modal navigation layer.
  ///
  /// Called the moment the dialog is dismissed rather than waiting for
  /// [dispose]: popping the route only *starts* the exit transition, so this
  /// State — and its layer — outlive the dismissal by the length of that
  /// animation. A *modal* layer left behind that way is not inert. It swallows
  /// every non-modal push in that window: [GamepadNavigationManager.pushLayer]
  /// slots those beneath the modal and deliberately does not activate them.
  ///
  /// The games grid lands in exactly that window. The list was emptied to free
  /// RAM for the emulator, so the grid unmounted at launch and remounts as soon
  /// as [GameLaunchDialog.onGameClosed] reloads the games — one short database
  /// read plus a frame after the pop. When it lost that race it registered
  /// without ever taking the controller, and the layer that did have it was the
  /// host list. Its navigator drove the grid: D-pad up/down stepped one game
  /// (reading as left/right across the grid) and left/right walked the details
  /// tabs, with no way back but leaving the system and entering it again.
  ///
  /// Idempotent, and it also suppresses the push for a dialog dismissed before
  /// its first post-frame callback ever ran.
  void _releaseNavLayer() {
    if (_navLayerReleased) return;
    _navLayerReleased = true;
    GamepadNavigationManager.popLayer('game_launch_dialog');
  }

  void _closeDialog() {
    if (_closeCalled || !mounted) return;
    _closeCalled = true;
    Timer(const Duration(seconds: 1), () {
      if (mounted) {
        _onGameClosedFired = true;
        // Before the pop: the layer must be gone by the time onGameClosed
        // remounts the games view. See [_releaseNavLayer].
        _releaseNavLayer();
        Navigator.of(context).pop();
        widget.onGameClosed();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final systemFolderName =
        SystemFolderNames.isAggregate(widget.system.folderName) &&
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
                          'assets/images/logos/${widget.system.folderName}.webp';
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
            ],
          ),
        ),
      ),
    );
  }
}
