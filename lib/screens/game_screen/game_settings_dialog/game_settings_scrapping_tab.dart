import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/screens/game_screen/my_games_carousel.dart';
import 'package:neostation/screens/game_screen/my_games_grid.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/artwork_cache.dart';
import 'package:neostation/widgets/custom_notification.dart';

/// Sub-tabs inside the Scrapping tab of [GameSettingsDialog].
enum _ScrappingSubTab { data, media }

/// Scrapping tab for [GameSettingsDialog]: force rescrape plus manual
/// metadata (title, descriptions, developer, publisher, genre) and artwork
/// (screenshot, wheel, fanart, boxart) editing.
///
/// The tab is split into two sub-tabs:
///  * [Scraping Data] — metadata fields plus the save action.
///  * [Scraping Media] — artwork rows; each row saves immediately on change.
class GameSettingsScrappingTab extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final FileProvider fileProvider;
  final bool isAllMode;
  final VoidCallback? onGameUpdated;

  const GameSettingsScrappingTab({
    super.key,
    required this.game,
    required this.system,
    required this.fileProvider,
    required this.isAllMode,
    this.onGameUpdated,
  });

  @override
  State<GameSettingsScrappingTab> createState() =>
      GameSettingsScrappingTabState();
}

class GameSettingsScrappingTabState extends State<GameSettingsScrappingTab> {
  static final _log = LoggerService.instance;

  // ── Sub-tabs ────────────────────────────────────────────────────────────
  _ScrappingSubTab _currentSubTab = _ScrappingSubTab.data;

  // ── Navigation entries (per sub-tab) ────────────────────────────────────
  // Data tab: rescrape, title, developer, publisher, genre, 6 descriptions, save.
  static const int _idxRescrape = 0;
  static const int _idxTitle = 1;
  static const int _idxDeveloper = 2;
  static const int _idxPublisher = 3;
  static const int _idxGenre = 4;
  static const int _idxDescStart = 5;
  static const int _idxSave = 11;
  static const int _totalDataItems = 12;

  // Media tab: screenshot, wheel, fanart, boxart.
  static const int _idxImageStart = 0;
  static const int _totalMediaItems = 4;

  static const _descLanguages = ['en', 'es', 'fr', 'de', 'it', 'pt'];
  static const _imageTypes = ['screenshots', 'wheels', 'fanarts', 'box2d'];

  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  // Text editing
  final _titleController = TextEditingController();
  final _developerController = TextEditingController();
  final _publisherController = TextEditingController();
  final _genreController = TextEditingController();
  final Map<String, TextEditingController> _descControllers = {
    for (final lang in _descLanguages) lang: TextEditingController(),
  };
  final Map<int, FocusNode> _fieldFocusNodes = {};
  int? _activeFieldIndex;

  // Async state
  bool _isScraping = false;
  double _scrapeProgress = 0;
  bool _isSaving = false;
  int _thumbsVersion = 0;

  int get _totalItems => _currentSubTab == _ScrappingSubTab.data
      ? _totalDataItems
      : _totalMediaItems;

  int get _itemKeyIndex => _currentSubTab.index * 100 + _selectedIndex;

  GlobalKey _itemKey(int navIndex) => _itemKeys.putIfAbsent(
    _currentSubTab.index * 100 + navIndex,
    () => GlobalKey(),
  );

  FocusNode _focusNodeFor(int navIndex) => _fieldFocusNodes.putIfAbsent(
    navIndex,
    () => FocusNode()..addListener(() => _onFieldFocusChanged(navIndex)),
  );

  /// True while a metadata text field holds focus — the host dialog turns B
  /// into 'leave the field' instead of 'close' in that state.
  bool get isEditingText => _activeFieldIndex != null;

  String? get _systemId => widget.game.systemId ?? widget.system.id;

  String get _folder => widget.isAllMode && widget.game.systemFolderName != null
      ? widget.game.systemFolderName!
      : widget.system.primaryFolderName;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _titleController.dispose();
    _developerController.dispose();
    _publisherController.dispose();
    _genreController.dispose();
    for (final c in _descControllers.values) {
      c.dispose();
    }
    for (final n in _fieldFocusNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  // ── Data ────────────────────────────────────────────────────────────────

  Future<void> _loadMetadata() async {
    final systemId = _systemId;
    Map<String, dynamic>? row;
    if (systemId != null) {
      row = await ScraperRepository.getGameMetadata(
        systemId,
        widget.game.romname,
      );
    }
    if (!mounted) return;
    setState(() {
      _titleController.text =
          (row?['real_name'] as String?) ??
          (widget.game.name.isNotEmpty ? widget.game.name : '');
      _developerController.text =
          (row?['developer'] as String?) ?? widget.game.developer;
      _publisherController.text =
          (row?['publisher'] as String?) ?? widget.game.publisher;
      _genreController.text = (row?['genre'] as String?) ?? widget.game.genre;
      for (final lang in _descLanguages) {
        // Exact-language values only — getDescriptionForLanguage would leak
        // the EN fallback into other languages' fields.
        _descControllers[lang]!.text =
            (row?['description_$lang'] as String?) ??
            widget.game.descriptions?[lang] ??
            '';
      }
    });
  }

  Future<void> _saveMetadata() async {
    final systemId = _systemId;
    if (systemId == null || _isSaving) return;
    setState(() => _isSaving = true);

    String? nullable(String text) {
      final trimmed = text.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final fields = <String, dynamic>{
      'real_name': nullable(_titleController.text),
      'developer': nullable(_developerController.text),
      'publisher': nullable(_publisherController.text),
      'genre': nullable(_genreController.text),
      for (final lang in _descLanguages)
        'description_$lang': nullable(_descControllers[lang]!.text),
    };

    final ok = await ScraperRepository.updateGameMetadata(
      systemId,
      widget.game.romname,
      fields,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    AppNotification.showNotification(
      context,
      ok
          ? AppLocale.metadataSaved.getString(context)
          : AppLocale.failedToSaveSetting.getString(context),
      type: ok ? NotificationType.success : NotificationType.error,
    );
    if (ok) widget.onGameUpdated?.call();
  }

  // ── Sub-tab switching ───────────────────────────────────────────────────

  void _focusFieldAt(int index) {
    setState(() {
      _selectedIndex = index;
      _activeFieldIndex = index;
    });
    _focusNodeFor(index).requestFocus();
  }

  /// Moves focus to the next input field when the user presses A/Enter while
  /// a single-line metadata field is focused. Matches the ScreenScraper login
  /// form behavior.
  void _focusNextInput(int currentIndex) {
    if (currentIndex >= _idxTitle && currentIndex < _idxGenre) {
      _focusFieldAt(currentIndex + 1);
    } else if (currentIndex == _idxGenre) {
      setState(() => _selectedIndex = _idxSave);
    } else if (currentIndex == _idxSave) {
      _saveMetadata();
    }
  }

  void _switchSubTab(_ScrappingSubTab tab) {
    if (_currentSubTab == tab) return;
    _unfocusActiveField();
    SfxService().playNavSound();
    setState(() {
      _currentSubTab = tab;
      _selectedIndex = 0;
    });
  }

  // ── Force rescrape ──────────────────────────────────────────────────────

  List<String> _artworkPaths() =>
      scrapedArtworkPaths(widget.game, _folder, widget.fileProvider);

  Future<void> _forceRescrape() async {
    if (_isScraping) return;
    final romPath = widget.game.romPath;
    if (romPath == null) return;

    setState(() {
      _isScraping = true;
      _scrapeProgress = 0;
    });

    // Resolve the real system (not the favorites/all virtual one).
    SystemModel targetSystem = widget.system;
    if (widget.isAllMode && widget.game.systemFolderName != null) {
      final original = await SystemRepository.getSystemByFolderName(
        widget.game.systemFolderName!,
      );
      if (original != null) targetSystem = original;
    }

    final systemId = targetSystem.id;
    if (systemId == null) {
      if (mounted) setState(() => _isScraping = false);
      return;
    }

    try {
      final result = await ScreenScraperService.scrapeSingleGame(
        appSystemId: systemId,
        romName: widget.game.romname,
        systemFolder: targetSystem.primaryFolderName,
        romPath: romPath,
        gameName: widget.game.name,
        forceOverwrite: true,
        onProgress: (status, progress) {
          if (mounted) setState(() => _scrapeProgress = progress);
        },
      );

      // Bust cached artwork so the fresh media shows up everywhere.
      await evictScrapedArtwork(_artworkPaths());
      GamesGrid.evictArtworkCaches(_artworkPaths());
      GamesCarousel.evictArtworkCaches(_artworkPaths());

      if (mounted) {
        final message = result['success'] == true
            ? 'Scraping completed'
            : 'Scraping failed: ${result['message'].toString().getString(context)}';
        AppNotification.showNotification(
          context,
          message,
          type: result['success'] == true
              ? NotificationType.success
              : NotificationType.error,
        );
      }
      if (result['success'] == true) {
        await _loadMetadata();
        if (mounted) setState(() => _thumbsVersion++);
        widget.onGameUpdated?.call();
      }
    } catch (e) {
      _log.e('Force rescrape failed: $e');
    } finally {
      if (mounted) setState(() => _isScraping = false);
    }
  }

  // ── Artwork replacement ─────────────────────────────────────────────────

  String _pathForImageType(String type) => type == 'screenshots'
      ? widget.game.getScreenshotPath(_folder, widget.fileProvider)
      : widget.game.getImagePath(_folder, type, widget.fileProvider);

  Future<void> _replaceImage(String type) async {
    final result = await FilePicker.pickFile(type: FileType.image);
    final srcPath = result?.path;
    if (srcPath == null || !mounted) return;

    try {
      // Write into NeoStation's own media folder, never over the path the
      // thumbnail happens to be read from: for an ES-DE imported library that
      // path is the user's `downloaded_media` file (e.g. a miximage), which is
      // read-only to us. The new file shadows it everywhere from now on.
      final targetPath = widget.game.getWritableImagePath(
        _folder,
        type,
        widget.fileProvider,
      );
      await File(targetPath).parent.create(recursive: true);
      await File(srcPath).copy(targetPath);
      await evictScrapedArtwork([targetPath]);
      GamesGrid.evictArtworkCaches([targetPath]);
      GamesCarousel.evictArtworkCaches([targetPath]);

      // Keep the grid's layout math correct for the new boxart dimensions.
      if (type == 'box2d' && widget.game.systemId != null) {
        final bytes = await File(targetPath).readAsBytes();
        final decoded = await decodeImageFromList(bytes);
        await GameRepository.updateBox2dAspectRatio(
          widget.game.systemId!,
          widget.game.romname,
          '${decoded.width}/${decoded.height}',
        );
      }

      if (!mounted) return;
      setState(() => _thumbsVersion++);
      widget.onGameUpdated?.call();
      AppNotification.showNotification(
        context,
        AppLocale.imageUpdated.getString(context),
        type: NotificationType.success,
      );
    } catch (e) {
      _log.e('Artwork replacement failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.failedToSaveSetting.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  // ── Gamepad delegates ───────────────────────────────────────────────────

  bool moveUp() {
    // While a text field is focused, let the field handle its own cursor/selection
    // navigation. The user can press Escape to exit the field and resume list nav.
    if (isEditingText) return false;
    final newIndex = (_selectedIndex - 1).clamp(0, _totalItems - 1);
    final moved = newIndex != _selectedIndex;
    if (moved) {
      setState(() => _selectedIndex = newIndex);
    }
    _scrollToSelectedItem();
    return moved;
  }

  bool moveDown() {
    // While a text field is focused, let the field handle its own cursor/selection
    // navigation. The user can press Escape to exit the field and resume list nav.
    if (isEditingText) return false;
    final newIndex = (_selectedIndex + 1).clamp(0, _totalItems - 1);
    final moved = newIndex != _selectedIndex;
    if (moved) {
      setState(() => _selectedIndex = newIndex);
    }
    _scrollToSelectedItem();
    return moved;
  }

  /// Switches to the left sub-tab (Data) when on the Media tab.
  bool moveLeft() {
    _unfocusActiveField();
    if (_currentSubTab == _ScrappingSubTab.media) {
      _switchSubTab(_ScrappingSubTab.data);
      _scrollToSelectedItem();
      return true;
    }
    return false;
  }

  /// Switches to the right sub-tab (Media) when on the Data tab.
  bool moveRight() {
    _unfocusActiveField();
    if (_currentSubTab == _ScrappingSubTab.data) {
      _switchSubTab(_ScrappingSubTab.media);
      _scrollToSelectedItem();
      return true;
    }
    return false;
  }

  void trigger() {
    // If a text field is focused, A/Enter advances to the next field (mirrors
    // the ScreenScraper login form behavior).
    final editingIndex = _activeFieldIndex;
    if (editingIndex != null) {
      _focusNextInput(editingIndex);
      return;
    }

    final idx = _selectedIndex;
    if (_currentSubTab == _ScrappingSubTab.data) {
      if (idx == _idxRescrape) {
        _forceRescrape();
      } else if (idx >= _idxTitle && idx < _idxSave) {
        _focusFieldAt(idx);
      } else if (idx == _idxSave) {
        _saveMetadata();
      }
    } else {
      if (idx >= _idxImageStart && idx < _totalMediaItems) {
        _replaceImage(_imageTypes[idx]);
      }
    }
  }

  /// Leaves the currently edited text field (used by the host on B).
  void cancelEdit() => _unfocusActiveField();

  void _unfocusActiveField() {
    final idx = _activeFieldIndex;
    if (idx == null) return;
    _fieldFocusNodes[idx]?.unfocus();
  }

  void _onFieldFocusChanged(int navIndex) {
    final node = _fieldFocusNodes[navIndex];
    if (node == null) return;
    setState(() {
      _activeFieldIndex = node.hasFocus ? navIndex : null;
    });
    // The keyboard reduces the dialog's scroll viewport on Android. Bring the
    // focused row into that viewport so lower metadata fields remain readable
    // while the user types.
    if (node.hasFocus) _scrollToSelectedItem();
  }

  void _scrollToSelectedItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _itemKeys[_itemKeyIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Tapping outside a text field leaves edit mode.
      onTap: _unfocusActiveField,
      child: Column(
        children: [
          _buildSubTabBar(context),
          Expanded(
            child: _currentSubTab == _ScrappingSubTab.data
                ? _buildDataTab(context)
                : _buildMediaTab(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SubTabItem(
              label: AppLocale.scrapingData.getString(context),
              isSelected: _currentSubTab == _ScrappingSubTab.data,
              onTap: () => _switchSubTab(_ScrappingSubTab.data),
            ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: _SubTabItem(
              label: AppLocale.scrapingMedia.getString(context),
              isSelected: _currentSubTab == _ScrappingSubTab.media,
              onTap: () => _switchSubTab(_ScrappingSubTab.media),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataTab(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.all(12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Force Rescrape.
          _NavRow(
            key: _itemKey(_idxRescrape),
            isSelected: _selectedIndex == _idxRescrape,
            icon: Symbols.refresh_rounded,
            label: AppLocale.forceRescrape.getString(context),
            subtitle: _isScraping
                ? '${AppLocale.scraping.getString(context)} '
                      '${(_scrapeProgress * 100).toInt()}%'
                : AppLocale.rescrape.getString(context),
            trailing: _isScraping
                ? SizedBox(
                    width: 60.r,
                    child: LinearProgressIndicator(
                      value: _scrapeProgress > 0 ? _scrapeProgress : null,
                      minHeight: 4.r,
                      backgroundColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.1,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.secondary,
                      ),
                    ),
                  )
                : null,
            onTap: () {
              SfxService().playNavSound();
              setState(() => _selectedIndex = _idxRescrape);
              _forceRescrape();
            },
          ),

          _SectionHeader(
            icon: Symbols.edit_rounded,
            label: AppLocale.description.getString(context),
          ),
          _MetadataFieldRow(
            key: _itemKey(_idxTitle),
            isSelected: _selectedIndex == _idxTitle,
            label: AppLocale.gameTitle.getString(context),
            controller: _titleController,
            focusNode: _focusNodeFor(_idxTitle),
            readOnly: _activeFieldIndex != _idxTitle,
            onTap: () => setState(() => _selectedIndex = _idxTitle),
            onSubmitted: () => _focusNextInput(_idxTitle),
          ),
          _MetadataFieldRow(
            key: _itemKey(_idxDeveloper),
            isSelected: _selectedIndex == _idxDeveloper,
            label: AppLocale.developer.getString(context),
            controller: _developerController,
            focusNode: _focusNodeFor(_idxDeveloper),
            readOnly: _activeFieldIndex != _idxDeveloper,
            onTap: () => setState(() => _selectedIndex = _idxDeveloper),
            onSubmitted: () => _focusNextInput(_idxDeveloper),
          ),
          _MetadataFieldRow(
            key: _itemKey(_idxPublisher),
            isSelected: _selectedIndex == _idxPublisher,
            label: AppLocale.publisher.getString(context),
            controller: _publisherController,
            focusNode: _focusNodeFor(_idxPublisher),
            readOnly: _activeFieldIndex != _idxPublisher,
            onTap: () => setState(() => _selectedIndex = _idxPublisher),
            onSubmitted: () => _focusNextInput(_idxPublisher),
          ),
          _MetadataFieldRow(
            key: _itemKey(_idxGenre),
            isSelected: _selectedIndex == _idxGenre,
            label: AppLocale.genre.getString(context),
            controller: _genreController,
            focusNode: _focusNodeFor(_idxGenre),
            readOnly: _activeFieldIndex != _idxGenre,
            onTap: () => setState(() => _selectedIndex = _idxGenre),
            onSubmitted: () => _focusNextInput(_idxGenre),
          ),
          for (int i = 0; i < _descLanguages.length; i++)
            _MetadataFieldRow(
              key: _itemKey(_idxDescStart + i),
              isSelected: _selectedIndex == _idxDescStart + i,
              label:
                  '${AppLocale.description.getString(context)} '
                  '(${_descLanguages[i].toUpperCase()})',
              controller: _descControllers[_descLanguages[i]]!,
              focusNode: _focusNodeFor(_idxDescStart + i),
              maxLines: 3,
              readOnly: _activeFieldIndex != _idxDescStart + i,
              onTap: () => setState(() => _selectedIndex = _idxDescStart + i),
            ),

          SizedBox(height: 8.r),
          _NavRow(
            key: _itemKey(_idxSave),
            isSelected: _selectedIndex == _idxSave,
            icon: Symbols.save_rounded,
            label: AppLocale.save.getString(context),
            subtitle: '',
            trailing: _isSaving
                ? SizedBox(
                    width: 16.r,
                    height: 16.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.secondary,
                    ),
                  )
                : null,
            onTap: () {
              SfxService().playNavSound();
              setState(() => _selectedIndex = _idxSave);
              _saveMetadata();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMediaTab(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.all(12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Symbols.image_rounded,
            label: AppLocale.systemArt.getString(context),
          ),
          for (int i = 0; i < _imageTypes.length; i++)
            _ArtworkRow(
              key: _itemKey(_idxImageStart + i),
              isSelected: _selectedIndex == _idxImageStart + i,
              label: _imageTypeLabel(context, _imageTypes[i]),
              imagePath: _pathForImageType(_imageTypes[i]),
              thumbsVersion: _thumbsVersion,
              onTap: () {
                SfxService().playNavSound();
                setState(() => _selectedIndex = _idxImageStart + i);
                _replaceImage(_imageTypes[i]);
              },
            ),
        ],
      ),
    );
  }

  String _imageTypeLabel(BuildContext context, String type) {
    switch (type) {
      case 'screenshots':
        return AppLocale.screenshot.getString(context);
      case 'wheels':
        return AppLocale.wheel.getString(context);
      case 'fanarts':
        return AppLocale.fanart.getString(context);
      case 'box2d':
        return AppLocale.boxart.getString(context);
      default:
        return type;
    }
  }
}

/// Selectable sub-tab item used inside the scrapping tab.
class _SubTabItem extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SubTabItem({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        onTap();
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 6.r),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondary.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.secondary.withValues(alpha: 0.5)
                : theme.colorScheme.outline.withValues(alpha: 0.1),
            width: 1.r,
          ),
        ),
        child: Text(
          label.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.r,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
            color: isSelected
                ? theme.colorScheme.secondary
                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
            letterSpacing: 0.5.r,
          ),
        ),
      ),
    );
  }
}

/// Small section header with icon, matching the settings-tab aesthetic.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 4.r, top: 8.r, bottom: 4.r),
      child: Row(
        children: [
          Icon(
            icon,
            size: 12.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 4.r),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Navigable action row (rescrape / save) with optional trailing widget.
class _NavRow extends StatelessWidget {
  final bool isSelected;
  final IconData icon;
  final String label;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _NavRow({
    super.key,
    required this.isSelected,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 4.r),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
        child: Row(
          children: [
            Container(
              width: 18.r,
              height: 18.r,
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.secondary.withValues(alpha: 0.2)
                    : theme.colorScheme.secondary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4.r),
              ),
              child: Icon(
                icon,
                color: isSelected
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.onSurface,
                size: 11.r,
              ),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected
                          ? theme.colorScheme.secondary
                          : theme.colorScheme.onSurface,
                      fontSize: 12.r,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                        fontSize: 10.r,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Compact metadata text field row; focusable via gamepad trigger.
class _MetadataFieldRow extends StatelessWidget {
  final bool isSelected;
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final int maxLines;
  final bool readOnly;
  final VoidCallback onTap;
  final VoidCallback? onSubmitted;

  const _MetadataFieldRow({
    super.key,
    required this.isSelected,
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.onTap,
    this.maxLines = 1,
    this.readOnly = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () {
        onTap();
        focusNode.requestFocus();
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 4.r),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: focusNode.hasFocus
                ? theme.colorScheme.secondary.withValues(alpha: 0.6)
                : theme.colorScheme.outline.withValues(alpha: 0.15),
            width: 1.r,
          ),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92.r,
              child: Padding(
                padding: EdgeInsets.only(top: 4.r),
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected
                        ? theme.colorScheme.secondary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    fontSize: 10.r,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Expanded(
              // Field-level key handling: while the field is focused the
              // global gamepad/keyboard layer stays out of the way, so Escape
              // (and Enter on single-line fields) is the way back out.
              child: readOnly
                  ? Padding(
                      padding: EdgeInsets.only(top: 4.r, bottom: 4.r),
                      child: Text(
                        controller.text.isEmpty ? '—' : controller.text,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 11.r,
                        ),
                        maxLines: maxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  : Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          focusNode.unfocus();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        maxLines: maxLines,
                        minLines: 1,
                        textInputAction: maxLines == 1
                            ? TextInputAction.next
                            : null,
                        onSubmitted: maxLines == 1
                            ? (_) => onSubmitted?.call()
                            : null,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 11.r,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 4.r),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Artwork row with a live thumbnail and a change action.
class _ArtworkRow extends StatelessWidget {
  final bool isSelected;
  final String label;
  final String imagePath;
  final int thumbsVersion;
  final VoidCallback onTap;

  const _ArtworkRow({
    super.key,
    required this.isSelected,
    required this.label,
    required this.imagePath,
    required this.thumbsVersion,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = File(imagePath);
    final exists = file.existsSync();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 4.r),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4.r),
              child: Container(
                width: 40.r,
                height: 40.r,
                color: theme.colorScheme.surfaceContainerHighest,
                child: exists
                    ? Image.file(
                        file,
                        key: ValueKey('thumb_${imagePath}_$thumbsVersion'),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Symbols.broken_image_rounded,
                          size: 16.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      )
                    : Icon(
                        Symbols.image_rounded,
                        size: 16.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.4,
                        ),
                      ),
              ),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.onSurface,
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4.r),
                border: Border.all(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.4),
                  width: 1.r,
                ),
              ),
              child: Text(
                AppLocale.change.getString(context),
                style: TextStyle(
                  fontSize: 11.r,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
