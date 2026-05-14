import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// A configuration modal for managing per-game settings, such as cloud synchronization preferences.
class GameSettingsModal extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final ISyncProvider syncProvider;
  final bool enableGamepad;

  const GameSettingsModal({
    super.key,
    required this.game,
    required this.system,
    required this.syncProvider,
    this.enableGamepad = false,
  });

  @override
  State<GameSettingsModal> createState() => _GameSettingsModalState();
}

class _GameSettingsModalState extends State<GameSettingsModal> {
  static final _log = LoggerService.instance;

  late bool _cloudSyncEnabled;
  bool _isLoading = false;
  GamepadNavigation? _gamepadNav;

  @override
  void initState() {
    super.initState();
    _cloudSyncEnabled = widget.game.cloudSyncEnabled ?? true;
    if (widget.enableGamepad) {
      _initializeGamepad();
    }
  }

  /// Initializes the gamepad navigation manager for the modal lifecycle.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (!_isLoading && widget.syncProvider.isAuthenticated) {
          _toggleCloudSync(!_cloudSyncEnabled);
        } else if (!widget.syncProvider.isAuthenticated) {
          // Provide feedback if NeoSync services are unreachable/unauthenticated.
          if (mounted) {
            AppNotification.showNotification(
              context,
              'NeoSync is not connected. Please connect to NeoSync first.',
              type: NotificationType.info,
            );
          }
        }
      },
      onBack: () {
        Navigator.of(context).pop();
      },
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  @override
  void dispose() {
    _gamepadNav?.dispose();
    super.dispose();
  }

  /// Orchestrates the cloud synchronization toggle, updating both local persistence and provider state.
  Future<void> _toggleCloudSync(bool value) async {
    if (!widget.syncProvider.isAuthenticated) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          'NeoSync is not connected. Please connect to NeoSync first.',
          type: NotificationType.info,
        );
      }
      return;
    }

    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Resolve the authoritative system folder (handling 'all' / unified views).
      final targetSystemFolder =
          widget.system.folderName == 'all' &&
              widget.game.systemFolderName != null
          ? widget.game.systemFolderName!
          : widget.system.folderName;

      // Persist to local SQLite storage.
      await GameRepository.updateCloudSyncEnabled(
        targetSystemFolder,
        widget.game.romname,
        value,
      );

      // Propagate state update to the sync provider.
      await widget.syncProvider.updateGameCloudSyncEnabled(
        widget.game.romname,
        value,
      );

      setState(() {
        _cloudSyncEnabled = value;
      });

      if (mounted) {
        AppNotification.showNotification(
          context,
          'Cloud sync ${value ? 'enabled' : 'disabled'} for ${GameUtils.formatGameName(widget.game.name)}',
          type: value ? NotificationType.success : NotificationType.info,
        );
      }
    } catch (e) {
      _log.e('Per-game cloud sync update failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          'Failed to update cloud sync setting',
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNeoSyncConnected = widget.syncProvider.isAuthenticated;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
          ),
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            width: 1.r,
          ),
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
            // Header Section: Title and Close control.
            Container(
              padding: EdgeInsets.all(6.r),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.2),
                  ],
                ),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16.r),
                  topRight: Radius.circular(16.r),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1.r,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.settings_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 24.r,
                  ),
                  SizedBox(width: 6.r),
                  Expanded(
                    child: Text(
                      AppLocale.gameSettings.getString(context),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Symbols.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Content Section: Game identity summary and toggleable settings.
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(8.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Game Identity Summary.
                    Container(
                      padding: EdgeInsets.all(8.r),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.5),
                            Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.3),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                          width: 1.r,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 32.r,
                            height: 32.r,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  widget.system.colorAsColor.withValues(
                                    alpha: 0.8,
                                  ),
                                  widget.system.colorAsColor.withValues(
                                    alpha: 0.4,
                                  ),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(20.r),
                            ),
                            child: Icon(
                              Symbols.videogame_asset_rounded,
                              color: Colors.white,
                              size: 16.r,
                            ),
                          ),
                          SizedBox(width: 12.r),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.game.name.isNotEmpty
                                      ? widget.game.name
                                      : widget.game.romname,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14.r,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  widget.system.realName,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 12.r,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 12.r),

                    // Cloud Sync Setting Item.
                    if (isNeoSyncConnected)
                      Container(
                        padding: EdgeInsets.all(12.r),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12.r),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.1),
                            width: 1.r,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36.r,
                              height: 36.r,
                              decoration: BoxDecoration(
                                color: _cloudSyncEnabled
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(18.r),
                              ),
                              child: Icon(
                                _cloudSyncEnabled
                                    ? Symbols.cloud_done_rounded
                                    : Symbols.cloud_off_rounded,
                                color: Colors.white,
                                size: 18.r,
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    AppLocale.cloudSync.getString(context),
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.r,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _cloudSyncEnabled
                                        ? AppLocale.cloudSyncEnabled.getString(
                                            context,
                                          )
                                        : AppLocale.cloudSyncDisabled.getString(
                                            context,
                                          ),
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 12.r,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_isLoading)
                              SizedBox(
                                width: 24.r,
                                height: 24.r,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            else
                              Switch(
                                value: _cloudSyncEnabled,
                                onChanged: _toggleCloudSync,
                                activeThumbColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
