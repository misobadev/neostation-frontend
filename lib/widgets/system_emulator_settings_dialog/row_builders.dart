part of '../system_emulator_settings_dialog.dart';

/// Emulator-list row builders for the settings dialog.
///
/// The grouped-core / core / standalone item renderers for the Emulators tab,
/// moved out of the monolith — behaviour is unchanged. State lives on the host
/// [State] (extensions can't declare fields); `setState` calls route through the
/// host [rebuild] bridge (`State.setState` is `@protected`).
extension _RowBuilders on _SystemEmulatorSettingsDialogState {
  Widget _buildGroupedCoreItem(
    EmulatorGroupedCoreItem item,
    int index,
    bool isSelected,
  ) {
    final theme = Theme.of(context);
    final isPickerSelected = isSelected && _emulatorActionIndex == 1;
    final isConfigured = Platform.isAndroid
        ? item.isInstalled
        : item.retroArchConfigured;
    final isDisabled = !isConfigured;

    final CoreEmulatorModel? selectedCore = item.cores.any((c) => c.isDefault)
        ? item.cores.firstWhere((c) => c.isDefault)
        : null;

    final customColors = AppThemes.getCustomColors(context);

    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected ? theme.colorScheme.onSurface : Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            rebuild(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Wrap left part and dropdown in Opacity
                Expanded(
                  child: Opacity(
                    opacity: isDisabled ? 0.5 : 1.0,
                    child: Row(
                      children: [
                        // Variant Icon
                        Container(
                          width: 24.r,
                          height: 24.r,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.surface.withValues(
                                    alpha: 0.2,
                                  )
                                : theme.colorScheme.primary.withValues(
                                    alpha: 0.1,
                                  ),
                            borderRadius:
                                Theme.of(
                                  context,
                                ).extension<CornerRadii>()?.radiusInternal ??
                                BorderRadius.circular(9.r),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4.r),
                            child: Image.asset(
                              'assets/images/emulators/retroarch.webp',
                              color: isSelected
                                  ? theme.colorScheme.surface
                                  : theme.colorScheme.onSurface,
                              colorBlendMode: BlendMode.srcIn,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    Symbols.gamepad_rounded,
                                    size: 14.r,
                                    color: isSelected
                                        ? theme.colorScheme.surface
                                        : theme.colorScheme.onSurface,
                                  ),
                            ),
                          ),
                        ),
                        SizedBox(width: 10.r),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.groupName,
                                style: TextStyle(
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? theme.colorScheme.surface
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    Platform.isAndroid
                                        ? (item.isInstalled
                                              ? Symbols.check_circle_rounded
                                              : Symbols.error_outline_rounded)
                                        : (item.retroArchConfigured
                                              ? Symbols.check_circle_rounded
                                              : Symbols.warning_rounded),
                                    size: 11.r,
                                    color: Platform.isAndroid
                                        ? (item.isInstalled
                                              ? customColors.successColor
                                              : customColors.warningColor)
                                        : (item.retroArchConfigured
                                              ? customColors.successColor
                                              : customColors.warningColor),
                                  ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    Platform.isAndroid
                                        ? (item.isInstalled
                                              ? AppLocale.installed.getString(
                                                  context,
                                                )
                                              : AppLocale.notInstalled
                                                    .getString(context))
                                        : (item.retroArchConfigured
                                              ? AppLocale.configured.getString(
                                                  context,
                                                )
                                              : AppLocale.notConfigured
                                                    .getString(context)),
                                    style: TextStyle(
                                      fontSize: 10.r,
                                      color: isSelected
                                          ? theme.colorScheme.surface
                                                .withValues(alpha: 0.7)
                                          : theme.colorScheme.onSurface
                                                .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                              if (!Platform.isAndroid &&
                                  item.retroArchConfigured &&
                                  item.retroArchPath != null)
                                Padding(
                                  padding: EdgeInsets.only(top: 2.r),
                                  child: Text(
                                    item.retroArchPath!,
                                    style: TextStyle(
                                      fontSize: 9.r,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5),
                                      fontFamily: 'monospace',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.r),
                        // MenuAnchor for Core selection
                        Container(
                          height: 28.r,
                          padding: EdgeInsets.symmetric(horizontal: 8.r),
                          decoration: BoxDecoration(
                            color: selectedCore != null
                                ? customColors
                                      .successColor // Green when a core is selected
                                : Theme.of(context).colorScheme.surface,
                            borderRadius:
                                Theme.of(
                                  context,
                                ).extension<CornerRadii>()?.radiusInternal ??
                                BorderRadius.circular(9.r),
                          ),
                          child: Theme(
                            data: theme.copyWith(
                              hoverColor: Colors.transparent,
                              splashColor: Colors.transparent,
                              highlightColor: Colors.transparent,
                            ),
                            child: MenuAnchor(
                              controller: _menuControllers[index],
                              childFocusNode: _menuFocusNodes[index],
                              onOpen: () {
                                rebuild(() => _openMenuIndex = index);
                                // Request focus on the first item when it opens
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (_menuCoresFocusNodes[index]?.isNotEmpty ==
                                      true) {
                                    _menuCoresFocusNodes[index]![0]
                                        .requestFocus();
                                  } else {
                                    _menuFocusNodes[index].requestFocus();
                                  }
                                });
                              },
                              onClose: () {
                                rebuild(() => _openMenuIndex = -1);
                              },
                              style: MenuStyle(
                                backgroundColor: WidgetStateProperty.all(
                                  theme.colorScheme.surface,
                                ),
                                shape: WidgetStateProperty.all(
                                  RoundedRectangleBorder(
                                    borderRadius:
                                        Theme.of(context)
                                            .extension<CornerRadii>()
                                            ?.radiusInternal ??
                                        BorderRadius.circular(9.r),
                                    side: BorderSide(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.1),
                                      width: 1.r,
                                    ),
                                  ),
                                ),
                              ),
                              menuChildren: item.cores.asMap().entries.map((
                                entry,
                              ) {
                                final coreIndex = entry.key;
                                final core = entry.value;
                                return MenuItemButton(
                                  focusNode:
                                      _menuCoresFocusNodes[index]?[coreIndex],
                                  onPressed: () => _setAsDefault(core),
                                  style: ButtonStyle(
                                    backgroundColor:
                                        WidgetStateProperty.resolveWith((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.focused,
                                          )) {
                                            return theme.colorScheme.primary
                                                .withValues(alpha: 0.2);
                                          }
                                          return null;
                                        }),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (core
                                          .isretroAchievementsCompatible) ...[
                                        Icon(
                                          Symbols.emoji_events_rounded,
                                          size: 12.r,
                                          color: customColors.warningColor,
                                        ),
                                        SizedBox(width: 6.r),
                                      ],
                                      Text(
                                        core.name
                                            .replaceAll('RetroArch ', '')
                                            .replaceAll('RetroArch32 ', '')
                                            .replaceAll('RetroArch64 ', '')
                                            .replaceAll(' (32-bit)', '')
                                            .replaceAll(' (64-bit)', ''),
                                        style: TextStyle(
                                          fontSize: 11.r,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                        ),
                                      ),
                                      if (core.isDefault) ...[
                                        SizedBox(width: 8.r),
                                        Icon(
                                          Symbols.check_circle_rounded,
                                          size: 12.r,
                                          color: customColors.successColor,
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }).toList(),
                              builder: (context, controller, child) {
                                return InkWell(
                                  canRequestFocus: false,
                                  focusColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  splashColor: Colors.transparent,
                                  onTap: isDisabled
                                      ? null
                                      : () {
                                          SfxService().playNavSound();
                                          if (controller.isOpen) {
                                            controller.close();
                                          } else {
                                            controller.open();
                                          }
                                        },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (selectedCore
                                              ?.isretroAchievementsCompatible ==
                                          true) ...[
                                        Icon(
                                          Symbols.emoji_events_rounded,
                                          size: 11.r,
                                          color: customColors.warningColor,
                                        ),
                                        SizedBox(width: 4.r),
                                      ],
                                      Text(
                                        selectedCore?.name
                                                .replaceAll('RetroArch ', '')
                                                .replaceAll('RetroArch32 ', '')
                                                .replaceAll('RetroArch64 ', '')
                                                .replaceAll(' (32-bit)', '')
                                                .replaceAll(' (64-bit)', '') ??
                                            AppLocale.selectCore.getString(
                                              context,
                                            ),
                                        style: TextStyle(
                                          fontSize: 10.r,
                                          fontWeight: FontWeight.bold,
                                          color: selectedCore != null
                                              ? customColors.onSuccessColor
                                              : theme.colorScheme.onSurface,
                                        ),
                                      ),
                                      Icon(
                                        Symbols.arrow_drop_down_rounded,
                                        size: 16.r,
                                        color: selectedCore != null
                                            ? customColors.onSuccessColor
                                            : theme.colorScheme.onSurface,
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Desktop: Configure RetroArch path (Persistent/Always enabled)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectRetroArchExe.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r),
                      decoration: BoxDecoration(
                        color: isPickerSelected
                            ? theme.colorScheme.primary.withValues(alpha: 0.28)
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.1,
                              ),
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusInternal ??
                            BorderRadius.circular(9.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(9.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureRetroArchPath();
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: isPickerSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
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

  Widget _buildCoreItem(
    CoreEmulatorModel core,
    int index,
    bool isSelected,
    bool retroArchConfigured,
    String? retroArchPath,
  ) {
    final customColors = AppThemes.getCustomColors(context);
    final theme = Theme.of(context);
    final isPickerSelected = isSelected && _emulatorActionIndex == 1;
    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.onSurface
            : Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            rebuild(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Core icon
                Container(
                  width: 24.r,
                  height: 24.r,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0.2)
                        : Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius:
                        Theme.of(
                          context,
                        ).extension<CornerRadii>()?.radiusInternal ??
                        BorderRadius.circular(9.r),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(4.r),
                    child: Image.asset(
                      'assets/images/emulators/retroarch.webp',
                      color: isSelected
                          ? Theme.of(context).colorScheme.surface
                          : Theme.of(context).colorScheme.onSurface,
                      colorBlendMode: BlendMode.srcIn,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Symbols.gamepad_rounded,
                        size: 14.r,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 10.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            core.name,
                            style: TextStyle(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.surface
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 1.r),
                      Row(
                        children: [
                          if (core.isretroAchievementsCompatible)
                            Container(
                              margin: EdgeInsets.only(right: 6.r),
                              padding: EdgeInsets.symmetric(
                                horizontal: 6.r,
                                vertical: 2.r,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.onSurface,
                                borderRadius:
                                    Theme.of(context)
                                        .extension<CornerRadii>()
                                        ?.radiusInternal ??
                                    BorderRadius.circular(9.r),
                                border: Border.all(
                                  color: customColors.warningColor,
                                  width: 0.5.r,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Symbols.emoji_events_rounded,
                                    size: 10.r,
                                    color: customColors.warningColor,
                                  ),
                                ],
                              ),
                            ),
                          // Status indicator (desktop: configured/not configured)
                          Row(
                            children: [
                              Icon(
                                Platform.isAndroid
                                    ? (core.isInstalled
                                          ? Symbols.check_circle_rounded
                                          : Symbols.error_outline_rounded)
                                    : (retroArchConfigured
                                          ? Symbols.check_circle_rounded
                                          : Symbols.warning_rounded),
                                size: 12.r,
                                color: Platform.isAndroid
                                    ? (core.isInstalled
                                          ? customColors.successColor
                                          : customColors.warningColor)
                                    : (retroArchConfigured
                                          ? customColors.successColor
                                          : customColors.warningColor),
                              ),
                              SizedBox(width: 4.r),
                              Text(
                                Platform.isAndroid
                                    ? (core.isInstalled
                                          ? AppLocale.installed.getString(
                                              context,
                                            )
                                          : AppLocale.notInstalled.getString(
                                              context,
                                            ))
                                    : (retroArchConfigured
                                          ? AppLocale.configured.getString(
                                              context,
                                            )
                                          : AppLocale.notConfigured.getString(
                                              context,
                                            )),
                                style: TextStyle(
                                  fontSize: 11.r,
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.surface
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (!Platform.isAndroid &&
                          retroArchConfigured &&
                          retroArchPath != null)
                        Padding(
                          padding: EdgeInsets.only(top: 2.r),
                          child: Text(
                            retroArchPath,
                            style: TextStyle(
                              fontSize: 9.r,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                // Desktop: Configure RetroArch path (Persistent)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectRetroArchExe.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r, right: 8.r),
                      decoration: BoxDecoration(
                        color: isPickerSelected
                            ? theme.colorScheme.primary.withValues(alpha: 0.28)
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.1,
                              ),
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusInternal ??
                            BorderRadius.circular(9.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(9.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureRetroArchPath();
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: isPickerSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Set as default button - always visible
                Builder(
                  builder: (context) {
                    final isConfigured = Platform.isAndroid
                        ? true // On Android assuming configured/installed check handled elsewhere or allowing selection
                        : retroArchConfigured;

                    final isDisabled = !isConfigured;

                    final customColors = AppThemes.getCustomColors(context);

                    return Opacity(
                      opacity: isDisabled ? 0.5 : 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: core.isDefault
                              ? customColors.successColor
                              : Theme.of(context).colorScheme.onSurface,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(9.r),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            overlayColor: WidgetStateProperty.all(
                              Colors.transparent,
                            ),
                            splashFactory: NoSplash.splashFactory,
                            borderRadius:
                                Theme.of(
                                  context,
                                ).extension<CornerRadii>()?.radiusInternal ??
                                BorderRadius.circular(9.r),
                            focusNode: _setDefaultButtonFocusNodes[index],
                            onTap: (core.isDefault || isDisabled)
                                ? null
                                : () {
                                    SfxService().playEnterSound();
                                    _setAsDefault(core);
                                  }, // Disabled when default or not configured
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 10.r,
                                vertical: 6.r,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (core.isDefault)
                                    Icon(
                                      Symbols.check_circle_rounded,
                                      size: 12.r,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    )
                                  else
                                    SizedBox(
                                      height: 12.r,
                                      width: 12.r,
                                      child: Image.asset(
                                        'assets/images/gamepad/Xbox_A_button.png',
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        colorBlendMode: BlendMode.srcIn,
                                      ),
                                    ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    core.isDefault
                                        ? AppLocale.selected.getString(context)
                                        : AppLocale.select.getString(context),
                                    style: TextStyle(
                                      fontSize: 10.r,
                                      fontWeight: FontWeight.bold,
                                      color: core.isDefault
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStandaloneItem(
    EmulatorStandaloneItem item,
    int index,
    bool isSelected,
  ) {
    final standalone = item.standalone;
    final isInstalled = item.isInstalled;
    final theme = Theme.of(context);
    final isPickerSelected = isSelected && _emulatorActionIndex == 1;

    // Status logic (Android: installed, Desktop: configured)
    final isConfigured = Platform.isAndroid
        ? isInstalled
        : standalone.isConfigured;

    final isDisabled = !isConfigured;

    final customColors = AppThemes.getCustomColors(context);

    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected ? theme.colorScheme.onSurface : Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            rebuild(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Wrap main info in Opacity
                Expanded(
                  child: Opacity(
                    opacity: isDisabled ? 0.5 : 1.0,
                    child: Row(
                      children: [
                        // Standalone icon
                        Container(
                          width: 24.r,
                          height: 24.r,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.surface.withValues(
                                    alpha: 0.2,
                                  )
                                : theme.colorScheme.primary.withValues(
                                    alpha: 0.1,
                                  ),
                            borderRadius:
                                Theme.of(
                                  context,
                                ).extension<CornerRadii>()?.radiusInternal ??
                                BorderRadius.circular(9.r),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4.r),
                            child: Icon(
                              Symbols.apps_rounded,
                              size: 14.r,
                              color: isSelected
                                  ? theme.colorScheme.surface
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        SizedBox(width: 10.r),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                standalone.name,
                                style: TextStyle(
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? theme.colorScheme.surface
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              SizedBox(height: 1.r),
                              Row(
                                children: [
                                  if (standalone.isretroAchievementsCompatible)
                                    Container(
                                      margin: EdgeInsets.only(right: 6.r),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6.r,
                                        vertical: 2.r,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        borderRadius:
                                            Theme.of(context)
                                                .extension<CornerRadii>()
                                                ?.radiusInternal ??
                                            BorderRadius.circular(9.r),
                                        border: Border.all(
                                          color: customColors.warningColor,
                                          width: 0.5.r,
                                        ),
                                      ),
                                      child: Icon(
                                        Symbols.emoji_events_rounded,
                                        size: 10.r,
                                        color: customColors.warningColor,
                                      ),
                                    ),
                                  Icon(
                                    Platform.isAndroid
                                        ? (isInstalled
                                              ? Symbols.check_circle_rounded
                                              : Symbols.error_outline_rounded)
                                        : (standalone.isConfigured
                                              ? Symbols.check_circle_rounded
                                              : Symbols.warning_rounded),
                                    size: 12.r,
                                    color: isConfigured
                                        ? customColors.successColor
                                        : customColors.warningColor,
                                  ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    Platform.isAndroid
                                        ? (isInstalled
                                              ? AppLocale.installed.getString(
                                                  context,
                                                )
                                              : AppLocale.notInstalled
                                                    .getString(context))
                                        : (standalone.isConfigured
                                              ? AppLocale.configured.getString(
                                                  context,
                                                )
                                              : AppLocale.notConfigured
                                                    .getString(context)),
                                    style: TextStyle(
                                      fontSize: 11.r,
                                      color: isSelected
                                          ? theme.colorScheme.surface
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  if (!Platform.isAndroid &&
                                      standalone.isConfigured &&
                                      standalone.userPath != null) ...[
                                    SizedBox(width: 8.r),
                                    Expanded(
                                      child: Text(
                                        standalone.userPath!,
                                        style: TextStyle(
                                          fontSize: 9.r,
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.5),
                                          fontFamily: 'monospace',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Select button
                Opacity(
                  opacity: isDisabled ? 0.5 : 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: standalone.isUserDefault == true
                          ? customColors.successColor
                          : Theme.of(context).colorScheme.tertiary,
                      borderRadius:
                          Theme.of(
                            context,
                          ).extension<CornerRadii>()?.radiusInternal ??
                          BorderRadius.circular(9.r),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        canRequestFocus: false,
                        focusColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusInternal ??
                            BorderRadius.circular(9.r),
                        onTap: (standalone.isUserDefault == true || isDisabled)
                            ? null
                            : () {
                                SfxService().playEnterSound();
                                _setStandaloneAsDefault(standalone);
                              },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10.r,
                            vertical: 6.r,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (standalone.isUserDefault == true)
                                Icon(
                                  Symbols.check_circle_rounded,
                                  size: 12.r,
                                  color: theme.colorScheme.onTertiary,
                                )
                              else
                                SizedBox(
                                  height: 12.r,
                                  width: 12.r,
                                  child: Image.asset(
                                    'assets/images/gamepad/Xbox_A_button.png',
                                    color: theme.colorScheme.onTertiary,
                                    colorBlendMode: BlendMode.srcIn,
                                  ),
                                ),
                              SizedBox(width: 4.r),
                              Text(
                                standalone.isUserDefault == true
                                    ? AppLocale.selected.getString(context)
                                    : AppLocale.select.getString(context),
                                style: TextStyle(
                                  fontSize: 10.r,
                                  fontWeight: FontWeight.bold,
                                  color: standalone.isUserDefault == true
                                      ? theme.colorScheme.onTertiary
                                      : theme.colorScheme.onTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Desktop: Folder button (Persistent)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectExecutablePath.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r),
                      decoration: BoxDecoration(
                        color: isPickerSelected
                            ? theme.colorScheme.primary.withValues(alpha: 0.28)
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.1,
                              ),
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusInternal ??
                            BorderRadius.circular(9.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(9.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureStandalonePath(standalone);
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: isPickerSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
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
