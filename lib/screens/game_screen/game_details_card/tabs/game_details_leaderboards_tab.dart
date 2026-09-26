import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_leaderboard.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';

import '../widgets/panel_gate_highlight.dart';

typedef RaLoadGameLeaderboards =
    Future<RaGameLeaderboardsPage> Function(int gameId);
typedef RaLoadLeaderboardEntries =
    Future<RaLeaderboardEntriesPage> Function(
      int leaderboardId, {
      required int count,
      required int offset,
    });
typedef RaLoadUserGameLeaderboards =
    Future<RaUserGameLeaderboardsPage> Function(int gameId);

/// The per-game RetroAchievements leaderboard panel.
///
/// The card owns the outer tab and its navigation layer. This panel only owns
/// its internal list after A enters it, matching the achievements and game-info
/// panels: left/right continue to mean "change card tab" until then, and B
/// returns from entries to the leaderboard list before leaving the panel.
class GameDetailsLeaderboardsTab extends StatefulWidget {
  final int? gameId;
  final bool isConnected;
  final RaLoadGameLeaderboards loadGameLeaderboards;
  final RaLoadLeaderboardEntries loadLeaderboardEntries;
  final RaLoadUserGameLeaderboards loadUserGameLeaderboards;
  final double topOffset;
  final double bottomOffset;

  const GameDetailsLeaderboardsTab({
    super.key,
    required this.gameId,
    required this.isConnected,
    required this.loadGameLeaderboards,
    required this.loadLeaderboardEntries,
    required this.loadUserGameLeaderboards,
    this.topOffset = 55.0,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsLeaderboardsTab> createState() =>
      GameDetailsLeaderboardsTabState();
}

class GameDetailsLeaderboardsTabState
    extends State<GameDetailsLeaderboardsTab> {
  static const int _entryPageSize = 100;

  final ScrollController _scrollController = ScrollController();
  List<RaGameLeaderboard> _leaderboards = [];
  final Map<int, RaLeaderboardEntry> _ownEntries = {};
  List<RaLeaderboardEntry> _entries = [];

  bool _isLoading = true;
  bool _isLoadingEntries = false;
  bool _isPanelActive = false;
  bool _showEntries = false;
  bool _hasMoreEntries = false;
  String? _error;
  int _selectedIndex = 0;
  int _entriesOffset = 0;
  RaGameLeaderboard? _selectedLeaderboard;

  bool get isPanelActive => _isPanelActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadLeaderboards();
    });
  }

  @override
  void didUpdateWidget(GameDetailsLeaderboardsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gameId != widget.gameId ||
        oldWidget.isConnected != widget.isConnected) {
      _reset();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLeaderboards();
      });
    }
  }

  void _reset() {
    _leaderboards = [];
    _ownEntries.clear();
    _entries = [];
    _isLoading = true;
    _isLoadingEntries = false;
    _isPanelActive = false;
    _showEntries = false;
    _hasMoreEntries = false;
    _error = null;
    _selectedIndex = 0;
    _entriesOffset = 0;
    _selectedLeaderboard = null;
  }

  Future<void> _loadLeaderboards() async {
    if (!widget.isConnected || widget.gameId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final page = await widget.loadGameLeaderboards(widget.gameId!);
      RaUserGameLeaderboardsPage? userPage;
      try {
        userPage = await widget.loadUserGameLeaderboards(widget.gameId!);
      } catch (_) {
        // Public leaderboards remain useful when the optional own-entry call
        // fails. A cached public page should never be hidden behind it.
      }

      if (!mounted) return;
      setState(() {
        _leaderboards = page.results;
        _isLoading = false;
        if (userPage != null) {
          for (final item in userPage.results) {
            final entry = item.userEntry;
            if (entry != null) _ownEntries[item.id] = entry;
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _cleanError(error);
      });
    }
  }

  Future<void> _openLeaderboard(RaGameLeaderboard leaderboard) async {
    if (_isLoadingEntries) return;
    SfxService().playNavSound();
    setState(() {
      _selectedLeaderboard = leaderboard;
      _showEntries = true;
      _selectedIndex = 0;
      _entries = [];
      _entriesOffset = 0;
      _hasMoreEntries = true;
      _error = null;
    });
    await _loadEntriesPage(reset: true);
  }

  Future<void> _loadEntriesPage({required bool reset}) async {
    final leaderboard = _selectedLeaderboard;
    if (leaderboard == null || _isLoadingEntries) return;
    if (!reset && !_hasMoreEntries) return;

    final offset = reset ? 0 : _entriesOffset;
    setState(() => _isLoadingEntries = true);
    try {
      final page = await widget.loadLeaderboardEntries(
        leaderboard.id,
        count: _entryPageSize,
        offset: offset,
      );
      if (!mounted) return;
      setState(() {
        _entries = reset ? page.results : [..._entries, ...page.results];
        _entriesOffset = offset + page.results.length;
        _hasMoreEntries =
            page.results.isNotEmpty &&
            (_entriesOffset < page.total ||
                page.results.length == _entryPageSize);
        _isLoadingEntries = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingEntries = false;
        _error = _cleanError(error);
      });
    }
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Bad state: ', '');
  }

  /// Hands the D-pad to this panel. The empty and signed-out states are also
  /// enterable so A cannot accidentally launch the game while the user is
  /// reading why the list is unavailable.
  bool enterPanel() {
    if (_isPanelActive) return true;
    setState(() => _isPanelActive = true);
    return true;
  }

  /// B first returns from entries to the leaderboard list, then leaves the
  /// panel and returns control to the card's tab strip.
  bool exitPanel() {
    if (!_isPanelActive) return false;
    if (_showEntries) {
      setState(() {
        _showEntries = false;
        _selectedIndex = 0;
        _error = null;
      });
      _scrollController.jumpTo(0);
      return true;
    }
    setState(() => _isPanelActive = false);
    return true;
  }

  bool activateFocused() {
    if (!_isPanelActive) return false;
    if (_showEntries) return true;
    if (_leaderboards.isEmpty || _selectedIndex >= _leaderboards.length) {
      return true;
    }
    _openLeaderboard(_leaderboards[_selectedIndex]);
    return true;
  }

  void moveUp() {
    if (!_isPanelActive) return;
    if (_selectedIndex == 0) return;
    setState(() => _selectedIndex--);
    _scrollToSelected();
  }

  void moveDown() {
    if (!_isPanelActive) return;
    final itemCount = _showEntries
        ? _displayEntries.length
        : _leaderboards.length;
    if (itemCount == 0) return;
    if (_selectedIndex < itemCount - 1) {
      setState(() => _selectedIndex++);
      _scrollToSelected();
    }
    if (_showEntries && _selectedIndex >= itemCount - 3) {
      _loadEntriesPage(reset: false);
    }
  }

  void moveLeft() {}
  void moveRight() {}

  List<RaLeaderboardEntry> get _displayEntries {
    final own = _selectedLeaderboard == null
        ? null
        : _ownEntries[_selectedLeaderboard!.id];
    if (own == null) return _entries;

    final rows = <RaLeaderboardEntry>[own];
    rows.addAll(
      _entries.where(
        (entry) =>
            entry.ulid != own.ulid ||
            (entry.ulid.isEmpty && entry.rank != own.rank),
      ),
    );
    return rows;
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;
    final target = (_selectedIndex * 68.r).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    return Positioned(
      left: 12.r,
      right: 12.r,
      top: widget.topOffset.r,
      bottom: widget.bottomOffset.r,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (!_isPanelActive) {
            SfxService().playNavSound();
            enterPanel();
          }
        },
        child: AnimatedContainer(
          duration: PanelGateHighlight.duration,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: radii.radiusExternal,
            border: PanelGateHighlight.border(
              context,
              isDrivable: true,
              isActive: _isPanelActive,
              restingColor: Colors.transparent,
            ),
            boxShadow: PanelGateHighlight.shadows(
              context,
              isActive: _isPanelActive,
              resting: BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.r, 2.r),
              ),
            ),
          ),
          child: Column(
            children: [
              _buildHeader(context),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final leaderboard = _selectedLeaderboard;
    return Padding(
      padding: EdgeInsets.fromLTRB(12.r, 8.r, 12.r, 4.r),
      child: Row(
        children: [
          Icon(
            _showEntries
                ? Symbols.arrow_back_rounded
                : Symbols.leaderboard_rounded,
            size: 16.r,
            color: Theme.of(context).colorScheme.secondary,
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              _showEntries
                  ? (leaderboard?.title ??
                        AppLocale.raLeaderboardEntries.getString(context))
                  : AppLocale.raSubtabLeaderboards.getString(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 13.r,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (_showEntries && leaderboard != null)
            _directionChip(context, leaderboard),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!widget.isConnected) {
      return _message(
        context,
        Symbols.lock_rounded,
        AppLocale.raLeaderboardSignIn.getString(context),
      );
    }
    if (_showEntries) return _buildEntries(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_leaderboards.isEmpty) {
      return _message(
        context,
        _error == null
            ? Symbols.leaderboard_rounded
            : Symbols.error_outline_rounded,
        _error ?? AppLocale.raLeaderboardNoLeaderboards.getString(context),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(12.r, 4.r, 12.r, 10.r),
      itemCount: _leaderboards.length,
      itemBuilder: (context, index) =>
          _buildLeaderboardRow(context, _leaderboards[index], index),
    );
  }

  Widget _buildEntries(BuildContext context) {
    final rows = _displayEntries;
    if (_isLoadingEntries && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty && _error == null) {
      return _message(
        context,
        Symbols.format_list_numbered_rounded,
        AppLocale.raLeaderboardNoEntries.getString(context),
      );
    }
    if (rows.isEmpty && _error != null) {
      return _message(context, Symbols.error_outline_rounded, _error!);
    }

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(12.r, 4.r, 12.r, 10.r),
      itemCount: rows.length + (_isLoadingEntries ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Padding(
            padding: EdgeInsets.all(12.r),
            child: Center(
              child: Text(
                AppLocale.loading.getString(context),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11.r,
                ),
              ),
            ),
          );
        }
        final own = _selectedLeaderboard == null
            ? null
            : _ownEntries[_selectedLeaderboard!.id];
        final isOwn =
            own != null &&
            (rows[index].ulid.isNotEmpty
                ? rows[index].ulid == own.ulid
                : rows[index].rank == own.rank);
        return _buildEntryRow(context, rows[index], index, isOwn);
      },
    );
  }

  Widget _buildLeaderboardRow(
    BuildContext context,
    RaGameLeaderboard leaderboard,
    int index,
  ) {
    final theme = Theme.of(context);
    final focused = _isPanelActive && !_showEntries && _selectedIndex == index;
    final top = leaderboard.topEntry;
    return Padding(
      padding: EdgeInsets.only(bottom: 6.r),
      child: InkWell(
        onTap: () {
          setState(() => _selectedIndex = index);
          _openLeaderboard(leaderboard);
        },
        borderRadius: BorderRadius.circular(10.r),
        child: AnimatedContainer(
          duration: PanelGateHighlight.duration,
          padding: EdgeInsets.all(10.r),
          decoration: BoxDecoration(
            color: focused
                ? theme.colorScheme.primary.withValues(alpha: 0.16)
                : theme.colorScheme.surface.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(
              color: focused
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.outline.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      leaderboard.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 13.r,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _directionChip(context, leaderboard),
                ],
              ),
              if (leaderboard.description.isNotEmpty) ...[
                SizedBox(height: 4.r),
                Text(
                  leaderboard.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11.r,
                  ),
                ),
              ],
              SizedBox(height: 6.r),
              Row(
                children: [
                  Text(
                    AppLocale.raLeaderboardFormat
                        .getString(context)
                        .replaceFirst('{format}', leaderboard.format),
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10.r,
                    ),
                  ),
                  const Spacer(),
                  if (top != null)
                    Flexible(
                      child: Text(
                        AppLocale.raLeaderboardTopEntry
                            .getString(context)
                            .replaceFirst('{user}', top.user)
                            .replaceFirst(
                              '{score}',
                              _score(top.score, top.formattedScore),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: theme.colorScheme.secondary,
                          fontSize: 10.r,
                          fontWeight: FontWeight.w600,
                        ),
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

  Widget _buildEntryRow(
    BuildContext context,
    RaLeaderboardEntry entry,
    int index,
    bool isOwn,
  ) {
    final theme = Theme.of(context);
    final focused = _isPanelActive && _showEntries && _selectedIndex == index;
    return Padding(
      padding: EdgeInsets.only(bottom: 6.r),
      child: AnimatedContainer(
        duration: PanelGateHighlight.duration,
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isOwn
              ? theme.colorScheme.secondary.withValues(alpha: 0.18)
              : focused
              ? theme.colorScheme.primary.withValues(alpha: 0.16)
              : theme.colorScheme.surface.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: isOwn || focused
                ? theme.colorScheme.secondary
                : theme.colorScheme.outline.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 38.r,
              child: Text(
                '#${entry.rank}',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12.r,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.user,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 12.r,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isOwn)
                    Text(
                      AppLocale.raLeaderboardYourEntry.getString(context),
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontSize: 9.r,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: 8.r),
            Text(
              _score(entry.score, entry.formattedScore),
              style: TextStyle(
                color: theme.colorScheme.secondary,
                fontSize: 12.r,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _directionChip(BuildContext context, RaGameLeaderboard leaderboard) {
    final ascending = leaderboard.rankAsc;
    return Semantics(
      label:
          (ascending
                  ? AppLocale.raLeaderboardRankAscending
                  : AppLocale.raLeaderboardRankDescending)
              .getString(context),
      child: Icon(
        ascending
            ? Symbols.arrow_upward_rounded
            : Symbols.arrow_downward_rounded,
        size: 14.r,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _message(BuildContext context, IconData icon, String message) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(20.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 36.r,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            SizedBox(height: 12.r),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13.r,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _score(int score, String formattedScore) {
    return formattedScore.trim().isEmpty ? score.toString() : formattedScore;
  }
}
