import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';
import 'settings_title.dart';

final _log = LoggerService.instance;

class ThemesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final ValueChanged<int>? onSelectionChanged;

  const ThemesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    this.onSelectionChanged,
  });

  @override
  State<ThemesSettingsContent> createState() => ThemesSettingsContentState();
}

class ThemesSettingsContentState extends State<ThemesSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = [];

  int get _gridColumns => Responsive.getThemesCrossAxisCount(context);

  int getItemCount() => _itemKeys.length;

  void _initKeys(int count) {
    _itemKeys.clear();
    for (int i = 0; i < count; i++) {
      _itemKeys.add(GlobalKey());
    }
  }

  void _ensureSelectedItemVisible(int index) {
    if (index >= 0 && index < _itemKeys.length) {
      final ctx = _itemKeys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    }
  }

  void navigateUp() {
    final newIndex = GridNavUtils.navigateUp(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  void navigateDown() {
    final newIndex = GridNavUtils.navigateDown(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  bool navigateLeft() {
    final currentCol = widget.selectedContentIndex % _gridColumns;
    if (currentCol == 0) return true; // return to menu

    final newIndex = GridNavUtils.navigateLeft(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
    return false;
  }

  void navigateRight() {
    final newIndex = GridNavUtils.navigateRight(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  void scrollToIndex(int index) => _ensureSelectedItemVisible(index);

  void selectItem(int index) {
    _onItemTapped(index);
  }

  List<String> _getSystemFolderNames() {
    final sqliteProvider = context.read<SqliteConfigProvider>();
    return sqliteProvider.availableSystems
        .where((s) => s.folderName != 'all-background')
        .map((s) => s.folderName)
        .toList();
  }

  void _onItemTapped(int index) async {
    final neoAssets = context.read<NeoAssetsProvider>();
    final themes = neoAssets.themes;

    String targetFolder;
    String targetName;

    if (index == 0) {
      targetFolder = '';
      targetName = AppLocale.neoThemesNone.getString(context);
    } else {
      final themeIndex = index - 1;
      if (themeIndex < 0 || themeIndex >= themes.length) return;
      targetFolder = themes[themeIndex].folder;
      targetName = themes[themeIndex].name;
    }

    if (neoAssets.activeThemeFolder == targetFolder) return;

    final confirmed = await _showConfirmDialog(
      targetName,
      targetFolder.isEmpty,
    );
    if (!confirmed) return;
    if (!mounted) return;

    widget.onSelectionChanged?.call(index);

    if (targetFolder.isEmpty) {
      await neoAssets.clearTheme();
    } else {
      final systemFolders = _getSystemFolderNames();
      await neoAssets.downloadAndApplyTheme(targetFolder, systemFolders);
    }
  }

  Future<bool> _showConfirmDialog(String themeName, bool isNone) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          _ThemeConfirmDialog(themeName: themeName, isNone: isNone),
    );
    return result ?? false;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neoAssets = context.watch<NeoAssetsProvider>();
    final theme = Theme.of(context);

    final List<_ThemeItem> items = [
      _ThemeItem(
        label: AppLocale.neoThemesNone.getString(context),
        folder: '',
        previewUrl: '',
        isAi: false,
      ),
      ...neoAssets.themes.map(
        (t) => _ThemeItem(
          label: t.name,
          folder: t.folder,
          previewUrl: t.previewUrl,
          isAi: t.isAi,
        ),
      ),
    ];

    if (_itemKeys.length != items.length) {
      _initKeys(items.length);
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.neoThemes.getString(context),
            subtitle: AppLocale.neoThemesSubtitle.getString(context),
          ),
          SizedBox(height: 12.r),

          if (neoAssets.downloading)
            _buildDownloadProgress(neoAssets, theme)
          else if (neoAssets.loading)
            _buildLoadingIndicator(theme)
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _gridColumns,
                crossAxisSpacing: 8.r,
                mainAxisSpacing: 8.r,
                childAspectRatio: 1.05,
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final isSelected = neoAssets.activeThemeFolder == item.folder;
                final isFocused =
                    widget.isContentFocused &&
                    widget.selectedContentIndex == index;

                return Container(
                  key: _itemKeys[index],
                  child: _NeoThemeCard(
                    item: item,
                    isSelected: isSelected,
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      _onItemTapped(index);
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.all(32.r),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24.r,
              height: 24.r,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            SizedBox(height: 12.r),
            Text(
              AppLocale.neoThemesLoading.getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress(NeoAssetsProvider neoAssets, ThemeData theme) {
    final primary = theme.colorScheme.primary;
    final pct = (neoAssets.downloadProgress * 100).toInt();

    return Padding(
      padding: EdgeInsets.all(32.r),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 48.r,
              height: 48.r,
              child: CircularProgressIndicator(
                value: neoAssets.downloadProgress,
                strokeWidth: 3,
                color: primary,
                backgroundColor: primary.withValues(alpha: 0.15),
              ),
            ),
            SizedBox(height: 16.r),
            Text(
              AppLocale.neoThemesDownloading.getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
            SizedBox(height: 4.r),
            Text(
              '$pct%',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 14.r,
                fontWeight: FontWeight.w600,
                color: primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeItem {
  final String label;
  final String folder;
  final String previewUrl;
  final bool isAi;

  const _ThemeItem({
    required this.label,
    required this.folder,
    required this.previewUrl,
    required this.isAi,
  });
}

class _NeoThemeCard extends StatelessWidget {
  static final Set<String> _loggedPreviewNormalizations = <String>{};

  final _ThemeItem item;
  final bool isSelected;
  final bool isFocused;
  final VoidCallback onTap;

  const _NeoThemeCard({
    required this.item,
    required this.isSelected,
    required this.isFocused,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              margin: EdgeInsets.symmetric(vertical: 4.h),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: isFocused ? primary : Colors.transparent,
                  width: 2.r,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.3),
                          blurRadius: 8.r,
                          spreadRadius: 1.r,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.r),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Preview image or placeholder
                    _buildPreview(context, theme),

                    // Selection indicator: centered checkmark, only when selected
                    if (isSelected)
                      Center(
                        child: Container(
                          width: 36.r,
                          height: 36.r,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.greenAccent,
                          ),
                          child: Icon(
                            Symbols.check_rounded,
                            color: Colors.black,
                            size: 24.r,
                          ),
                        ),
                      ),

                    if (item.isAi)
                      Positioned(
                        top: 8.r,
                        left: 8.r,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6.r,
                            vertical: 2.r,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(999.r),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                              width: 1.r,
                            ),
                          ),
                          child: Text(
                            'AI',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 8.r,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),

                    // Tap layer
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          onTap: onTap,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 4.r),
          Text(
            item.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isFocused || isSelected
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 11.r,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context, ThemeData theme) {
    final normalizedPreviewUrl = _normalizePreviewUrl(item.previewUrl);

    if (normalizedPreviewUrl.isNotEmpty) {
      final normalizationKey =
          '${item.folder}|${item.previewUrl}|$normalizedPreviewUrl';
      if (item.previewUrl != normalizedPreviewUrl &&
          _loggedPreviewNormalizations.add(normalizationKey)) {
        _log.i(
          'Theme preview URL normalized for "${item.folder}": '
          'original="${item.previewUrl}" resolved="$normalizedPreviewUrl"',
        );
      }

      return Image.network(
        normalizedPreviewUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) {
          _log.w(
            'Theme preview failed for "${item.folder}" '
            '(label="${item.label}") url="$normalizedPreviewUrl" error="$error"',
          );
          if (stackTrace != null) {
            _log.d('Theme preview stackTrace: $stackTrace');
          }
          return _buildPlaceholder(theme);
        },
        loadingBuilder: (_, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return _buildPlaceholder(theme);
        },
      );
    }
    return _buildPlaceholder(theme);
  }

  String _normalizePreviewUrl(String value) {
    var url = value.trim();
    if (url.isEmpty) return '';

    // Handle legacy malformed URLs like:
    // https://raw.../https://github.com/owner/repo/blob/main/file.webp
    final embeddedGithub = RegExp(
      r'https?://github\.com/[^\s]+',
    ).firstMatch(url);
    if (embeddedGithub != null) {
      url = embeddedGithub.group(0)!;
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;

    if (uri.host == 'github.com' &&
        uri.pathSegments.length >= 5 &&
        uri.pathSegments[2] == 'blob') {
      final owner = uri.pathSegments[0];
      final repo = uri.pathSegments[1];
      final branch = uri.pathSegments[3];
      final filePath = uri.pathSegments.sublist(4).join('/');
      return _forceWebpPreviewUrl(
        'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath',
      );
    }

    return _forceWebpPreviewUrl(url);
  }

  String _forceWebpPreviewUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;

    final path = uri.path;
    final lowerPath = path.toLowerCase();
    if (!lowerPath.endsWith('.jpg') &&
        !lowerPath.endsWith('.jpeg') &&
        !lowerPath.endsWith('.png')) {
      return url;
    }

    final webpPath = path.replaceFirst(
      RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false),
      '.webp',
    );
    return uri.replace(path: webpPath).toString();
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      child: Center(
        child: Icon(
          item.folder.isEmpty ? Symbols.block_rounded : Symbols.image_rounded,
          size: 28.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
        ),
      ),
    );
  }
}

class _ThemeConfirmDialog extends StatefulWidget {
  final String themeName;
  final bool isNone;

  const _ThemeConfirmDialog({required this.themeName, required this.isNone});

  @override
  State<_ThemeConfirmDialog> createState() => _ThemeConfirmDialogState();
}

class _ThemeConfirmDialogState extends State<_ThemeConfirmDialog> {
  late final GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (mounted) Navigator.of(context).pop(true);
      },
      onBack: () {
        if (mounted) Navigator.of(context).pop(false);
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'theme_confirm_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('theme_confirm_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(color: primary.withValues(alpha: 0.3)),
      ),
      title: Row(
        children: [
          Icon(Symbols.image_rounded, color: primary, size: 20.r),
          SizedBox(width: 8.r),
          Text(
            AppLocale.neoThemesApplyTitle.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 14.r,
              color: primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"${widget.themeName}"',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 13.r,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (!widget.isNone) ...[
            SizedBox(height: 8.r),
            Text(
              AppLocale.neoThemesApplyBody.getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                AppLocale.cancel.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12.r,
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: theme.colorScheme.onPrimary,
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  color: theme.colorScheme.onPrimary,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                AppLocale.apply.getString(context),
                style: TextStyle(fontSize: 12.r),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
