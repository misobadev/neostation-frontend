import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/utils/collection_sort.dart';
import 'package:neostation/services/collections/collections_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/widgets/systems_grid_footer.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';

import '../game_screen/my_games_list.dart';
import '../systems_screen/my_systems_section/my_systems_carousel.dart';
import '../systems_screen/my_systems_section/my_systems_grid.dart';
import 'collection_cards.dart';
import 'collection_name_dialog.dart';
import 'smart_collection_editor.dart';

/// Second level of the collections navigation: the user's collections as cards,
/// with a trailing "New collection" card.
///
/// Reached from the Collections virtual system on the systems grid/carousel.
/// Activating a collection pushes the ordinary [SystemGamesList] with a
/// synthesized `collection:<uuid>` [SystemModel] — the same trick the "All
/// Games" card uses — so no second games UI exists.
///
/// The cards themselves are laid out, navigated and drawn by the systems
/// screen's own [SystemCardGridView] and [MySystemsCarousel]: this screen owns
/// the selection index and the actions, and hands both widgets a
/// `List<SystemInfo>` built from the collections. Nothing about the browsing
/// behaviour is reimplemented here, so it cannot drift from the systems screen
/// — the two are the same widgets with different data and different A/Y/Start
/// handlers. Everything those widgets do that belongs to *systems* (rescan on
/// pull, the secondary-display push, the app-wide dynamic background, theme
/// artwork, tab bumpers) is switched off through their constructors.
class CollectionsBrowserScreen extends StatefulWidget {
  const CollectionsBrowserScreen({super.key});

  @override
  State<CollectionsBrowserScreen> createState() =>
      _CollectionsBrowserScreenState();
}

/// Context-menu result ids. Local to this screen; the menu widget itself is
/// domain-agnostic.
const String _menuEditRules = 'edit_rules';
const String _menuRename = 'rename';
const String _menuChangeImage = 'change_image';
const String _menuRemoveImage = 'remove_image';
const String _menuDelete = 'delete';
const String _menuViewMode = 'view_mode';

class _CollectionsBrowserScreenState extends State<CollectionsBrowserScreen> {
  static final _log = LoggerService.instance;

  /// Per-instance gamepad layer ids, handed to whichever systems view is on
  /// screen. [GamepadNavigationManager.popLayer] resolves an id to the *first*
  /// matching entry, so a shared constant would let a second copy of this route
  /// unregister the first one's layer and strand its own — a dead layer that
  /// swallows input, and the shape of the bug that had the Android apps grid
  /// launching several apps per press. The grid and the carousel get separate
  /// ids because switching view mode disposes one and mounts the other.
  static int _instanceSeq = 0;
  late final int _instance = ++_instanceSeq;
  late final String _gridLayerId = 'collections_browser_grid#$_instance';
  late final String _carouselLayerId =
      'collections_browser_carousel#$_instance';

  /// Anchor for the per-collection menu: the selected card itself.
  ///
  /// The menu used to hang off the footer's Y button, which sits in the
  /// bottom-right corner — so `besideAnchor` found no room on the right,
  /// left-flipped, and landed the panel over the footer's own B/X controls and
  /// nowhere near the card it acts on. Anchoring to the card matches what the
  /// games views do (D11) and keeps the menu next to the thing it changes.
  final GlobalKey _selectedCardAnchorKey = GlobalKey(
    debugLabel: 'selectedCollectionCardAnchor',
  );

  int _selectedIndex = 0;
  bool _canPop = false;
  bool _isNavigatingBack = false;

  /// True while a dialog/picker owns the interaction, so a queued button press
  /// cannot start a second one.
  bool _isBusy = false;

  /// Cover files previewed on each collection card that has no artwork of its
  /// own, keyed by [_previewKey].
  ///
  /// Screen-owned rather than provider-owned on purpose: resolving it costs a
  /// query plus a `stat` per game, and only this screen draws it. Putting it in
  /// [CollectionsProvider._refresh] would pay that cost on every membership
  /// toggle from the games screen's Y menu, which never shows a mosaic.
  final Map<String, List<String>> _previewCache = {};

  /// Keys whose resolution is in flight, so a rebuild cannot start it twice.
  final Set<String> _previewsInFlight = {};

  /// Games scanned per collection when picking covers.
  ///
  /// Each candidate costs two `existsSync` calls, so a 900-game collection is
  /// not worth walking to find a fourth cover; the first [_kPreviewScanLimit]
  /// of a stable shuffle are plenty.
  static const int _kPreviewScanLimit = 40;

  /// Covers drawn on one card.
  static const int _kPreviewCovers = 4;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<CollectionsProvider>();
      provider.load();
    });
  }

  // ── Model ──────────────────────────────────────────────────────────────────

  List<CollectionModel> get _collections {
    final config = context.read<SqliteConfigProvider>().config;
    return _ordered(
      context.read<CollectionsProvider>().collections,
      config.collectionSortBy,
      config.collectionSortOrder,
    );
  }

  /// Applies the browser's own sort preference.
  ///
  /// Delegates to [sortCollections] so the ordering is testable on its own;
  /// every read of the list goes through here because [_selectedIndex] is a
  /// position in it, and a build that ordered differently from [_collections]
  /// would put the cursor on the wrong collection.
  List<CollectionModel> _ordered(
    List<CollectionModel> collections,
    String sortBy,
    String sortOrder,
  ) => sortCollections(collections, sortBy, sortOrder);

  /// Whether the cursor sits on the "New collection" card.
  bool get _onCreateCard => _selectedIndex >= _collections.length;

  /// The selected collection, or null when the create card is selected.
  CollectionModel? get _selectedCollection =>
      _onCreateCard ? null : _collections[_selectedIndex];

  // ── Navigation ─────────────────────────────────────────────────────────────

  /// Selection moves are owned by the systems grid/carousel — this is only the
  /// index they report back, exactly as the systems screen keeps it.
  void _onCardSelected(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  void _goBack() {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;

    setState(() => _canPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _activateSelection() async {
    if (_isBusy) return;
    final collection = _selectedCollection;
    if (collection == null) {
      await _createCollection();
      return;
    }
    await _openCollection(collection);
  }

  /// Pushes the ordinary games list for [collection].
  ///
  /// The [SystemModel] is synthesized exactly as `_createAllGamesSystem` does
  /// for "All Games": nothing about it is persisted, and
  /// `GameListService.loadGamesForSystem` recognises the `collection:<uuid>`
  /// folder name and loads the membership.
  Future<void> _openCollection(CollectionModel collection) async {
    if (collection.rulesInvalid) {
      _notify(
        AppLocale.smartInvalidRules.getString(context),
        NotificationType.error,
      );
      await _editRules(collection);
      return;
    }
    final fileProvider = context.read<FileProvider>();
    final target = SystemGamesList(
      system: _createCollectionSystem(collection),
      fileProvider: fileProvider,
    );

    // Held for the whole push: a bounced A press would otherwise stack a second
    // copy of the games list on top of the first.
    _isBusy = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => target),
      );
    } finally {
      _isBusy = false;
    }

    if (!mounted) return;
    // Membership (and therefore the counts) can change inside the games list.
    await context.read<CollectionsProvider>().load();
  }

  SystemModel _createCollectionSystem(CollectionModel collection) {
    final folderName = '${SystemFolderNames.collectionPrefix}${collection.id}';
    return SystemModel(
      id: folderName,
      folderName: folderName,
      realName: collection.name,
      iconImage: '/images/icons/folder-bulk.png',
      color: collection.color1 ?? kCollectionFallbackColor,
      customBackgroundPath: collection.imagePath,
      hideLogo: false,
      imageVersion: context.read<CollectionsProvider>().imageVersion,
      romCount: collection.gameCount,
      detected: true,
    );
  }

  /// Opens the per-collection menu (Y / Start).
  Future<void> _openContextMenu() async {
    if (_isBusy) return;
    final collection = _selectedCollection;
    if (collection == null) return;

    SfxService().playNavSound();

    final items = <ContextMenuItem>[
      if (collection.isSmart)
        ContextMenuItem(
          id: _menuEditRules,
          label: AppLocale.smartEditRules.getString(context),
          icon: Symbols.auto_awesome_rounded,
        ),
      ContextMenuItem(
        id: _menuRename,
        label: AppLocale.renameCollection.getString(context),
        icon: Symbols.edit_rounded,
      ),
      ContextMenuItem(
        id: _menuChangeImage,
        label: AppLocale.changeImage.getString(context),
        icon: Symbols.image_rounded,
      ),
      if (collection.imagePath != null)
        ContextMenuItem(
          id: _menuRemoveImage,
          label: AppLocale.removeImage.getString(context),
          icon: Symbols.hide_image_rounded,
        ),
      ContextMenuItem(
        id: _menuDelete,
        label: AppLocale.deleteCollection.getString(context),
        icon: Symbols.delete_rounded,
        separatorBefore: true,
      ),
      // View-level action, below the hairline that marks where the menu stops
      // acting on this one collection — the same split the games views' menu
      // uses. It is here because the header that used to carry the View Mode
      // pill is gone, and X is a pad-only route: without this row a touch user
      // could not change the view at all. Mirrors what the rail removal did to
      // the games views, which moved the same control into the same menu.
      ContextMenuItem(
        id: _menuViewMode,
        label: AppLocale.viewMode.getString(context),
        icon: Symbols.grid_view_rounded,
        separatorBefore: true,
      ),
    ];

    final result = await showAnchoredContextMenu(
      context: context,
      items: items,
      // Keep the menu next to the collection it acts on; without a mounted
      // card, the menu falls back to the viewport centre.
      anchorKey: _selectedCardAnchorKey,
      alignment: ContextMenuAlignment.overAnchor,
      layerId: 'collection_context_menu',
      submenuLayerId: 'collection_context_submenu',
    );

    if (!mounted || result == null) return;

    switch (result) {
      case _menuEditRules:
        await _editRules(collection);
      case _menuRename:
        await _renameCollection(collection);
      case _menuChangeImage:
        await _changeImage(collection);
      case _menuRemoveImage:
        await _removeImage(collection);
      case _menuDelete:
        await _deleteCollection(collection);
      case _menuViewMode:
        await _openViewMenu();
    }
  }

  /// Opens the view picker (X).
  ///
  /// The systems screen's own picker, reached through [showSystemViewDropdown]
  /// rather than through a reduced copy: view mode and card size are the same
  /// two persisted settings this screen reads, so the same menu has to write
  /// them. `includeSorting: false` suppresses just the sort/order rows —
  /// release year and manufacturer describe hardware and say nothing about a
  /// collection — instead of forking the widget.
  Future<void> _openViewMenu() async {
    if (_isBusy) return;
    SfxService().playNavSound();
    await showSystemViewDropdown(
      context,
      // The systems picker's own sort rows describe hardware — release year,
      // manufacturer — and say nothing about a collection. These are the rows
      // that do.
      includeSorting: false,
      includeCollectionSorting: true,
      // The cards preview their games, so the box-art/fanart switch belongs
      // here — it changes what is on screen.
      includeCardStyle: true,
    );
    // The provider notifies; `build` watches `systemViewMode` /
    // `systemGridColumns` and relays out. [_selectedIndex] is screen state and
    // is untouched, so the cursor stays on the same collection across a switch.
  }

  /// Creates a collection, prompting for its name with the next unused
  /// generated name pre-filled.
  Future<void> _createCollection() async {
    final type = await showAnchoredContextMenu(
      context: context,
      items: [
        ContextMenuItem(
          id: 'manual',
          label: AppLocale.manualCollection.getString(context),
          icon: Symbols.bookmark_rounded,
        ),
        ContextMenuItem(
          id: 'smart',
          label: AppLocale.smartCollection.getString(context),
          icon: Symbols.auto_awesome_rounded,
        ),
      ],
      layerId: 'collection_type#$_instance',
      submenuLayerId: 'collection_type_submenu#$_instance',
      alignment: ContextMenuAlignment.centerScreen,
    );
    if (type == null || !mounted) return;
    final provider = context.read<CollectionsProvider>();
    final template = AppLocale.newCollectionDefaultName.getString(context);
    final existing = provider.collections.map((c) => c.name).toSet();

    var index = provider.collections.length + 1;
    var suggestion = template.replaceFirst('{number}', '$index');
    while (existing.contains(suggestion)) {
      index++;
      suggestion = template.replaceFirst('{number}', '$index');
    }

    final smartDraft = type == 'smart'
        ? await SmartCollectionEditor.show(context, initialName: suggestion)
        : null;
    if (!mounted || (type == 'smart' && smartDraft == null)) return;
    final name =
        smartDraft?.name ??
        await _prompt(
          title: AppLocale.createCollection.getString(context),
          initialValue: suggestion,
          confirmLabel: AppLocale.save.getString(context),
        );
    if (name == null || !mounted) return;

    try {
      final created = await provider.create(name, rules: smartDraft?.rules);
      if (!mounted) return;
      // Land the cursor on what was just made.
      final position = provider.collections.indexWhere(
        (c) => c.id == created.id,
      );
      setState(() => _selectedIndex = position >= 0 ? position : 0);
      _notify(
        AppLocale.collectionCreated
            .getString(context)
            .replaceFirst('{name}', created.name),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection creation failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _editRules(CollectionModel collection) async {
    final draft = await SmartCollectionEditor.show(
      context,
      collection: collection,
      initialName: collection.name,
    );
    if (draft == null || !mounted) return;
    try {
      final provider = context.read<CollectionsProvider>();
      await provider.updateRules(collection.id, draft.rules);
      if (draft.name != collection.name) {
        await provider.rename(collection.id, draft.name);
      }
      if (mounted) setState(() => _previewCache.clear());
    } catch (e) {
      _log.e('Updating smart collection failed: $e');
      if (mounted) _reportSaveError();
    }
  }

  Future<void> _renameCollection(CollectionModel collection) async {
    final name = await _prompt(
      title: AppLocale.renameCollection.getString(context),
      initialValue: collection.name,
      confirmLabel: AppLocale.save.getString(context),
    );
    if (name == null || !mounted || name == collection.name) return;

    try {
      await context.read<CollectionsProvider>().rename(collection.id, name);
    } catch (e) {
      _log.e('Collection rename failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _deleteCollection(CollectionModel collection) async {
    if (_isBusy) return;
    _isBusy = true;
    bool confirmed;
    try {
      confirmed = await ConfirmActionDialog.show(
        context,
        title: AppLocale.deleteCollection.getString(context),
        body: AppLocale.deleteCollectionConfirm
            .getString(context)
            .replaceFirst('{name}', collection.name),
        confirmLabel: AppLocale.delete.getString(context),
        icon: Symbols.delete_rounded,
      );
    } finally {
      _isBusy = false;
    }
    if (!confirmed || !mounted) return;

    try {
      await context.read<CollectionsProvider>().delete(collection.id);
      if (!mounted) return;
      setState(() {
        // Collections plus the trailing create card.
        _selectedIndex = _selectedIndex.clamp(0, _collections.length);
      });
      _notify(
        AppLocale.collectionDeleted
            .getString(context)
            .replaceFirst('{name}', collection.name),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection delete failed: $e');
      _reportSaveError();
    }
  }

  /// Replaces a collection's artwork.
  ///
  /// [CollectionsService.setCollectionImage] does the copy into
  /// `<userData>/media/collections/` and evicts the image caches; the provider
  /// bumps `imageVersion`, which is what actually forces the card to repaint —
  /// the file path is unchanged, so no `ValueKey` would otherwise differ.
  Future<void> _changeImage(CollectionModel collection) async {
    if (_isBusy) return;
    _isBusy = true;
    String? pickedPath;
    try {
      pickedPath = await _pickImageFile();
    } catch (e) {
      _log.e('Collection image picker failed: $e');
    } finally {
      _isBusy = false;
    }
    if (pickedPath == null || !mounted) return;

    try {
      final saved = await context.read<CollectionsProvider>().setImage(
        collection.id,
        pickedPath,
      );
      if (!mounted) return;
      if (saved == null) {
        _reportSaveError();
        return;
      }
      _notify(
        AppLocale.imageUpdatedSuccess.getString(context),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection image update failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _removeImage(CollectionModel collection) async {
    try {
      await context.read<CollectionsProvider>().clearImage(collection.id);
      if (!mounted) return;
      _notify(
        AppLocale.imageResetDefault.getString(context),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection image removal failed: $e');
      _reportSaveError();
    }
  }

  /// Picks an image file, using the in-app browser on Android TV.
  ///
  /// The TV branch is not optional: Google TV devices have no system file
  /// picker activity for the plugin to hand off to, so `pickFiles` returns
  /// nothing there and the action would silently do nothing.
  Future<String?> _pickImageFile() async {
    final dialogTitle = AppLocale.changeImage.getString(context);

    if (Platform.isAndroid && await PermissionService.isTelevision()) {
      if (!mounted) return null;
      return TvDirectoryPicker.showFilePicker(
        context,
        extensions: CollectionsService.supportedImageExtensions,
      );
    }

    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: CollectionsService.supportedImageExtensions,
      dialogTitle: dialogTitle,
      windowsOptions: const WindowsOptions(lockParentWindow: true),
      linuxOptions: const LinuxOptions(lockParentWindow: true),
    );
    return result?.path;
  }

  /// Shows the name prompt, holding the busy flag so a bounced press cannot
  /// stack two dialogs.
  Future<String?> _prompt({
    required String title,
    required String initialValue,
    required String confirmLabel,
  }) async {
    if (_isBusy) return null;
    _isBusy = true;
    try {
      return await CollectionNameDialog.show(
        context,
        title: title,
        initialValue: initialValue,
        confirmLabel: confirmLabel,
      );
    } finally {
      _isBusy = false;
    }
  }

  void _notify(String message, NotificationType type) {
    if (!mounted) return;
    AppNotification.showNotification(context, message, type: type);
  }

  void _reportSaveError() {
    _notify(
      AppLocale.errorSavingCollection.getString(context),
      NotificationType.error,
    );
  }

  // ── Card previews ──────────────────────────────────────────────────────────

  /// Identifies one resolved preview.
  ///
  /// [CollectionModel.gameCount] is part of the key so adding or removing a
  /// game re-resolves the mosaic, and the image type is too, so flipping the
  /// card style between box art and fanart repaints rather than showing the
  /// other style's covers.
  String _previewKey(CollectionModel collection, String imageType) =>
      '${collection.id}|$imageType|${collection.gameCount}|${collection.rules?.encode()}';

  /// The mosaic covers for [collection], resolving them in the background the
  /// first time they are asked for.
  ///
  /// Returns empty until the resolution lands, so the card falls back to its
  /// tint for a frame rather than blocking the build on disk I/O.
  ///
  /// Resolved **even when the collection has its own artwork**, which looks
  /// wasteful and is not. `SystemCard` paints chosen artwork through
  /// `Image.file`, whose `errorBuilder` falls back to the mosaic — so the
  /// mosaic is exactly what a card needs when its artwork file has gone
  /// missing or will not decode. Short-circuiting here left that fallback with
  /// nothing to draw, and the card painted a flat tint: a blank card, no
  /// explanation, and "Remove artwork" the only way back, because clearing the
  /// path is what let this method compute again. Observed on the Thor with a
  /// collection whose file was gone from `media/collections/`.
  ///
  /// Costs one background resolve per collection, cached by
  /// [_previewKey]. It cannot change a card that *has* working artwork:
  /// `SystemCard` gives a custom background precedence over the mosaic, so a
  /// non-empty list here is only ever reached down the error path.
  List<String> _previewFor(CollectionModel collection, String imageType) {
    final key = _previewKey(collection, imageType);
    final cached = _previewCache[key];
    if (cached != null) return cached;
    if (collectionWantsMosaic(collection)) {
      unawaited(_resolvePreview(collection, imageType, key));
    }
    return const [];
  }

  /// Picks up to [_kPreviewCovers] on-disk covers from [collection]'s games.
  ///
  /// The games are shuffled with a seed derived from the collection id, the
  /// same way the subfolder preview cards sample a folder: stable for a given
  /// collection, but different between two collections holding the same
  /// series, so a shelf of them does not show four identical box arts.
  Future<void> _resolvePreview(
    CollectionModel collection,
    String imageType,
    String key,
  ) async {
    if (!_previewsInFlight.add(key)) return;
    try {
      final games = await CollectionsService.loadGamesForCollection(
        collection.id,
      );
      if (!mounted) return;
      final fileProvider = context.read<FileProvider>();
      final candidates = games.toList()
        ..shuffle(Random(collection.id.hashCode));
      final covers = <String>[];
      for (final game in candidates.take(_kPreviewScanLimit)) {
        final folder = game.systemFolderName;
        if (folder == null || folder.isEmpty) continue;
        final art = game.getImagePath(folder, imageType, fileProvider);
        if (File(art).existsSync()) {
          covers.add(art);
        } else {
          final shot = game.getScreenshotPath(folder, fileProvider);
          if (File(shot).existsSync()) covers.add(shot);
        }
        if (covers.length >= _kPreviewCovers) break;
      }
      if (!mounted) return;
      setState(() => _previewCache[key] = covers);
    } catch (e) {
      _log.e('Collection preview resolution failed: $e');
    } finally {
      _previewsInFlight.remove(key);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<CollectionsProvider>();

    // Selected, not read: the browser has to repaint when the sort preference
    // changes, and `_ordered` alone would not register the dependency.
    final collectionSortBy = context.select<SqliteConfigProvider, String>(
      (p) => p.config.collectionSortBy,
    );
    final collectionSortOrder = context.select<SqliteConfigProvider, String>(
      (p) => p.config.collectionSortOrder,
    );
    final collections = _ordered(
      provider.collections,
      collectionSortBy,
      collectionSortOrder,
    );

    // A delete (or a change made by the other engine) can shorten the list
    // under the cursor.
    if (_selectedIndex > collections.length) {
      _selectedIndex = collections.length;
    }

    // Collections are a screen full of system-style cards, so they honour the
    // systems screen's own layout preferences rather than introducing a second
    // set: switching either screen's view mode switches both.
    final viewMode = context.select<SqliteConfigProvider, String>(
      (p) => p.config.systemViewMode,
    );
    final cols = Responsive.getSystemsCrossAxisCountFromSize(
      context.select<SqliteConfigProvider, String>(
        (p) => p.config.systemGridColumns,
      ),
    );

    // The mosaic on an artless card follows the same box-art/fanart choice the
    // games views use for their own cards, so a collection previews its games
    // in the style the user picked to see games in.
    final imageType =
        context.select<SqliteConfigProvider, String>(
              (p) => p.config.gameCarouselCardStyle,
            ) ==
            'fanart'
        ? 'fanarts'
        : 'box2d';

    final showSpinner = provider.isLoading && !provider.hasLoaded;
    final items = _buildCards(collections, provider.imageVersion, imageType);

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        // No header at all. It floated over the cards so they kept the full
        // height, which made it cheap to keep — but it only ever held the View
        // Mode pill and the collection count, and the screen says both without
        // it: the cards are self-evidently collections, and counting them is
        // not worth a permanent line of chrome. The Stack went with it, since
        // the header was the only thing over the cards.
        body: Column(
          children: [
            if (!showSpinner && collections.isEmpty) _buildEmptyHint(theme),
            Expanded(
              child: showSpinner
                  ? const Center(child: CircularProgressIndicator())
                  : viewMode == 'carousel'
                  ? _buildCarousel(items)
                  : _buildGrid(items, cols),
            ),
            if (!showSpinner)
              SafeArea(
                top: false,
                child: SystemsGridFooter(
                  system: items[_selectedIndex],
                  onEnter: _activateSelection,
                  onOptions: _openContextMenu,
                  enterLabel: AppLocale.hintSelect.getString(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The card list the systems widgets lay out: one entry per collection, plus
  /// the trailing "New collection" entry.
  List<SystemInfo> _buildCards(
    List<CollectionModel> collections,
    int imageVersion,
    String imageType,
  ) {
    return [
      for (final collection in collections)
        collectionToSystemInfo(
          collection,
          imageVersion: imageVersion,
          mosaicPaths: _previewFor(collection, imageType),
        ),
      newCollectionCardInfo(AppLocale.createCollection.getString(context)),
    ];
  }

  /// Renders the one entry that is not a collection.
  ///
  /// Returning null for every other index leaves those cards to the systems
  /// widgets' own `SystemCard`, so a collection card and a system card are
  /// literally the same widget with the same artwork, focus and tap handling.
  Widget? _buildCardOverride(
    BuildContext context,
    int index,
    SystemInfo info,
    bool isSelected,
    VoidCallback onTap,
  ) {
    if (info.folderName != kNewCollectionCardFolder) return null;
    return NewCollectionCard(
      key: const ValueKey('collection_card_new'),
      label: info.title ?? '',
      isSelected: isSelected,
      onTap: onTap,
    );
  }

  /// The systems carousel, driven by collections.
  Widget _buildCarousel(List<SystemInfo> items) {
    return Padding(
      // No top padding: the header no longer occupies a row to be spaced from.
      padding: EdgeInsets.zero,
      child: MySystemsCarousel(
        items: items,
        selectedIndex: _selectedIndex,
        // Keep counts visible on the cards as well as in the selected footer.
        showCardCounts: true,
        // "New collection" is an action, not a place, so it is left out of the
        // strip of collections you can jump to.
        showChipFor: (info) => info.folderName != kNewCollectionCardFolder,
        selectedItemKey: _selectedCardAnchorKey,
        onCardTapped: _onCardSelected,
        onActivate: (index) {
          _selectedIndex = index;
          _activateSelection();
        },
        onOptions: (index) {
          _selectedIndex = index;
          _openContextMenu();
        },
        onYPressed: _openContextMenu,
        onBackPressed: _goBack,
        onXPressed: _openViewMenu,
        navLayerId: _carouselLayerId,
        cardOverrideBuilder: _buildCardOverride,
        // This screen owns B, so the carousel must not swallow the platform
        // back gesture on the way to it.
        blockSystemBack: false,
        // Everything below belongs to systems, not collections: rescanning ROM
        // folders, repainting the screen underneath, resolving theme artwork
        // for folder names that have none, telling a second display which
        // *system* is selected, and cycling the top-level tabs from a pushed
        // route.
        enablePullToRescan: false,
        enableDynamicBackground: false,
        enableThemeAssets: false,
        enableSecondaryDisplay: false,
        enableTabBumpers: false,
      ),
    );
  }

  /// The systems grid, driven by collections.
  ///
  /// Pinch-to-resize is deliberately left on: it writes the same
  /// `config.systemGridColumns` this screen reads, which is exactly the setting
  /// the X picker offers here, so the gesture stays consistent with the cards
  /// on screen.
  Widget _buildGrid(List<SystemInfo> items, int cols) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 6.0.r, vertical: 4.0.r),
      child: SystemCardGridView(
        crossAxisCount: cols,
        childAspectRatio: _kCardAspectRatio,
        systems: items,
        selectedIndex: _selectedIndex,
        selectedItemKey: _selectedCardAnchorKey,
        onCardTapped: _onCardSelected,
        onEnterPressed: _activateSelection,
        // Start, matching the systems screen where Start opens the card's
        // settings; Y does the same thing here.
        onEscapePressed: _openContextMenu,
        onYPressed: _openContextMenu,
        onBackPressed: _goBack,
        onXPressed: _openViewMenu,
        navLayerId: _gridLayerId,
        cardOverrideBuilder: _buildCardOverride,
        enablePullToRescan: false,
        enableThemeAssets: false,
        enableSecondaryDisplay: false,
        enableTabBumpers: false,
      ),
    );
  }

  /// Shown above the grid when there is nothing but the create card, so the
  /// screen explains itself without ever hiding the one thing that is usable.
  Widget _buildEmptyHint(ThemeData theme) {
    return Padding(
      // Top inset stands in for the header it used to sit below, so the hint
      // is not flush against the screen edge.
      padding: EdgeInsets.only(left: 16.r, right: 16.r, top: 16.r, bottom: 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.noCollections.getString(context),
            style: TextStyle(
              fontSize: 13.r,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          SizedBox(height: 2.r),
          Text(
            AppLocale.noCollectionsSubtitle.getString(context),
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Card aspect ratio, matching the systems grid so the two look identical.
const double _kCardAspectRatio = 0.80;
