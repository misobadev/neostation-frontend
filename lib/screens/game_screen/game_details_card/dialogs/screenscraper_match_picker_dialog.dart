import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/screenscraper_game_candidate.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// What the user chose in [ScreenScraperMatchPickerDialog].
class ScreenScraperMatchChoice {
  /// The game picked, or null when the user chose automatic matching.
  final ScreenScraperGameCandidate? game;

  const ScreenScraperMatchChoice.game(ScreenScraperGameCandidate this.game);

  const ScreenScraperMatchChoice.automatic() : game = null;

  bool get isAutomatic => game == null;
}

/// Lets the user identify a game by hand on ScreenScraper (Identify…).
///
/// Matching by dump hash or filename cannot reach every ROM: hacks,
/// translations, regional names and untidy filenames match the wrong game or
/// none at all. This searches ScreenScraper by name within the game's own
/// system so the user can point the ROM at the right game. Applying the choice
/// is left to the caller, which already shows scrape progress.
///
/// Every search spends a request of the user's daily ScreenScraper quota, so
/// it runs once on open and then only when the user asks (A / Enter), never
/// as they type.
///
/// Pops a [ScreenScraperMatchChoice], or null when cancelled.
class ScreenScraperMatchPickerDialog extends StatefulWidget {
  final GameModel game;

  /// The game's own app system id (not an aggregate view's).
  final String appSystemId;

  /// The game the user identified this ROM as before, if any.
  final int? currentGameId;

  /// Runs a search; tests substitute their own. Defaults to
  /// [ScreenScraperService.searchGames].
  @visibleForTesting
  final Future<ScreenScraperSearchResult> Function(String query)? search;

  const ScreenScraperMatchPickerDialog({
    super.key,
    required this.game,
    required this.appSystemId,
    this.currentGameId,
    this.search,
  });

  static Future<ScreenScraperMatchChoice?> show(
    BuildContext context, {
    required GameModel game,
    required String appSystemId,
    int? currentGameId,
  }) {
    return showDialog<ScreenScraperMatchChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScreenScraperMatchPickerDialog(
        game: game,
        appSystemId: appSystemId,
        currentGameId: currentGameId,
      ),
    );
  }

  /// Best first guess at the game's name: the ROM filename with the
  /// extension, region tags and dump markers stripped.
  ///
  /// Not the displayed title: for a game that was matched wrongly, that is the
  /// wrong game's name. Android app entries are the exception — their
  /// "filename" is the package name (it doubles as the path), so the app's
  /// own name is the better guess.
  @visibleForTesting
  static String initialQuery(GameModel game) {
    final isApp = game.romPath == game.romname;
    final raw = (isApp || game.romname.isEmpty) ? game.name : game.romname;
    return raw
        .replaceAll(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '')
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
        .trim();
  }

  @override
  State<ScreenScraperMatchPickerDialog> createState() =>
      _ScreenScraperMatchPickerDialogState();
}

class _ScreenScraperMatchPickerDialogState
    extends State<ScreenScraperMatchPickerDialog> {
  static const String _layerId = 'screenscraper_match_picker_dialog';

  late final GamepadNavigation _gamepadNav;
  final TextEditingController _queryController = TextEditingController();
  // Focused only on purpose (A on the field, or a tap). Gamepad navigation
  // owns the cursor; if Flutter's arrow-key traversal could land here, the
  // next Enter would be taken as typing instead of picking the row.
  final FocusNode _queryFocus = FocusNode(skipTraversal: true);
  final ScrollController _scrollController = ScrollController();

  List<ScreenScraperGameCandidate> _results = [];
  ScreenScraperSearchFailure? _failure;
  bool _isSearching = false;
  bool _hasSearched = false;
  bool _isFieldFocused = false;
  int _selectedIndex = 0;

  /// Set once a choice has been made, so the dialog pops exactly once.
  bool _closing = false;

  /// The query whose results are on screen. A/Enter in the field and the
  /// keyboard's submit action can both fire for one press; a repeat of a query
  /// already answered is skipped so it doesn't spend a second request.
  String? _shownQuery;

  /// Index of the "use automatic matching" row, or null when it is not shown.
  int? get _resetIndex =>
      widget.currentGameId != null ? _results.length + 1 : null;

  int get _itemCount => _results.length + (_resetIndex != null ? 2 : 1);

  @override
  void initState() {
    super.initState();

    _queryController.text = ScreenScraperMatchPickerDialog.initialQuery(
      widget.game,
    );
    _queryFocus.addListener(() {
      if (!mounted) return;
      setState(() => _isFieldFocused = _queryFocus.hasFocus);
    });

    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onSelectItem: _activateSelection,
      onBack: _handleBack,
      isTextFieldFocused: () => _queryFocus.hasFocus,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });

    _search(_queryController.text);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _queryController.dispose();
    _queryFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (_isSearching || trimmed.isEmpty || trimmed == _shownQuery) return;

    setState(() {
      _isSearching = true;
      _failure = null;
    });
    final search = widget.search;
    final result = search != null
        ? await search(trimmed)
        : await ScreenScraperService.searchGames(
            appSystemId: widget.appSystemId,
            query: trimmed,
          );
    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _hasSearched = true;
      _results = result.games;
      _failure = result.failure;
      // A failed search can be retried with the same text.
      _shownQuery = result.failure == null ? trimmed : null;
      _selectedIndex = _results.isNotEmpty ? 1 : 0;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  // ── Gamepad ───────────────────────────────────────────────────────────────

  void _moveUp() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex == 0) return;
    setState(() => _selectedIndex--);
    _scrollToSelection();
  }

  void _moveDown() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex >= _itemCount - 1) return;
    setState(() => _selectedIndex++);
    _scrollToSelection();
  }

  void _activateSelection() {
    if (_queryFocus.hasFocus) {
      // Enter/A while typing runs the search and returns to list navigation.
      _queryFocus.unfocus();
      _search(_queryController.text);
      return;
    }

    if (_selectedIndex == 0) {
      _queryFocus.requestFocus();
      return;
    }

    if (_selectedIndex == _resetIndex) {
      _choose(const ScreenScraperMatchChoice.automatic());
      return;
    }

    final game = _results.elementAtOrNull(_selectedIndex - 1);
    if (game != null) _choose(ScreenScraperMatchChoice.game(game));
  }

  /// B leaves the text field first, and only closes the dialog once the field
  /// is no longer focused — the app-wide way out of text entry.
  void _handleBack() {
    if (_queryFocus.hasFocus) {
      _queryFocus.unfocus();
      return;
    }
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _scrollToSelection() {
    if (!_scrollController.hasClients) return;
    // Rows are a fixed height, so the offset can be computed directly rather
    // than measured.
    final target = ((_selectedIndex - 1) * 44.r).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  void _choose(ScreenScraperMatchChoice choice) {
    // A second pop would close whatever is underneath (Game Settings, the
    // games list), so only the first choice counts.
    if (_closing || !mounted) return;
    _closing = true;
    SfxService().playNavSound();
    Navigator.of(context).pop(choice);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    return Dialog(
      backgroundColor: theme.cardColor,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Container(
        width: size.width * 0.6,
        constraints: BoxConstraints(maxHeight: size.height * 0.7),
        padding: EdgeInsets.all(12.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitle(theme),
            SizedBox(height: 10.r),
            _buildSearchField(theme),
            SizedBox(height: 8.r),
            Flexible(child: _buildResults(theme)),
            if (_resetIndex != null) ...[
              SizedBox(height: 6.r),
              _buildResetRow(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Row(
      children: [
        Icon(
          Symbols.manage_search_rounded,
          color: theme.colorScheme.primary,
          size: 18.r,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            AppLocale.raFixMatchTitle.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 13.r,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          'ScreenScraper',
          style: TextStyle(
            fontSize: 10.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final selected = _selectedIndex == 0;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: selected || _isFieldFocused
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
          width: selected || _isFieldFocused ? 2.r : 1.r,
        ),
      ),
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Row(
        children: [
          Icon(
            Symbols.search_rounded,
            size: 14.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: TextField(
              controller: _queryController,
              focusNode: _queryFocus,
              textInputAction: TextInputAction.search,
              // The on-screen keyboard's search key. On desktop, Enter also
              // reaches [_activateSelection]; [_search] skips the repeat.
              onSubmitted: _search,
              onTap: () => setState(() => _selectedIndex = 0),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10.r),
                hintText: AppLocale.identifySearchHint.getString(context),
                hintStyle: TextStyle(
                  fontSize: 12.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          if (_isSearching)
            SizedBox(
              width: 12.r,
              height: 12.r,
              child: CircularProgressIndicator(strokeWidth: 1.5.r),
            ),
        ],
      ),
    );
  }

  /// The message shown in place of the list, or null when there is a list.
  String? _statusMessage() {
    switch (_failure) {
      case ScreenScraperSearchFailure.noCredentials:
        return AppLocale.scrapeNoCredentials.getString(context);
      case ScreenScraperSearchFailure.systemNotMapped:
        return AppLocale.scrapeSystemNotMapped.getString(context);
      case ScreenScraperSearchFailure.quotaExceeded:
        return AppLocale.scrapeQuotaExceeded.getString(context);
      case ScreenScraperSearchFailure.failed:
        return AppLocale.identifySearchFailed.getString(context);
      case null:
        break;
    }
    if (_hasSearched && _results.isEmpty) {
      return AppLocale.raFixMatchNoResults.getString(context);
    }
    return null;
  }

  Widget _buildResults(ThemeData theme) {
    final message = _isSearching ? null : _statusMessage();
    if (_results.isEmpty || message != null) {
      // Nothing to list yet: a spinner while the first search runs, the
      // reason when there is one, otherwise just the field above.
      if (!_isSearching && message == null) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20.r),
        child: Center(
          child: message == null
              ? SizedBox(
                  width: 16.r,
                  height: 16.r,
                  child: CircularProgressIndicator(strokeWidth: 2.r),
                )
              : Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final game = _results[i];
        return _ScreenScraperMatchRow(
          game: game,
          selected: _selectedIndex == i + 1,
          isCurrent: game.id == widget.currentGameId,
          onTap: () {
            setState(() => _selectedIndex = i + 1);
            _choose(ScreenScraperMatchChoice.game(game));
          },
        );
      },
    );
  }

  Widget _buildResetRow(ThemeData theme) {
    final selected = _selectedIndex == _resetIndex;
    return InkWell(
      // Not focusable: see [_ScreenScraperMatchRow].
      canRequestFocus: false,
      onTap: () => _choose(const ScreenScraperMatchChoice.automatic()),
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 8.r),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Symbols.restart_alt_rounded,
              size: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            SizedBox(width: 6.r),
            Text(
              AppLocale.raFixMatchUseAutomatic.getString(context),
              style: TextStyle(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One game from a ScreenScraper search: its name, then year · publisher ·
/// system underneath.
class _ScreenScraperMatchRow extends StatelessWidget {
  final ScreenScraperGameCandidate game;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;

  const _ScreenScraperMatchRow({
    required this.game,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [
      game.year,
      game.publisher,
      game.systemName,
    ].whereType<String>().join(' · ');

    return InkWell(
      // The dialog's gamepad navigation owns the selection. A focusable row
      // would also pick up Flutter's own arrow-key focus and answer the same
      // Enter press a second time.
      canRequestFocus: false,
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: 44.r,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            if (isCurrent) ...[
              Icon(
                Symbols.check_circle_rounded,
                size: 14.r,
                color: theme.colorScheme.primary,
              ),
              SizedBox(width: 6.r),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.r,
                      color: theme.colorScheme.onSurface,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
