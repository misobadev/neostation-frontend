import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import '../utils/gamepad_nav.dart';
import '../services/game_service.dart';
import '../services/permission_service.dart';

/// Full-screen directory/file browser for Android TV / Google TV.
/// Phase 1: pick a storage volume. Phase 2: browse folders (and optionally files).
///
/// [allowedExtensions]: when set, shows matching files alongside folders.
///   Selecting a file returns its path. No "Set this directory" entry shown.
///   When null (default), directory-picker mode: returns selected folder path.
class TvDirectoryPicker extends StatefulWidget {
  final List<String>? allowedExtensions;

  const TvDirectoryPicker({super.key, this.allowedExtensions});

  /// Directory-picker mode — returns the chosen folder path.
  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const TvDirectoryPicker(),
    );
  }

  /// File-picker mode — shows only files matching [extensions] alongside folders.
  /// Returns the chosen file path.
  static Future<String?> showFilePicker(
    BuildContext context, {
    required List<String> extensions,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvDirectoryPicker(allowedExtensions: extensions),
    );
  }

  @override
  State<TvDirectoryPicker> createState() => _TvDirectoryPickerState();
}

class _TvDirectoryPickerState extends State<TvDirectoryPicker> {
  // Phase
  bool _showVolumePicker = true;
  List<_StorageVolume> _volumes = [];
  bool _loadingVolumes = true;

  // Folder browser
  String _currentPath = '/storage/emulated/0';
  List<_DirEntry> _entries = []; // subdirectories
  List<_DirEntry> _fileEntries = []; // files (file-picker mode only)
  bool _loading = false;
  String? _error;
  bool _permissionDenied = false;
  bool _readyToSelect = false;

  bool get _isFilePicker => widget.allowedExtensions != null;

  // Focus index: volume phase = index into _volumes;
  // folder phase (dir mode):  0 = <Set dir>, 1..n = dirs
  // folder phase (file mode): 0..m-1 = files, m..m+n-1 = dirs  (files first)
  int _focusedIndex = 0;

  final ScrollController _scrollController = ScrollController();
  GamepadNavigation? _gamepadNav;

  static const double _itemHeight = 44.0;

  @override
  void initState() {
    super.initState();
    _initGamepad();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _detectVolumes(context);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _readyToSelect = true);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    GamepadNavigationManager.popLayer('tv_directory_picker');
    _gamepadNav?.dispose();
    super.dispose();
  }

  void _initGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _moveIndex(-1),
      onNavigateDown: () => _moveIndex(1),
      onSelectItem: _handleSelect,
      onBack: _handleBack,
    );
    _gamepadNav?.initialize();
    GamepadNavigationManager.pushLayer(
      'tv_directory_picker',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
  }

  void _moveIndex(int delta) {
    int maxIndex;
    if (_showVolumePicker) {
      maxIndex = _volumes.length - 1;
    } else if (_isFilePicker) {
      // 0 = .., 1..files, files+1..files+dirs
      maxIndex = _fileEntries.length + _entries.length;
    } else {
      // 0 = <Set dir>, 1 = .., 2..n+1 = subdirs
      maxIndex = _entries.length + 1;
    }
    if (maxIndex < 0) return;
    setState(() {
      _focusedIndex = (_focusedIndex + delta).clamp(0, maxIndex);
    });
    _scrollToFocused();
  }

  void _scrollToFocused() {
    if (!_scrollController.hasClients) return;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset =
        (_focusedIndex * _itemHeight) -
        (viewportHeight / 2) +
        (_itemHeight / 2);
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  void _handleSelect() {
    if (!_readyToSelect) return;

    if (_showVolumePicker) {
      if (_focusedIndex < _volumes.length) {
        _selectVolume(_volumes[_focusedIndex]);
      }
      return;
    }

    if (_isFilePicker) {
      // 0 = .., 1..files = files, files+1.. = dirs
      if (_focusedIndex == 0) {
        _goUp();
      } else if (_focusedIndex <= _fileEntries.length) {
        Navigator.of(context).pop(_fileEntries[_focusedIndex - 1].path);
      } else {
        final dirIndex = _focusedIndex - _fileEntries.length - 1;
        if (dirIndex < _entries.length) _loadEntries(_entries[dirIndex].path);
      }
    } else {
      // 0 = <Set dir>, 1 = .., 2+ = subdirs
      if (_focusedIndex == 0) {
        Navigator.of(context).pop(_currentPath);
      } else if (_focusedIndex == 1) {
        _goUp();
      } else {
        _loadEntries(_entries[_focusedIndex - 2].path);
      }
    }
  }

  void _goUp() {
    final parent = Directory(_currentPath).parent.path;
    if (parent == _currentPath) {
      setState(() {
        _showVolumePicker = true;
        _focusedIndex = 0;
      });
    } else {
      _loadEntries(parent);
    }
  }

  void _handleBack() {
    Navigator.of(context).pop();
  }

  Future<void> _detectVolumes(BuildContext context) async {
    final volumes = <_StorageVolume>[];

    // Use Android API for reliable detection of USB/SD on TV devices.
    final androidVolumes = await PermissionService.getExternalStorageVolumes();

    if (androidVolumes.isNotEmpty) {
      for (final vol in androidVolumes) {
        final path = vol['path']?.toString();
        if (path == null || path.isEmpty) continue;
        final description = vol['description']?.toString() ?? 'Storage';
        final isInternal = vol['isInternal'] == true;
        volumes.add(
          _StorageVolume(name: description, path: path, isInternal: isInternal),
        );
      }
    } else {
      // Fallback: scan /storage/ manually.
      const internal = '/storage/emulated/0';
      if (await Directory(internal).exists()) {
        if (!context.mounted) return;
        volumes.add(
          _StorageVolume(
            name: AppLocale.internalStorage.getString(context),
            path: internal,
            isInternal: true,
          ),
        );
      }
      try {
        await for (final entity in Directory('/storage').list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name == 'emulated' || name == 'self') continue;
            try {
              await entity.list().take(1).toList();
              if (!context.mounted) return;
              volumes.add(
                _StorageVolume(
                  name: AppLocale.externalStorage
                      .getString(context)
                      .replaceFirst('{name}', name),
                  path: entity.path,
                  isInternal: false,
                ),
              );
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _volumes = volumes;
        _loadingVolumes = false;
        _focusedIndex = 0;
      });
    }
  }

  void _selectVolume(_StorageVolume volume) {
    setState(() {
      _showVolumePicker = false;
      _currentPath = volume.path;
      _focusedIndex = 0;
    });
    _loadEntries(volume.path);
  }

  Future<void> _loadEntries(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _permissionDenied = false;
      _focusedIndex = 0;
    });

    try {
      final dirs = <_DirEntry>[];
      final files = <_DirEntry>[];
      final exts = widget.allowedExtensions
          ?.map((e) => e.toLowerCase())
          .toSet();

      await for (final entity in Directory(path).list(followLinks: false)) {
        final name = entity.path.split('/').last;
        if (name.startsWith('.')) continue;

        if (entity is Directory) {
          dirs.add(_DirEntry(name: name, path: entity.path));
        } else if (entity is File && exts != null) {
          final ext = name.contains('.')
              ? name.split('.').last.toLowerCase()
              : '';
          if (exts.contains(ext)) {
            files.add(_DirEntry(name: name, path: entity.path));
          }
        }
      }

      dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      files.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

      if (mounted) {
        setState(() {
          _currentPath = path;
          _entries = dirs;
          _fileEntries = files;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final isPermissionError =
          e.toString().contains('errno = 13') ||
          e.toString().toLowerCase().contains('permission denied');
      if (isPermissionError && Platform.isAndroid) {
        final hasAccess = await PermissionService.hasAllFilesAccess();
        if (mounted) {
          setState(() {
            _permissionDenied = true;
            _error = hasAccess
                ? AppLocale.folderRestrictedDesc.getString(context)
                : null;
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _error = e.toString();
            _loading = false;
          });
        }
      }
    }
  }

  Future<void> _requestStoragePermission() async {
    await PermissionService.openAllFilesAccessSettings();
    // After user returns from settings, retry
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) _loadEntries(_currentPath);
  }

  String _displayPath(String path) {
    if (path.startsWith('/storage/emulated/0')) {
      return 'Internal${path.substring('/storage/emulated/0'.length)}';
    }
    return path;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowDown) {
      _moveIndex(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveIndex(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      _handleSelect();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _handleBack();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: EdgeInsets.all(24.r),
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 700.w, maxHeight: 500.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme),
              Divider(height: 1, color: theme.dividerColor),
              Expanded(child: _buildBody(theme)),
              Divider(height: 1, color: theme.dividerColor),
              _buildFooter(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
      child: Row(
        children: [
          Icon(
            _showVolumePicker ? Symbols.storage_rounded : Symbols.folder_open_rounded,
            color: theme.colorScheme.primary,
            size: 20.r,
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              _showVolumePicker
                  ? AppLocale.selectStorage.getString(context)
                  : _displayPath(_currentPath),
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: 12.r,
                fontFamily: _showVolumePicker ? null : 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loadingVolumes && _showVolumePicker) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_showVolumePicker) return _buildVolumeList(theme);
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(16.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.lock_outline_rounded,
                color: theme.colorScheme.error,
                size: 32.r,
              ),
              SizedBox(height: 8.r),
              Text(
                _error != null
                    ? AppLocale.folderRestrictedAndroid.getString(context)
                    : AppLocale.storagePermissionRequired.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(fontSize: 12.r),
              ),
              SizedBox(height: 4.r),
              Text(
                _error ?? AppLocale.allFilesAccessDesc.getString(context),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 9.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
              if (_error == null) ...[
                SizedBox(height: 16.r),
                _TvButton(
                  onPressed: _requestStoragePermission,
                  child: Text(
                    AppLocale.grantPermission.getString(context),
                    style: TextStyle(fontSize: 12.r),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(16.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.error_outline_rounded,
                color: theme.colorScheme.error,
                size: 32.r,
              ),
              SizedBox(height: 8.r),
              Text(
                AppLocale.cannotReadFolder.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(fontSize: 12.r),
              ),
              SizedBox(height: 4.r),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 9.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return _buildFolderList(theme);
  }

  Widget _buildVolumeList(ThemeData theme) {
    if (_volumes.isEmpty) {
      return Center(
        child: Text(
          AppLocale.noStorageFound.getString(context),
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.r),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      itemCount: _volumes.length,
      itemBuilder: (context, index) {
        final vol = _volumes[index];
        final focused = _focusedIndex == index;
        return GestureDetector(
          onTap: () => _selectVolume(vol),
          child: Container(
            height: _itemHeight,
            decoration: BoxDecoration(
              color: focused
                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              border: focused
                  ? Border(
                      left: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 3.r,
                      ),
                    )
                  : null,
            ),
            padding: EdgeInsets.symmetric(horizontal: 16.r),
            child: Row(
              children: [
                Icon(
                  vol.isInternal ? Symbols.phone_android_rounded : Symbols.sd_card_rounded,
                  color: focused
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  size: 20.r,
                ),
                SizedBox(width: 12.r),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vol.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12.r,
                          fontWeight: focused
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: focused
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        vol.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 9.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Symbols.chevron_right_rounded,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  size: 16.r,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFolderList(ThemeData theme) {
    if (_isFilePicker) {
      final totalFiles = _fileEntries.length;
      // +1 for .. item at index 0
      final totalItems = 1 + totalFiles + _entries.length;

      return ListView.builder(
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        itemCount: totalItems,
        itemBuilder: (context, index) {
          final focused = _focusedIndex == index;

          if (index == 0) {
            return GestureDetector(
              onTap: _goUp,
              child: _parentDirItem(theme, focused),
            );
          }

          if (index <= totalFiles) {
            final file = _fileEntries[index - 1];
            return GestureDetector(
              onTap: _readyToSelect
                  ? () => Navigator.of(context).pop(file.path)
                  : null,
              child: Container(
                height: _itemHeight,
                decoration: BoxDecoration(
                  color: focused
                      ? theme.colorScheme.secondary.withValues(alpha: 0.15)
                      : Colors.transparent,
                  border: focused
                      ? Border(
                          left: BorderSide(
                            color: theme.colorScheme.secondary,
                            width: 3.r,
                          ),
                        )
                      : null,
                ),
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Row(
                  children: [
                    Icon(
                      Symbols.image_rounded,
                      color: focused
                          ? theme.colorScheme.secondary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      size: 18.r,
                    ),
                    SizedBox(width: 12.r),
                    Expanded(
                      child: Text(
                        file.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12.r,
                          color: focused
                              ? theme.colorScheme.secondary
                              : theme.colorScheme.onSurface,
                          fontWeight: focused
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Symbols.check_circle_outline_rounded,
                      color: focused
                          ? theme.colorScheme.secondary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                      size: 16.r,
                    ),
                  ],
                ),
              ),
            );
          }

          final entry = _entries[index - 1 - totalFiles];
          return GestureDetector(
            onTap: () => _loadEntries(entry.path),
            child: _folderItemContainer(theme, entry.name, focused),
          );
        },
      );
    }

    // Directory-picker mode: 0 = <Set dir>, 1 = .., 2+ = subdirs.
    return ListView.builder(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      itemCount: _entries.length + 2,
      itemBuilder: (context, index) {
        final focused = _focusedIndex == index;

        if (index == 0) {
          return GestureDetector(
            onTap: _readyToSelect
                ? () => Navigator.of(context).pop(_currentPath)
                : null,
            child: Container(
              height: _itemHeight,
              decoration: BoxDecoration(
                color: focused
                    ? theme.colorScheme.primary.withValues(alpha: 0.2)
                    : theme.colorScheme.primary.withValues(alpha: 0.05),
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary,
                    width: focused ? 3.r : 1.r,
                  ),
                  bottom: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
              ),
              padding: EdgeInsets.symmetric(horizontal: 16.r),
              child: Row(
                children: [
                  Icon(
                    Symbols.check_circle_outline_rounded,
                    color: theme.colorScheme.primary,
                    size: 18.r,
                  ),
                  SizedBox(width: 12.r),
                  Text(
                    AppLocale.setThisDirectory.getString(context),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 12.r,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (index == 1) {
          return GestureDetector(
            onTap: _goUp,
            child: _parentDirItem(theme, focused),
          );
        }

        final entry = _entries[index - 2];
        return GestureDetector(
          onTap: () => _loadEntries(entry.path),
          child: _folderItemContainer(theme, entry.name, focused),
        );
      },
    );
  }

  Widget _parentDirItem(ThemeData theme, bool focused) {
    return Container(
      height: _itemHeight,
      decoration: BoxDecoration(
        color: focused
            ? theme.colorScheme.onSurface.withValues(alpha: 0.1)
            : Colors.transparent,
        border: focused
            ? Border(
                left: BorderSide(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  width: 3.r,
                ),
              )
            : null,
      ),
      padding: EdgeInsets.symmetric(horizontal: 16.r),
      child: Row(
        children: [
          Icon(
            Symbols.drive_folder_upload_rounded,
            color: focused
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
            size: 18.r,
          ),
          SizedBox(width: 12.r),
          Text(
            '..',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 12.r,
              color: focused
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurface.withValues(alpha: 0.5),
              fontWeight: focused ? FontWeight.bold : FontWeight.normal,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderItemContainer(ThemeData theme, String name, bool focused) {
    return Container(
      height: _itemHeight,
      decoration: BoxDecoration(
        color: focused
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        border: focused
            ? Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 3.r),
              )
            : null,
      ),
      padding: EdgeInsets.symmetric(horizontal: 16.r),
      child: Row(
        children: [
          Icon(
            Symbols.folder_rounded,
            color: focused
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            size: 18.r,
          ),
          SizedBox(width: 12.r),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 12.r,
                color: focused
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight: focused ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Symbols.chevron_right_rounded,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            size: 16.r,
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 10.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _HintChip(
                label: 'A',
                description: _showVolumePicker
                    ? AppLocale.select.getString(context)
                    : _isFilePicker
                    ? AppLocale.hintSelectFile.getString(context)
                    : AppLocale.hintEnterSetDir.getString(context),
              ),
              SizedBox(width: 12.r),
              _HintChip(
                label: 'B',
                description: AppLocale.cancel.getString(context),
              ),
            ],
          ),
          _TvButton(
            onPressed: () => Navigator.of(context).pop(),
            secondary: true,
            child: Text(
              AppLocale.cancel.getString(context),
              style: TextStyle(fontSize: 12.r),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Data classes ──────────────────────────────────────────────────────────────

class _StorageVolume {
  final String name;
  final String path;
  final bool isInternal;

  const _StorageVolume({
    required this.name,
    required this.path,
    required this.isInternal,
  });
}

class _DirEntry {
  final String name;
  final String path;
  const _DirEntry({required this.name, required this.path});
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _HintChip extends StatelessWidget {
  final String label;
  final String description;

  const _HintChip({required this.label, required this.description});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4.r),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        SizedBox(width: 4.r),
        Text(
          description,
          style: TextStyle(
            fontSize: 10.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// Simple TV-friendly button with focus highlighting.
class _TvButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final bool secondary;

  const _TvButton({
    required this.onPressed,
    required this.child,
    this.secondary = false,
  });

  @override
  State<_TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<_TvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSecondary = widget.secondary;

    return InkWell(
      onTap: widget.onPressed,
      onFocusChange: (v) => setState(() => _focused = v),
      borderRadius: BorderRadius.circular(8.r),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isSecondary
              ? (_focused ? theme.colorScheme.surface : Colors.transparent)
              : (_focused
                    ? theme.colorScheme.primary.withValues(alpha: 0.9)
                    : theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: isSecondary
                ? theme.colorScheme.outline.withValues(alpha: 0.5)
                : theme.colorScheme.primary,
            width: _focused ? 2.r : 1.r,
          ),
        ),
        child: DefaultTextStyle(
          style: TextStyle(
            color: isSecondary
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w600,
          ),
          child: IconTheme(
            data: IconThemeData(
              color: isSecondary
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onPrimary,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
