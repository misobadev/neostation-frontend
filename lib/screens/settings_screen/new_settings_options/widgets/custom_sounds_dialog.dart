import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../../l10n/app_locale.dart';
import '../../../../models/config_model.dart';
import '../../../../models/custom_sfx.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/permission_service.dart';
import '../../../../services/game_service.dart';
import '../../../../services/sfx_service.dart';
import '../../../../themes/corner_radii.dart';
import '../../../../utils/gamepad_nav.dart';
import '../../../../widgets/neo_glass.dart';
import '../../../../widgets/tv_directory_picker.dart';

class CustomSoundsDialog extends StatefulWidget {
  const CustomSoundsDialog({super.key});
  @override
  State<CustomSoundsDialog> createState() => _CustomSoundsDialogState();
}

class _CustomSoundsDialogState extends State<CustomSoundsDialog> {
  static const extensions = ['wav', 'mp3', 'ogg', 'flac'];
  final _keys = List.generate(9, (_) => GlobalKey());
  late final GamepadNavigation _nav;
  int _selected = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nav = GamepadNavigation(
      playSelectSound: false,
      onNavigateUp: () => _move((_selected - 3).clamp(0, 8)),
      onNavigateDown: () => _move((_selected + 3).clamp(0, 8)),
      onNavigateLeft: () => _move((_selected - 1).clamp(0, 8)),
      onNavigateRight: () => _move((_selected + 1).clamp(0, 8)),
      onSelectItem: () => _activate(_selected),
      onBack: () {
        if (!_busy) Navigator.pop(context);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nav.initialize();
      GamepadNavigationManager.pushLayer(
        'custom_sounds',
        modal: true,
        onActivate: _nav.activate,
        onDeactivate: _nav.deactivate,
      );
    });
  }

  bool _move(int index) {
    if (_busy || index == _selected) return false;
    setState(() => _selected = index);
    final target = _keys[index].currentContext;
    if (target != null) Scrollable.ensureVisible(target, alignment: 0.5);
    return true;
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('custom_sounds');
    _nav.dispose();
    super.dispose();
  }

  Future<void> _activate(int index) async {
    if (_busy) return;
    final provider = context.read<SqliteConfigProvider>();
    final action = SfxAction.values[index ~/ 3];
    final operation = index % 3;
    if (operation == 1 && !provider.config.sfxEnabled) return;
    if (operation == 2 && !provider.config.customSfx.containsKey(action)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _selected = index;
    });
    try {
      if (operation == 0) {
        String? path;
        String? filename;
        if (Platform.isAndroid && await PermissionService.isTelevision()) {
          if (!mounted) return;
          path = await TvDirectoryPicker.showFilePicker(
            context,
            extensions: extensions,
          );
          if (path != null) filename = p.basename(Uri.decodeFull(path));
        } else {
          final result = await FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: extensions,
            windowsOptions: const WindowsOptions(lockParentWindow: true),
            linuxOptions: const LinuxOptions(lockParentWindow: true),
          );
          path = result?.path;
          filename = result?.name;
        }
        if (path != null && filename != null) {
          await provider.importCustomSfx(action, path, filename);
        }
      } else if (operation == 1) {
        await SfxService().preview(action);
      } else {
        await provider.resetCustomSfx(action);
      }
    } catch (e) {
      if (!mounted) return;
      final key = e is FormatException
          ? switch (e.message) {
              'size' => AppLocale.customSoundsSizeError,
              'duration' => AppLocale.customSoundsDurationError,
              _ => AppLocale.customSoundsInvalidError,
            }
          : AppLocale.customSoundsSaveError;
      setState(() => _error = key.getString(context));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(
    int index,
    String text, {
    bool enabled = true,
    IconData? icon,
  }) => _SoundButton(
    key: _keys[index],
    label: text,
    icon: icon,
    selected: _selected == index,
    enabled: enabled && !_busy,
    onTap: () => _activate(index),
  );

  IconData _actionIcon(SfxAction action) => switch (action) {
    SfxAction.movement => Symbols.volume_up_rounded,
    SfxAction.confirm => Symbols.check_circle_rounded,
    SfxAction.back => Symbols.arrow_back_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final config = context.watch<SqliteConfigProvider>().config;
    final labels = [
      AppLocale.customSoundsMovement,
      AppLocale.customSoundsConfirm,
      AppLocale.customSoundsBack,
    ];

    return PopScope(
      canPop: !_busy,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(16.r),
        child: NeoGlassRim(
          cornerRadius: radii.radiusExternalRadius,
          child: Container(
            constraints: const BoxConstraints(
              maxWidth: 640.0,
              maxHeight: 480.0,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: radii.radiusExternal,
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.5),
                  blurRadius: 18.r,
                  offset: Offset(0, 8.r),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radii.radiusExternal,
              child: Column(
                children: [
                  _buildHeader(theme),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(14.r, 10.r, 14.r, 10.r),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_busy)
                            Padding(
                              padding: EdgeInsets.only(bottom: 10.r),
                              child: ClipRRect(
                                borderRadius: radii.radiusInternal,
                                child: const LinearProgressIndicator(
                                  minHeight: 3,
                                ),
                              ),
                            ),
                          for (final action in SfxAction.values)
                            _buildActionCard(
                              context,
                              theme,
                              radii,
                              action,
                              labels[action.index],
                              config,
                            ),
                          if (_error != null)
                            Container(
                              margin: EdgeInsets.only(top: 2.r),
                              padding: EdgeInsets.all(10.r),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.error.withValues(
                                  alpha: 0.12,
                                ),
                                borderRadius: radii.radiusInternal,
                                border: Border.all(
                                  color: theme.colorScheme.error.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Symbols.error_rounded,
                                    size: 16.r,
                                    color: theme.colorScheme.error,
                                  ),
                                  SizedBox(width: 8.r),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: TextStyle(
                                        fontSize: 10.r,
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _buildFooter(theme, radii),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 10.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.12),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.volume_up_rounded,
            size: 18.r,
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.customSounds.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 1.r),
                Text(
                  AppLocale.customSoundsHint.getString(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              onTap: _busy
                  ? null
                  : () {
                      SfxService().playBackSound();
                      Navigator.of(context).pop();
                    },
              child: Container(
                padding: EdgeInsets.all(6.r),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18.r,
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: _busy ? 0.25 : 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard(
    BuildContext context,
    ThemeData theme,
    CornerRadii radii,
    SfxAction action,
    String label,
    ConfigModel config,
  ) {
    final filename =
        config.customSfx[action]?.filename ??
        AppLocale.customSoundsDefault.getString(context);
    final custom = config.customSfx.containsKey(action);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
      child: NeoGlassRim(
        cornerRadius: radii.radiusInternalRadius,
        child: Container(
          padding: EdgeInsets.all(10.r),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.16,
            ),
            borderRadius: radii.radiusInternal,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 28.r,
                    height: 28.r,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: radii.radiusInternal,
                    ),
                    child: Icon(
                      _actionIcon(action),
                      size: 16.r,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label.getString(context),
                          style: TextStyle(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 1.r),
                        Text(
                          filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: custom ? 0.8 : 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 10.r),
              Row(
                children: [
                  Expanded(
                    child: _button(
                      action.index * 3,
                      AppLocale.customSoundsImport.getString(context),
                      icon: Symbols.upload_file_rounded,
                    ),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: _button(
                      action.index * 3 + 1,
                      AppLocale.customSoundsPreview.getString(context),
                      icon: Symbols.play_arrow_rounded,
                      enabled: config.sfxEnabled,
                    ),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: _button(
                      action.index * 3 + 2,
                      AppLocale.customSoundsReset.getString(context),
                      icon: Symbols.restart_alt_rounded,
                      enabled: custom,
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

  Widget _buildFooter(ThemeData theme, CornerRadii radii) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.05,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: radii.radiusExternal.bottomLeft,
          bottomRight: radii.radiusExternal.bottomRight,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildHint(
            theme,
            'assets/images/gamepad/Xbox_D-pad_ALL.png',
            AppLocale.navigate.getString(context),
          ),
          SizedBox(width: 20.r),
          _buildHint(
            theme,
            'assets/images/gamepad/Xbox_A_button.png',
            AppLocale.select.getString(context),
          ),
          SizedBox(width: 20.r),
          _buildHint(
            theme,
            'assets/images/gamepad/Xbox_B_button.png',
            AppLocale.close.getString(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHint(ThemeData theme, String asset, String label) {
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColorFiltered(
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          child: Image.asset(asset, width: 15.r, height: 15.r),
        ),
        SizedBox(width: 5.r),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.r,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// A keyboard/gamepad-focusable action button inside the custom sounds dialog.
class _SoundButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final foreground = selected ? scheme.surface : scheme.onSurface;
    final background = selected
        ? scheme.onSurface
        : scheme.surfaceContainerHighest.withValues(alpha: 0.3);
    final color = enabled ? foreground : foreground.withValues(alpha: 0.4);

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: radii.radiusInternal,
          child: Container(
            height: 34.r,
            padding: EdgeInsets.symmetric(horizontal: 6.r),
            decoration: BoxDecoration(
              color: background,
              borderRadius: radii.radiusInternal,
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : scheme.outline.withValues(alpha: 0.18),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14.r, color: color),
                  SizedBox(width: 4.r),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.r,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
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
