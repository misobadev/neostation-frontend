import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_locale.dart';
import '../../models/retro_achievements_game_info.dart';
import '../../models/retro_achievement_comment.dart';
import '../../models/ra_achievement_query.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../widgets/ra_earned_badge.dart';
import '../../utils/custom_scroll_behavior.dart';

class RaAchievementBrowser extends StatefulWidget {
  final GameInfoAndUserProgress info;
  final int? highlightId;
  final VoidCallback? onLeaderboards;
  final VoidCallback? onFilterChanged;

  const RaAchievementBrowser({
    super.key,
    required this.info,
    this.highlightId,
    this.onLeaderboards,
    this.onFilterChanged,
  });
  @override
  State<RaAchievementBrowser> createState() => RaAchievementBrowserState();
}

class RaAchievementBrowserState extends State<RaAchievementBrowser> {
  final RaAchievementQuery _query = RaAchievementQuery();
  final _list = ScrollController();
  final _detail = ScrollController();
  final _controlKeys = List.generate(4, (_) => GlobalKey());
  static const _controlCount = 4;
  int _selected = 0;
  int _control = -1;
  bool _details = false;
  bool _comments = false;
  bool _loading = false;
  bool _failed = false;
  int _offset = 0, _total = 0, _request = 0;
  List<RetroAchievementComment> _thread = [];
  List<Achievement> get _items => _query.apply(widget.info);
  Achievement? get _current =>
      _items.isEmpty ? null : _items[_selected.clamp(0, _items.length - 1)];
  double get _extent =>
      86.r * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);

  @override
  void initState() {
    super.initState();
    _selected = _items.indexWhere((a) => a.id == widget.highlightId);
    if (_selected < 0) _selected = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal();
    });
  }

  @override
  void dispose() {
    _request++;
    _list.dispose();
    _detail.dispose();
    super.dispose();
  }

  void _reveal() {
    if (!_list.hasClients) return;
    final top = _selected * _extent;
    final bottom = top + _extent;
    final p = _list.position;
    final target = top < p.pixels
        ? top
        : bottom > p.pixels + p.viewportDimension
        ? bottom - p.viewportDimension
        : p.pixels;
    _list.animateTo(
      target.clamp(0, p.maxScrollExtent),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  void _change(VoidCallback update) {
    final id = _current?.id;
    setState(() {
      update();
      final index = _items.indexWhere((a) => a.id == id);
      _selected = index < 0 ? 0 : index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal();
    });
  }

  /// False at the top hands navigation to the game's hero actions.
  bool move(int dx, int dy) {
    if (_details) {
      if (_detail.hasClients && dy != 0) {
        _detail.animateTo(
          (_detail.offset + dy * 100.r).clamp(
            0,
            _detail.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
      return true;
    }
    if (_control >= 0) {
      if (dy < 0) return false;
      if (dy > 0) {
        setState(() => _control = -1);
        _reveal();
        return true;
      }
      setState(
        () => _control = (_control + dx + _controlCount) % _controlCount,
      );
      final ctx = _controlKeys[_control].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 120),
        );
      }
      return true;
    }
    // The control row is a horizontal navigation strip. Enter it from the
    // current achievement wherever the list cursor is, so the user never has
    // to return to the first row before reaching All/Locked/Missables/AOTW
    // leaderboards.
    if (dx != 0) {
      setState(() => _control = dx > 0 ? 0 : _controlCount - 1);
      final ctx = _controlKeys[_control].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 120),
        );
      }
      return true;
    }
    if (dy < 0 && (_selected == 0 || _items.isEmpty)) {
      setState(() => _control = 0);
      return true;
    }
    if (_items.isNotEmpty && dy != 0) {
      setState(() => _selected = (_selected + dy).clamp(0, _items.length - 1));
      _reveal();
    }
    return true;
  }

  bool back() {
    if (_comments) {
      setState(() => _comments = false);
      return true;
    }
    if (_details) {
      setState(() => _details = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal();
      });
      return true;
    }
    if (_control >= 0) {
      setState(() => _control = -1);
      return true;
    }
    return false;
  }

  void selectCurrent() {
    if (_details) {
      if (!_comments) {
        setState(() => _comments = true);
        if (_thread.isEmpty) unawaited(_loadComments());
      } else if (_failed || _offset < _total) {
        unawaited(_loadComments());
      }
      return;
    }
    if (_control >= 0) {
      _activateControl(_control);
      return;
    }
    if (_current != null) _open(_selected);
  }

  void enterFilters() => setState(() => _control = 0);
  void _open(int index) {
    _request++;
    setState(() {
      _selected = index;
      _details = true;
      _comments = false;
      _thread = [];
      _offset = 0;
      _total = 0;
      _failed = false;
      _loading = false;
      _control = -1;
    });
  }

  void _activateControl(int index) {
    if (index == 3) {
      setState(() => _control = -1);
      widget.onLeaderboards?.call();
      return;
    }
    _change(() {
      switch (index) {
        case 0:
          _query
            ..hardcore = false
            ..status = RaUnlockFilter.all
            ..type = null;
        case 1:
          _query
            ..hardcore = false
            ..status = RaUnlockFilter.locked
            ..type = null;
        case 2:
          _query
            ..hardcore = false
            ..status = RaUnlockFilter.locked
            ..type = 'missable';
      }
    });
    widget.onFilterChanged?.call();
  }

  Future<void> _loadComments() async {
    if (_loading || _current == null) return;
    final provider = context.read<RetroAchievementsProvider>();
    final account = provider.sessionGeneration;
    final request = ++_request;
    final id = _current!.id;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await provider.getAchievementComments(id, offset: _offset);
      if (!mounted ||
          request != _request ||
          account != provider.sessionGeneration) {
        return;
      }
      setState(() {
        _thread = {
          for (final c in [..._thread, ...page.results]) c.cacheKey: c,
        }.values.toList();
        _offset += page.count;
        _total = page.count < 25 ? _offset : page.total;
        _loading = false;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  String _s(String key) => key.getString(context);
  bool _filterSelected(int index) => switch (index) {
    0 => _query.status == RaUnlockFilter.all && _query.type == null,
    1 => _query.status == RaUnlockFilter.locked && _query.type == null,
    2 => _query.status == RaUnlockFilter.locked && _query.type == 'missable',
    _ => false,
  };

  ButtonStyle _filterStyle(BuildContext context, int index) {
    final theme = Theme.of(context);
    final selected = _filterSelected(index);
    final focused = _control == index;
    final accent = theme.colorScheme.primary;
    return OutlinedButton.styleFrom(
      foregroundColor: selected || focused
          ? (selected ? theme.colorScheme.onPrimary : accent)
          : accent,
      backgroundColor: selected
          ? accent
          : accent.withValues(
              alpha: focused
                  ? theme.brightness == Brightness.dark
                        ? .32
                        : .16
                  : theme.brightness == Brightness.dark
                  ? .18
                  : .08,
            ),
      side: BorderSide(
        width: _control == index ? 2.5 : 1,
        color: selected ? accent : accent.withValues(alpha: .72),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
    );
  }

  Widget _badge(Achievement a) => RaEarnedBadge(
    casual: a.isUnlocked,
    hardcore: (a.dateEarnedHardcore ?? '').isNotEmpty,
    child: SizedBox(
      width: 42.r,
      height: 42.r,
      child: a.badgeName.isEmpty
          ? const Icon(Icons.emoji_events_outlined)
          : Image.network(
              'https://media.retroachievements.org/Badge/${a.badgeName}${a.isUnlocked ? '' : '_lock'}.png',
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.emoji_events_outlined),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: CustomScrollBehavior(),
    child: Column(
      children: [
        if (!_details)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.all(6.r),
            child: Row(
              children: [
                for (int i = 0; i < _controlCount; i++)
                  Padding(
                    key: _controlKeys[i],
                    padding: EdgeInsets.only(left: 6.r),
                    child: OutlinedButton(
                      style: _filterStyle(context, i),
                      onPressed: () => _activateControl(i),
                      child: Text(
                        _s(switch (i) {
                          0 => AppLocale.filterAll,
                          1 => AppLocale.raFilterLocked,
                          2 => AppLocale.raFilterMissables,
                          _ => AppLocale.raSubtabLeaderboards,
                        }),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (!_details)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              child: Text(
                '${_items.length} / ${widget.info.achievements.length} ${_s(AppLocale.achievements)}',
              ),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final list = _items.isEmpty
                  ? Center(child: Text(_s(AppLocale.raNoAchievementsForFilter)))
                  : ListView.builder(
                      key: const PageStorageKey('ra-achievement-list'),
                      controller: _list,
                      physics: const ClampingScrollPhysics(),
                      itemExtent: _extent,
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final a = _items[index];
                        return Semantics(
                          selected: index == _selected,
                          child: InkWell(
                            onTap: () => _open(index),
                            child: Container(
                              padding: EdgeInsets.all(8.r),
                              margin: EdgeInsets.symmetric(
                                horizontal: 8.r,
                                vertical: 2.r,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8.r),
                                border: Border.all(
                                  color: index == _selected && _control < 0
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  _badge(a),
                                  SizedBox(width: 10.r),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          a.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                        Flexible(
                                          child: Text(
                                            a.description,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(width: 8.r),
                                  Text('${a.points} ${_s(AppLocale.points)}'),
                                  Icon(
                                    a.isUnlocked
                                        ? Icons.lock_open
                                        : Icons.lock_outline,
                                    size: 18.r,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
              if (!_details || _current == null) return list;
              final details = _buildDetails(_current!);
              return constraints.maxWidth >= 1000
                  ? Row(
                      children: [
                        Expanded(child: list),
                        SizedBox(
                          width: constraints.maxWidth * .4,
                          child: details,
                        ),
                      ],
                    )
                  : details;
            },
          ),
        ),
      ],
    ),
  );

  Widget _buildDetails(Achievement a) {
    final total = _query.hardcore
        ? widget.info.numDistinctPlayersHardcore
        : widget.info.numDistinctPlayersCasual;
    final awarded = _query.hardcore ? a.numAwardedHardcore : a.numAwarded;
    final metadataColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: back,
              icon: const Icon(Icons.arrow_back),
              label: Text(_s(AppLocale.back)),
            ),
            const Spacer(),
            if (!_comments)
              TextButton.icon(
                onPressed: selectCurrent,
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 18.r,
                      height: 18.r,
                      color: Theme.of(context).colorScheme.primary,
                      colorBlendMode: BlendMode.srcIn,
                    ),
                    SizedBox(width: 4.r),
                    const Icon(Icons.comment_outlined),
                  ],
                ),
                label: Text(_s(AppLocale.raComments)),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _detail,
            padding: EdgeInsets.all(12.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _badge(a),
                    SizedBox(width: 12.r),
                    Expanded(
                      child: Text(
                        a.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12.r),
                Text(a.description),
                SizedBox(height: 12.r),
                Text(
                  '${a.points} ${_s(AppLocale.points)}${total > 0 ? ' · ${(100 * awarded / total).toStringAsFixed(1)}%' : ''}',
                ),
                if ((a.dateEarned ?? '').isNotEmpty)
                  Text('${_s(AppLocale.raCasual)}: ${a.dateEarned}'),
                if ((a.dateEarnedHardcore ?? '').isNotEmpty)
                  Text('${_s(AppLocale.raHardcore)}: ${a.dateEarnedHardcore}'),
                if (a.isMissable) Text(_s(AppLocale.raMissable)),
                if (_comments) ...[
                  const Divider(),
                  Text(
                    _s(AppLocale.raComments),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final comment in _thread)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 10.r),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${comment.user} · ${comment.submitted?.toLocal().toString().split('.').first ?? ''}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: metadataColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(comment.commentText),
                        ],
                      ),
                    ),
                  if (!_loading && !_failed && _thread.isEmpty)
                    Text(_s(AppLocale.raNoCommentsYet)),
                  if (_failed) Text(_s(AppLocale.raCommentsCouldNotLoad)),
                  if (_loading) const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        if (_comments && !_loading && (_failed || _offset < _total))
          TextButton(
            onPressed: _loadComments,
            child: Text(_s(_failed ? AppLocale.retry : AppLocale.raLoadMore)),
          ),
      ],
    );
  }
}
