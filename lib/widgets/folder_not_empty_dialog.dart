import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';

import 'core_footer.dart';

/// Confirmation shown when the user picks a NON-empty folder as the user-data
/// location. Warns that NeoStation will store its data alongside the existing
/// contents (a foreign front-end's library, etc.) so the choice is deliberate.
///
/// Returns `true` if the user chooses to use the folder anyway, `false`
/// (or `null` when dismissed) otherwise.
class FolderNotEmptyDialog extends StatefulWidget {
  final String path;
  final int itemCount;

  const FolderNotEmptyDialog({
    super.key,
    required this.path,
    required this.itemCount,
  });

  /// Shows the dialog and resolves to whether the user confirmed.
  static Future<bool> show(
    BuildContext context, {
    required String path,
    required int itemCount,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FolderNotEmptyDialog(path: path, itemCount: itemCount),
    );
    return result ?? false;
  }

  @override
  State<FolderNotEmptyDialog> createState() => _FolderNotEmptyDialogState();
}

class _FolderNotEmptyDialogState extends State<FolderNotEmptyDialog> {
  late final GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(onSelectItem: _confirm, onBack: _cancel);
    _gamepadNav.initialize();
    _gamepadNav.activate();
    GamepadNavigationManager.pushLayer(
      'folder_not_empty_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('folder_not_empty_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.of(context).pop(true);

  void _cancel() => Navigator.of(context).pop(false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5.r, sigmaY: 5.r),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 420.r,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.9),
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
                          Symbols.warning_rounded,
                          color: theme.colorScheme.tertiary,
                          size: 16.r,
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        child: Text(
                          AppLocale.folderNotEmptyTitle.getString(context),
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
                Padding(
                  padding: EdgeInsets.all(16.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.folderNotEmptyBody
                            .getString(context)
                            .replaceFirst('{count}', '${widget.itemCount}'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.8,
                          ),
                        ),
                      ),
                      SizedBox(height: 10.r),
                      Container(
                        padding: EdgeInsets.all(10.r),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: Text(
                          widget.path,
                          style: TextStyle(
                            fontSize: 11.r,
                            color: theme.colorScheme.onSurface,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(height: 16.r),
                      Row(
                        children: [
                          Expanded(
                            child: GamepadControl(
                              iconPath:
                                  'assets/images/gamepad/Xbox_B_button.png',
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
                              iconPath:
                                  'assets/images/gamepad/Xbox_A_button.png',
                              label: AppLocale.folderNotEmptyUseAnyway
                                  .getString(context),
                              onTap: _confirm,
                              backgroundColor: theme.colorScheme.primary,
                              textColor: theme.colorScheme.onPrimary,
                            ),
                          ),
                        ],
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
