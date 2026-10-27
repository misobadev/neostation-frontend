part of '../system_emulator_settings_dialog.dart';

/// Tab bodies for the settings dialog.
///
/// The General / Appearance / Emulators tab builders, the system-image &
/// logo pickers, and the shared switch/preview helpers — moved out of the
/// monolith. Behaviour is unchanged. State lives on the host [State]
/// (extensions can't declare fields); `setState` calls route through the host
/// [rebuild] bridge (`State.setState` is `@protected`), and the host's static
/// `_log` is referenced qualified (extensions can't use unqualified statics).
extension _Tabs on _SystemEmulatorSettingsDialogState {
  Widget _buildGeneralTab() {
    return ListView(
      controller: _generalScrollController,
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      children: [_buildGeneralSettingsSection()],
    );
  }

  Widget _buildAppearanceTab() {
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      children: [_buildSystemImagesSection()],
    );
  }

  Widget _buildSystemImagesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 8.r),
          child: Text(
            AppLocale.systemImages.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        _buildImagePickerItem(
          index: 0,
          key: _appearanceItemKeys[0],
          title: AppLocale.backgroundImage.getString(context),
          subtitle: AppLocale.backgroundImageSubtitle.getString(context),
          currentPath:
              _system.customBackgroundPath ?? _system.backgroundImage ?? '',
          hasCustom:
              _system.customBackgroundPath != null &&
              _system.customBackgroundPath!.isNotEmpty,
          onPick: _pickAndSaveImage,
          onReset: _resetImage,
        ),
        SizedBox(height: 6.r),
        _buildImagePickerItem(
          index: 1,
          key: _appearanceItemKeys[1],
          title: AppLocale.logoImage.getString(context),
          subtitle: AppLocale.logoImageSubtitle.getString(context),
          currentPath: _system.customLogoPath ?? '',
          hasCustom:
              _system.customLogoPath != null &&
              _system.customLogoPath!.isNotEmpty,
          onPick: _pickAndSaveLogoImage,
          onReset: _resetLogoImage,
        ),
      ],
    );
  }

  Widget _buildImagePickerItem({
    required int index,
    required Key key,
    required String title,
    required String subtitle,
    required String currentPath,
    required bool hasCustom,
    required VoidCallback onPick,
    required VoidCallback onReset,
  }) {
    final bool isFocused = _currentTab == 2 && _appearanceIndex == index;
    final theme = Theme.of(context);
    // Use the row's text colour: surface on the focused inverse row, onSurface
    // otherwise. Never a hardcoded white.
    final previewIconColor = isFocused
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface;
    final trailingIconColor = isFocused
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface;

    return Container(
      key: key,
      height: 50.r,
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      decoration: BoxDecoration(
        color: isFocused ? theme.colorScheme.onSurface : Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
            BorderRadius.circular(9.r),
        border: null,
      ),
      child: Row(
        children: [
          // Preview (Small)
          Container(
            key: ValueKey('${currentPath}_${_system.imageVersion}'),
            width: 36.r,
            height: 36.r,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius:
                  Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                  BorderRadius.circular(9.r),
            ),
            child: currentPath.isEmpty
                ? Icon(
                    Symbols.image_not_supported_rounded,
                    size: 16.r,
                    color: previewIconColor,
                  )
                : _buildPreviewImage(currentPath, iconColor: previewIconColor),
          ),

          SizedBox(width: 12.r),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w500,
                    color: isFocused
                        ? theme.colorScheme.surface
                        : theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  hasCustom
                      ? AppLocale.customImageSet.getString(context)
                      : subtitle,
                  style: TextStyle(
                    fontSize: 10.r,
                    color: isFocused
                        ? theme.colorScheme.surface.withValues(alpha: 0.7)
                        : (hasCustom
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                )),
                    fontWeight: hasCustom ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          // Buttons (Small & Compact)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: onPick,
                icon: Icon(Symbols.upload_file_rounded, size: 16.r),
                tooltip: AppLocale.upload.getString(context),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 24.r, minHeight: 24.r),
                color: trailingIconColor,
              ),
              if (hasCustom) ...[
                SizedBox(width: 4.r),
                IconButton(
                  onPressed: onReset,
                  icon: Icon(Symbols.delete_outline_rounded, size: 16.r),
                  tooltip: AppLocale.reset.getString(context),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 24.r, minHeight: 24.r),
                  color: trailingIconColor,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndSaveImage() async {
    try {
      String? pickedPath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (!mounted) return;
        pickedPath = await TvDirectoryPicker.showFilePicker(
          context,
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        );
      } else {
        final result = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
          dialogTitle: 'Select Background Image',
          windowsOptions: const WindowsOptions(lockParentWindow: true),
          linuxOptions: const LinuxOptions(lockParentWindow: true),
        );
        pickedPath = result?.path;
      }

      if (pickedPath == null) return;

      final originalFile = File(pickedPath);
      if (!originalFile.existsSync()) return;

      final extension = path.extension(originalFile.path);
      const suffix = '_background';
      final fileName = '${_system.folderName}$suffix$extension';

      final userDataPath = await ConfigService.getUserDataPath();
      final targetDir = Directory(path.join(userDataPath, 'media', 'systems'));
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }
      final targetPath = path.join(targetDir.path, fileName);

      // Copy file
      await originalFile.copy(targetPath);

      // Evict from cache to ensure immediate UI update
      await FileImage(File(targetPath)).evict();

      // Nuclear option: Clear global image cache to force reload
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      // Update DB
      await SystemRepository.setCustomImages(
        _system.id!,
        backgroundPath: targetPath,
      );

      // Update State
      rebuild(() {
        // Increment version to force rebuild in dialog preview
        final newVersion = (_system.imageVersion) + 1;

        _system = _system.copyWith(
          customBackgroundPath: targetPath,
          imageVersion: newVersion,
        );
      });

      if (mounted) {
        // Refresh provider to update UI everywhere
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageUpdatedSuccess.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      _SystemEmulatorSettingsDialogState._log.e(
        'Error updating system background image: $e',
      );
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorUpdatingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _resetImage() async {
    try {
      await SystemRepository.setCustomImages(_system.id!, backgroundPath: '');

      // Clear global image cache to force reload
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      rebuild(() {
        _system = _system.copyWith(customBackgroundPath: '');
      });

      if (mounted) {
        // Refresh provider to update UI everywhere
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageResetDefault.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      _SystemEmulatorSettingsDialogState._log.e(
        'Error resetting system background image: $e',
      );
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorResettingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _pickAndSaveLogoImage() async {
    try {
      String? pickedPath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (!mounted) return;
        pickedPath = await TvDirectoryPicker.showFilePicker(
          context,
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
      } else {
        final result = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
          dialogTitle: 'Select Logo Image',
          windowsOptions: const WindowsOptions(lockParentWindow: true),
          linuxOptions: const LinuxOptions(lockParentWindow: true),
        );
        pickedPath = result?.path;
      }

      if (pickedPath == null) return;

      final originalFile = File(pickedPath);
      if (!originalFile.existsSync()) return;

      final extension = path.extension(originalFile.path);
      final fileName = '${_system.folderName}_logo$extension';

      final userDataPath = await ConfigService.getUserDataPath();
      final targetDir = Directory(path.join(userDataPath, 'media', 'systems'));
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }
      final targetPath = path.join(targetDir.path, fileName);

      await originalFile.copy(targetPath);

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await SystemRepository.setCustomImages(_system.id!, logoPath: targetPath);

      rebuild(() {
        final newVersion = _system.imageVersion + 1;
        _system = _system.copyWith(
          customLogoPath: targetPath,
          imageVersion: newVersion,
        );
      });

      if (mounted) {
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageUpdatedSuccess.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      _SystemEmulatorSettingsDialogState._log.e(
        'Error updating system logo image: $e',
      );
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorUpdatingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _resetLogoImage() async {
    try {
      await SystemRepository.setCustomImages(_system.id!, logoPath: '');

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      rebuild(() {
        _system = _system.copyWith(customLogoPath: '');
      });

      if (mounted) {
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageResetDefault.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      _SystemEmulatorSettingsDialogState._log.e(
        'Error resetting system logo image: $e',
      );
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorResettingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Widget _buildPreviewImage(String path, {required Color iconColor}) {
    if (path.isEmpty) return const SizedBox.shrink();

    if (ImageUtils.isGif(path)) {
      return ShaderGifWidget(imagePath: path, key: ValueKey('preview_$path'));
    }

    if (File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: iconColor),
      );
    } else if (path.startsWith('assets')) {
      return Image.asset(
        path,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: iconColor),
      );
    } else {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: iconColor),
      );
    }
  }

  Widget _buildGeneralSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSwitchItem(
          index: 0,
          key: _generalItemKeys[0],
          title: AppLocale.alwaysShowRomName.getString(context),
          subtitle: AppLocale.alwaysShowRomNameSubtitle.getString(context),
          value: _system.preferFileName,
          onChanged: _togglePreferFileName,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 1,
          key: _generalItemKeys[1],
          title: AppLocale.hideExtension.getString(context),
          subtitle: AppLocale.hideExtensionSubtitle.getString(context),
          value: _system.hideExtension,
          onChanged: _toggleHideExtension,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 2,
          key: _generalItemKeys[2],
          title: AppLocale.hideParentheses.getString(context),
          subtitle: AppLocale.hideParenthesesSubtitle.getString(context),
          value: _system.hideParentheses,
          onChanged: _toggleHideParentheses,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 3,
          key: _generalItemKeys[3],
          title: AppLocale.hideBrackets.getString(context),
          subtitle: AppLocale.hideBracketsSubtitle.getString(context),
          value: _system.hideBrackets,
          onChanged: _toggleHideBrackets,
        ),
        if (_offersRecursiveScan) ...[
          SizedBox(height: 4.r),
          _buildSwitchItem(
            index: 4,
            key: _generalItemKeys[4],
            title: AppLocale.recursiveScan.getString(context),
            subtitle: AppLocale.recursiveScanSubtitle.getString(context),
            value: _system.recursiveScan,
            onChanged: _toggleRecursiveScan,
          ),
        ],
        if (_offersSubfolderView) ...[
          SizedBox(height: 4.r),
          _buildSwitchItem(
            index: 5,
            key: _generalItemKeys[5],
            title: AppLocale.subfolderView.getString(context),
            subtitle: AppLocale.subfolderViewSubtitle.getString(context),
            value: _system.subfolderView,
            onChanged: _toggleSubfolderView,
            // Subfolders only exist when recursive scanning is on, so the
            // toggle is inert otherwise.
            enabled: _system.recursiveScan,
          ),
        ],
      ],
    );
  }

  Widget _buildSwitchItem({
    required int index,
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final bool isFocused = _generalIndex == index;
    final theme = Theme.of(context);
    final double contentOpacity = enabled ? 1.0 : 0.4;

    return Container(
      key: key,
      decoration: BoxDecoration(
        color: isFocused ? theme.colorScheme.onSurface : Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
      ),
      child: InkWell(
        onTap: enabled
            ? () {
                SfxService().playNavSound();
                onChanged(!value);
              }
            : null,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          child: Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 10.r,
                          fontWeight: FontWeight.w600,
                          color: isFocused
                              ? theme.colorScheme.surface
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 9.r,
                          color: isFocused
                              ? theme.colorScheme.surface.withValues(alpha: 0.7)
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Opacity(
                opacity: contentOpacity,
                child: CustomToggleSwitch(
                  value: value,
                  onChanged: enabled ? onChanged : (_) {},
                  activeColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hidden tab: the games the user took out of the game lists, each with the
  /// action that puts it back. This is the only place a hidden game resurfaces,
  /// so it stays reachable even when every game of the system is hidden.
  Widget _buildHiddenGamesTab() {
    final theme = Theme.of(context);

    if (_isLoadingHiddenGames) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      );
    }

    if (_hiddenGames.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.visibility_off_rounded,
                size: 28.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              SizedBox(height: 8.r),
              Text(
                AppLocale.noHiddenGames.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              SizedBox(height: 4.r),
              Text(
                AppLocale.noHiddenGamesSubtitle.getString(context),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _hiddenScrollController,
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      itemCount: _totalHiddenItems,
      itemBuilder: (context, index) {
        if (index >= _hiddenGames.length) return _buildUnhideAllItem(index);
        return _buildHiddenGameItem(index, _hiddenGames[index]);
      },
    );
  }

  Widget _buildHiddenGameItem(int index, DatabaseGameModel game) {
    final theme = Theme.of(context);
    final isFocused = _hiddenIndex == index;
    final key = _hiddenItemKeys.putIfAbsent(index, () => GlobalKey());
    final displayName = game.realName ?? game.filename;
    // In the aggregated libraries the same game name can come from several
    // systems, so the row says which one it belongs to. Within one system the
    // filename is the only extra detail worth showing, and only when the title
    // above isn't already that same filename.
    final subtitle = _isVirtualLibrarySystem
        ? (game.systemRealName ?? game.systemFolderName ?? '')
        : (displayName == game.filename ? '' : game.filename);

    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: 4.r),
      child: Container(
        decoration: BoxDecoration(
          color: isFocused ? theme.colorScheme.onSurface : Colors.transparent,
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
        ),
        child: InkWell(
          onTap: () {
            SfxService().playNavSound();
            rebuild(() => _hiddenIndex = index);
            _unhideGame(game);
          },
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.r,
                          fontWeight: FontWeight.w600,
                          color: isFocused
                              ? theme.colorScheme.surface
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.r,
                            color: isFocused
                                ? theme.colorScheme.surface.withValues(
                                    alpha: 0.7,
                                  )
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: 8.r),
                _buildUnhidePill(AppLocale.unhide.getString(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnhideAllItem(int index) {
    final theme = Theme.of(context);
    final isFocused = _hiddenIndex == index;
    final key = _hiddenItemKeys.putIfAbsent(index, () => GlobalKey());

    return Padding(
      key: key,
      padding: EdgeInsets.only(top: 4.r, bottom: 4.r),
      child: Container(
        decoration: BoxDecoration(
          color: isFocused ? theme.colorScheme.onSurface : Colors.transparent,
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
        ),
        child: InkWell(
          onTap: () {
            SfxService().playNavSound();
            rebuild(() => _hiddenIndex = index);
            _unhideAllGames();
          },
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
            child: Row(
              children: [
                Icon(
                  Symbols.visibility_rounded,
                  size: 14.r,
                  color: isFocused
                      ? theme.colorScheme.surface
                      : theme.colorScheme.onSurface,
                ),
                SizedBox(width: 8.r),
                Expanded(
                  child: Text(
                    AppLocale.unhideAll.getString(context),
                    style: TextStyle(
                      fontSize: 10.r,
                      fontWeight: FontWeight.w600,
                      color: isFocused
                          ? theme.colorScheme.surface
                          : theme.colorScheme.onSurface,
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

  Widget _buildUnhidePill(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
          width: 1.r,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.r,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildEmulatorsTab() {
    return _buildCoresList();
  }

  Widget _buildCoresList() {
    if (_totalEmulators == 0) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(8.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.gamepad_rounded,
                size: 28.r,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              SizedBox(height: 8.r),
              Text(
                AppLocale.noEmulatorsAvailable.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: _centeredScrollController.rebuildNotifier,
      builder: (context, rebuildCount, child) {
        return ListView.builder(
          key: ValueKey('emulators_list_rebuild_$rebuildCount'),
          controller: _centeredScrollController.scrollController,
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
          itemCount: _totalEmulators,
          itemBuilder: (context, index) {
            final item = _displayItems[index];
            final isSelected = _selectedIndex == index;

            if (item is EmulatorGroupedCoreItem) {
              return _buildGroupedCoreItem(item, index, isSelected);
            } else if (item is EmulatorCoreItem) {
              return _buildCoreItem(
                item.core,
                index,
                isSelected,
                item.retroArchConfigured,
                item.retroArchPath,
              );
            } else if (item is EmulatorStandaloneItem) {
              return _buildStandaloneItem(item, index, isSelected);
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}
