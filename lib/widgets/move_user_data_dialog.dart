import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';

import 'core_footer.dart';

/// Heavier confirmation shown before relocating the user-data folder from
/// Settings. Unlike the wizard's [FolderNotEmptyDialog], this actually MOVES
/// data, so it spells out the source → destination move and (when relevant)
/// notes that the destination already has files.
///
/// Returns `true` if the user confirms the move.
class MoveUserDataDialog extends StatefulWidget {
  final String fromPath;
  final String toPath;
  final int destItemCount;

  /// Shown first in the body when the destination isn't the folder the user
  /// picked, saying why.
  final String? notice;

  const MoveUserDataDialog({
    super.key,
    required this.fromPath,
    required this.toPath,
    required this.destItemCount,
    this.notice,
  });

  static Future<bool> show(
    BuildContext context, {
    required String fromPath,
    required String toPath,
    required int destItemCount,
    String? notice,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MoveUserDataDialog(
        fromPath: fromPath,
        toPath: toPath,
        destItemCount: destItemCount,
        notice: notice,
      ),
    );
    return result ?? false;
  }

  @override
  State<MoveUserDataDialog> createState() => _MoveUserDataDialogState();
}

class _MoveUserDataDialogState extends State<MoveUserDataDialog> {
  late final GamepadNavigation _gamepadNav;
  final _bodyScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: _confirm,
      onBack: _cancel,
      onNavigateUp: () => _scrollBody(-1),
      onNavigateDown: () => _scrollBody(1),
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
    GamepadNavigationManager.pushLayer(
      'move_user_data_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('move_user_data_dialog');
    _gamepadNav.dispose();
    _bodyScroll.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.of(context).pop(true);
  void _cancel() => Navigator.of(context).pop(false);

  /// Scrolls the body half a view down ([direction] 1) or up (-1), so the
  /// paths can be read with a controller when they don't fit.
  void _scrollBody(int direction) {
    if (!_bodyScroll.hasClients) return;
    final position = _bodyScroll.position;
    final target =
        (position.pixels + direction * position.viewportDimension / 2).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _bodyScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  Widget _pathBox(ThemeData theme, String path) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(10.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        path,
        style: TextStyle(
          fontSize: 11.r,
          color: theme.colorScheme.onSurface,
          fontFamily: 'monospace',
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5.r, sigmaY: 5.r),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 440.r,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.4),
              width: 1.r,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30.r,
                spreadRadius: 5.r,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 12.r,
                    horizontal: 16.r,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8.r),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: Icon(
                          Symbols.drive_file_move_rounded,
                          color: theme.colorScheme.tertiary,
                          size: 16.r,
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        child: Text(
                          AppLocale.moveUserDataTitle.getString(context),
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.tertiary,
                            fontWeight: FontWeight.bold,
                            fontSize: 12.r,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // The text and paths scroll when the screen is too short for
                // them, so the buttons below always stay in view.
                Flexible(
                  child: SingleChildScrollView(
                    controller: _bodyScroll,
                    padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // First, so it is on screen without scrolling: the
                        // destination isn't the folder picked.
                        if (widget.notice case final notice?) ...[
                          Text(
                            notice,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                          SizedBox(height: 10.r),
                        ],
                        Text(
                          AppLocale.moveUserDataBody.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                        SizedBox(height: 12.r),
                        _pathBox(theme, widget.fromPath),
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 4.r),
                          child: Icon(
                            Symbols.arrow_downward_rounded,
                            size: 16.r,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        _pathBox(theme, widget.toPath),
                        if (widget.destItemCount > 0) ...[
                          SizedBox(height: 10.r),
                          Text(
                            AppLocale.moveUserDataDestNotEmpty
                                .getString(context)
                                .replaceFirst(
                                  '{count}',
                                  '${widget.destItemCount}',
                                ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(16.r),
                  child: Row(
                    children: [
                      Expanded(
                        child: GamepadControl(
                          iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                          label: AppLocale.cancel.getString(context),
                          onTap: _cancel,
                          backgroundColor: theme.colorScheme.tertiary,
                          textColor: theme.colorScheme.onTertiary,
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        flex: 2,
                        child: GamepadControl(
                          iconPath: 'assets/images/gamepad/Xbox_A_button.png',
                          label: AppLocale.moveUserDataConfirm.getString(
                            context,
                          ),
                          onTap: _confirm,
                          backgroundColor: theme.colorScheme.primary,
                          textColor: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
