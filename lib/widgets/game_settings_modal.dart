import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../models/game_model.dart';
import '../../../models/system_model.dart';

/// Settings modal for a specific game
class GameSettingsModal extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final Function(bool enabled) onCloudSyncChanged;

  const GameSettingsModal({
    super.key,
    required this.game,
    required this.system,
    required this.onCloudSyncChanged,
  });

  @override
  State<GameSettingsModal> createState() => _GameSettingsModalState();
}

class _GameSettingsModalState extends State<GameSettingsModal> {
  late bool _cloudSyncEnabled;

  @override
  void initState() {
    super.initState();
    _cloudSyncEnabled = widget.game.cloudSyncEnabled ?? true;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400.w,
        padding: EdgeInsets.all(24.w),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
              Theme.of(context).colorScheme.surface.withValues(alpha: 0.3),
            ],
          ),
          borderRadius: BorderRadius.circular(16.w),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.4),
              blurRadius: 20.w,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.2),
              blurRadius: 40.w,
              offset: const Offset(0, 16),
            ),
          ],
          border: Border.all(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.1),
            width: 1.w,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 48.w,
                  height: 48.w,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        widget.system.colorAsColor.withValues(alpha: 0.8),
                        widget.system.colorAsColor.withValues(alpha: 0.4),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24.w),
                  ),
                  child: Icon(Symbols.settings_rounded, color: Colors.white, size: 24.sp),
                ),
                SizedBox(width: 16.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.gameSettings.getString(context),
                        style: TextStyle(
                          fontSize: 20.sp,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0.5),
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        widget.game.name.isNotEmpty
                            ? widget.game.name
                            : widget.game.romname,
                        style: TextStyle(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w400,
                          color: Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0.5),
                          letterSpacing: 0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    Symbols.close_rounded,
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.5),
                    size: 24.sp,
                  ),
                ),
              ],
            ),
            SizedBox(height: 24.h),

            // Cloud Sync Setting
            Container(
              padding: EdgeInsets.all(16.w),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.3),
                    Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.2),
                  ],
                ),
                borderRadius: BorderRadius.circular(12.w),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.1),
                  width: 1.w,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40.w,
                    height: 40.w,
                    decoration: BoxDecoration(
                      color: _cloudSyncEnabled
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.6)
                          : Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(20.w),
                    ),
                    child: Icon(
                      _cloudSyncEnabled ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded,
                      color: Colors.white,
                      size: 20.sp,
                    ),
                  ),
                  SizedBox(width: 16.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.cloudSync.getString(context),
                          style: TextStyle(
                            fontSize: 16.sp,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.5),
                            letterSpacing: 0.3,
                          ),
                        ),
                        SizedBox(height: 4.h),
                        Text(
                          _cloudSyncEnabled
                              ? AppLocale.neoSyncSavesSync.getString(context)
                              : AppLocale.cloudSyncOff.getString(context),
                          style: TextStyle(
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w400,
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.5),
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _cloudSyncEnabled,
                    onChanged: (value) {
                      setState(() {
                        _cloudSyncEnabled = value;
                      });
                      widget.onCloudSyncChanged(value);
                    },
                    activeThumbColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.5),
                    activeTrackColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    inactiveThumbColor: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.5),
                    inactiveTrackColor: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.2),
                  ),
                ],
              ),
            ),

            SizedBox(height: 24.h),

            // Status indicator
            if (_cloudSyncEnabled)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8.w),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.2),
                    width: 1.w,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.check_circle_rounded,
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.5),
                      size: 16.sp,
                    ),
                    SizedBox(width: 8.w),
                    Text(
                      AppLocale.cloudSyncEnabled.getString(context),
                      style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.5),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.3),
                      Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.2),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(8.w),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.2),
                    width: 1.w,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.cloud_off_rounded,
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.5),
                      size: 16.sp,
                    ),
                    SizedBox(width: 8.w),
                    Text(
                      AppLocale.cloudSyncDisabled.getString(context),
                      style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.5),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
