import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Delete Cloud Save Dialog with Gamepad Navigation
class DeleteCloudSaveDialog extends StatefulWidget {
  final NeoSyncFile file;
  final Function(bool) onDisableNeoSyncChanged;

  const DeleteCloudSaveDialog({
    super.key,
    required this.file,
    required this.onDisableNeoSyncChanged,
  });

  @override
  State<DeleteCloudSaveDialog> createState() => _DeleteCloudSaveDialogState();
}

class _DeleteCloudSaveDialogState extends State<DeleteCloudSaveDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer. Without one, a resume (or a modal
  /// closing just before this opened) woke the screen underneath, and one A or
  /// B press drove both. Modal, so a screen that mounts behind it can't take
  /// the controller back; per instance, as [GamepadNavigationManager.popLayer]
  /// removes the first layer with a matching id.
  late final String _layerId = 'neo_sync_delete_save#${identityHashCode(this)}';

  bool disableNeoSync = false;

  /// Where keyboard focus is decides what Enter and A do, as Enter reaches
  /// the navigation's select as well as the focused control: on Cancel it
  /// cancels, on the switch it only toggles the switch. The navigation's
  /// direction callbacks move this focus for the D-pad and the arrow keys;
  /// Flutter's own focus traversal is switched off in the build.
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'delete_save_cancel');
  final FocusNode _switchFocus = FocusNode(debugLabel: 'delete_save_switch');
  final FocusNode _deleteFocus = FocusNode(debugLabel: 'delete_save_delete');
  bool _closing = false;

  /// Moves focus to [to] if it is on [from]; whether it moved. An edge of the
  /// prompt reports false, so no navigation sound plays there.
  bool _move(FocusNode from, FocusNode to) {
    if (!from.hasFocus) return false;
    to.requestFocus();
    return true;
  }

  void _setDisableNeoSync(bool value) {
    setState(() => disableNeoSync = value);
    widget.onDisableNeoSyncChanged(value);
  }

  /// Redraws the focus highlights, which a controller relies on: on Android
  /// its keys never reach Flutter, so Flutter's own focus ring stays off.
  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  /// Closes the prompt once. A keyboard Enter reaches both the navigation's
  /// select and the focused button, so it arrives here twice.
  void _close(bool confirmed) {
    if (_closing) return;
    _closing = true;
    if (confirmed) widget.onDisableNeoSyncChanged(disableNeoSync);
    Navigator.of(context).pop(confirmed);
  }

  @override
  void initState() {
    super.initState();
    for (final node in [_cancelFocus, _switchFocus, _deleteFocus]) {
      node.addListener(_onFocusChange);
    }
    // The switch sits above the buttons, Cancel to the left of Delete.
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () =>
          _move(_cancelFocus, _switchFocus) ||
          _move(_deleteFocus, _switchFocus),
      onNavigateDown: () => _move(_switchFocus, _deleteFocus),
      onNavigateLeft: () => _move(_deleteFocus, _cancelFocus),
      onNavigateRight: () => _move(_cancelFocus, _deleteFocus),
      onSelectItem: () {
        // A on the switch only toggles it. Enter there toggles it here too,
        // so the switch itself ignores Enter (see the build).
        if (_switchFocus.hasFocus) {
          _setDisableNeoSync(!disableNeoSync);
          return;
        }
        _close(!_cancelFocus.hasFocus);
      },
      onBack: () => _close(false),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _cancelFocus.dispose();
    _switchFocus.dispose();
    _deleteFocus.dispose();
    super.dispose();
  }

  /// Outlines [button] while [focus] has it, as the custom save folders
  /// dialogue outlines its focused button.
  Widget _outlineWhenFocused(
    FocusNode focus,
    BorderRadius radius,
    Widget button,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: focus.hasFocus
              ? Theme.of(context).colorScheme.onSurface
              : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: button,
    );
  }

  @override
  Widget build(BuildContext context) {
    // On Android an arrow key from a TV remote or a keyboard also reaches
    // Flutter's focus traversal, after the navigation has moved focus, and so
    // took a second step. Only the navigation moves focus here.
    return Actions(
      actions: <Type, Action<Intent>>{
        DirectionalFocusIntent: DoNothingAction(),
      },
      child: _buildDialog(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
      title: Row(
        children: [
          Icon(
            Symbols.delete_forever_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18.r,
          ),
          SizedBox(width: 8.r),
          Text(
            AppLocale.deleteCloudSave.getString(context),
            style: TextStyle(
              fontSize: 15.r,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.deleteCloudSaveConfirm.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.3,
            ),
          ),
          SizedBox(height: 6.r),
          Container(
            padding: EdgeInsets.all(8.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.save_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 16.r,
                ),
                SizedBox(width: 6.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.file.fileName,
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 1.r),
                      Text(
                        '${widget.file.fileSizeFormatted} • ${widget.file.uploadedAt.toLocal().toString().split(' ')[0]}',
                        style: TextStyle(
                          fontSize: 9.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 10.r),
          // Highlighted while focused, as the custom save folders dialogue
          // highlights its rows.
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: _switchFocus.hasFocus
                  ? Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12)
                  : Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: _switchFocus.hasFocus
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.2),
                width: _switchFocus.hasFocus ? 2.r : 1.r,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.scale(
                  scale: 0.7,
                  // The navigation's select already toggles the focused
                  // switch on Enter; the switch toggling too would undo it.
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.enter):
                          DoNothingAndStopPropagationIntent(),
                    },
                    child: Switch(
                      focusNode: _switchFocus,
                      value: disableNeoSync,
                      onChanged: _setDisableNeoSync,
                      activeThumbColor: Theme.of(context).colorScheme.secondary,
                      activeTrackColor: Theme.of(
                        context,
                      ).colorScheme.secondary.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                SizedBox(width: 4.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.alsoDisableNeoSync.getString(context),
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 2.r),
                      Text(
                        AppLocale.preventsAutoSaves.getString(context),
                        style: TextStyle(
                          fontSize: 10.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 8.h),
        ],
      ),
      actionsPadding: EdgeInsets.only(right: 12.r, bottom: 12.r),
      actions: [
        _outlineWhenFocused(
          _cancelFocus,
          BorderRadius.circular(22.r),
          TextButton(
            focusNode: _cancelFocus,
            onPressed: () => _close(false),
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  width: 14.r,
                  height: 14.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                SizedBox(width: 6.r),
                Text(
                  AppLocale.cancel.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
        _outlineWhenFocused(
          _deleteFocus,
          BorderRadius.circular(10.r),
          ElevatedButton(
            focusNode: _deleteFocus,
            autofocus: true,
            onPressed: () => _close(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.r),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  width: 14.r,
                  height: 14.r,
                  color: Theme.of(context).colorScheme.onError,
                ),
                SizedBox(width: 6.r),
                Text(
                  AppLocale.delete.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onError,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Success Dialog with Gamepad Navigation
class SuccessDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const SuccessDialog({
    super.key,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<SuccessDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer, as for [DeleteCloudSaveDialog].
  late final String _layerId = 'neo_sync_success#${identityHashCode(this)}';

  bool _closing = false;

  /// Closes the dialogue once. A keyboard Enter reaches both the navigation's
  /// select and the focused button, so it arrives here twice.
  void _close() {
    if (_closing) return;
    _closing = true;
    widget.onClose();
  }

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(onSelectItem: _close, onBack: _close);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(Symbols.check_circle_rounded, color: Colors.green, size: 24.r),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: _close,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}

/// Error Dialog with Gamepad Navigation
class ErrorDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<ErrorDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer, as for [DeleteCloudSaveDialog].
  late final String _layerId = 'neo_sync_error#${identityHashCode(this)}';

  bool _closing = false;

  /// Closes the dialogue once. A keyboard Enter reaches both the navigation's
  /// select and the focused button, so it arrives here twice.
  void _close() {
    if (_closing) return;
    _closing = true;
    widget.onClose();
  }

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(onSelectItem: _close, onBack: _close);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(
            Symbols.error_rounded,
            color: theme.colorScheme.error,
            size: 24.r,
          ),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: _close,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}
