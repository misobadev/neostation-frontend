import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../../l10n/app_locale.dart';
import '../../../../models/custom_sfx.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/permission_service.dart';
import '../../../../services/game_service.dart';
import '../../../../services/sfx_service.dart';
import '../../../../utils/gamepad_nav.dart';
import '../../../../widgets/tv_directory_picker.dart';

class CustomSoundsDialog extends StatefulWidget {
  const CustomSoundsDialog({super.key});
  @override
  State<CustomSoundsDialog> createState() => _CustomSoundsDialogState();
}

class _CustomSoundsDialogState extends State<CustomSoundsDialog> {
  static const extensions = ['wav', 'mp3', 'ogg', 'flac'];
  final _keys = List.generate(10, (_) => GlobalKey());
  late final GamepadNavigation _nav;
  int _selected = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nav = GamepadNavigation(
      playSelectSound: false,
      onNavigateUp: () =>
          _move(_selected == 9 ? 6 : (_selected - 3).clamp(0, 9)),
      onNavigateDown: () => _move((_selected + 3).clamp(0, 9)),
      onNavigateLeft: () => _move((_selected - 1).clamp(0, 9)),
      onNavigateRight: () => _move((_selected + 1).clamp(0, 9)),
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
    if (index == 9) {
      Navigator.pop(context);
      return;
    }
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

  Widget _button(int index, String text, {bool enabled = true}) =>
      OutlinedButton(
        key: _keys[index],
        onPressed: !_busy && enabled ? () => _activate(index) : null,
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: _selected == index
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
            width: _selected == index ? 2 : 1,
          ),
          minimumSize: Size(0, 40.r),
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 10.r),
          textStyle: TextStyle(fontSize: 11.r),
        ),
        child: Text(text, textAlign: TextAlign.center),
      );

  @override
  Widget build(BuildContext context) {
    final config = context.watch<SqliteConfigProvider>().config;
    final labels = [
      AppLocale.customSoundsMovement,
      AppLocale.customSoundsConfirm,
      AppLocale.customSoundsBack,
    ];
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        titlePadding: EdgeInsets.fromLTRB(24.r, 20.r, 24.r, 12.r),
        contentPadding: EdgeInsets.symmetric(horizontal: 24.r),
        actionsPadding: EdgeInsets.fromLTRB(24.r, 12.r, 24.r, 16.r),
        title: Text(
          AppLocale.customSounds.getString(context),
          style: TextStyle(fontSize: 16.r, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 600.r,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.customSoundsHint.getString(context),
                  style: TextStyle(fontSize: 11.r),
                ),
                for (final action in SfxAction.values) ...[
                  SizedBox(height: 16.r),
                  Text(
                    labels[action.index].getString(context),
                    style: TextStyle(
                      fontSize: 13.r,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    config.customSfx[action]?.filename ??
                        AppLocale.customSoundsDefault.getString(context),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.r),
                  ),
                  SizedBox(height: 6.r),
                  Row(
                    children: [
                      Expanded(
                        child: _button(
                          action.index * 3,
                          AppLocale.customSoundsImport.getString(context),
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        child: _button(
                          action.index * 3 + 1,
                          AppLocale.customSoundsPreview.getString(context),
                          enabled: config.sfxEnabled,
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        child: _button(
                          action.index * 3 + 2,
                          AppLocale.customSoundsReset.getString(context),
                          enabled: config.customSfx.containsKey(action),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_busy)
                  Padding(
                    padding: EdgeInsets.only(top: 12.r),
                    child: const LinearProgressIndicator(),
                  ),
                if (_error != null)
                  Padding(
                    padding: EdgeInsets.only(top: 12.r),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [_button(9, AppLocale.customSoundsClose.getString(context))],
      ),
    );
  }
}
