import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_locale.dart';
import '../../models/ra_cabinet.dart';
import '../../models/ra_event_calendar.dart';
import '../../models/retro_achievements_dashboard_models.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../widgets/ra_earned_badge.dart';
import '../../utils/custom_scroll_behavior.dart';

/// Collection content used by the dedicated Events and Awards destinations.
class RaCollectionTab extends StatefulWidget {
  final bool events, active, focused;
  final void Function(int id, String title) onOpenGame;

  /// Retained for callers that embed the collection in another surface.
  final VoidCallback? onBack;
  const RaCollectionTab({
    super.key,
    required this.events,
    required this.active,
    required this.focused,
    required this.onOpenGame,
    this.onBack,
  });
  @override
  State<RaCollectionTab> createState() => RaCollectionTabState();
}

class RaCollectionTabState extends State<RaCollectionTab> {
  final _scroll = ScrollController();
  RetroAchievementsProvider? _provider;
  List<RaCabinetAward> _awards = [];
  List<RaEventWeek> _weeks = [];
  bool _loading = false, _failed = false, _loaded = false;
  int _selected = 0,
      _columns = 6,
      _generation = -1,
      _session = -1,
      _request = 0;
  double _rowExtent = 100;
  Timer? _clock;
  int get _count => widget.events ? _weeks.length : _awards.length;
  String _s(String key) => key.getString(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<RetroAchievementsProvider>();
    if (_provider != provider) {
      _provider?.removeListener(_changed);
      _provider = provider;
      provider.addListener(_changed);
    }
    _schedule();
  }

  void _changed() {
    if (_session != _provider!.sessionGeneration) {
      _request++;
      _loading = false;
      _loaded = false;
      _weeks = [];
      _awards = [];
      _selected = 0;
    }
    _schedule();
  }

  void _schedule() {
    if (!widget.active || _loading) return;
    if (_loaded &&
        _generation == _provider!.cacheGeneration &&
        _session == _provider!.sessionGeneration) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && !_loading) unawaited(refresh());
    });
  }

  @override
  void didUpdateWidget(RaCollectionTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && widget.active && widget.events) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _request++;
    _provider?.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (_loading) return;
    final provider = _provider!;
    final request = ++_request;
    _session = provider.sessionGeneration;
    _generation = provider.cacheGeneration;
    setState(() {
      _loading = true;
      _failed = false;
      _loaded = true;
    });
    try {
      if (widget.events) {
        final now = DateTime.now().toUtc();
        // The opening days in January can still belong to the prior event year.
        Map<String, dynamic> catalogue;
        try {
          catalogue = await provider.getEventCatalogue(now.year);
        } catch (_) {
          catalogue = await provider.getEventCatalogue(now.year - 1);
          final last = (catalogue['weeks'] as List).last;
          if (!now.isBefore(DateTime.parse(last['end'] as String))) rethrow;
        }
        final schedule = catalogue['weeks'] as List;
        if (schedule.isNotEmpty &&
            now.isBefore(DateTime.parse(schedule.first['start'] as String))) {
          try {
            catalogue = await provider.getEventCatalogue(now.year - 1);
          } catch (_) {
            /* Keep the known upcoming calendar. */
          }
        }
        final weeks = catalogue['weeks'] as List;
        if (mounted && request == _request) {
          setState(() => _weeks = RaEventWeek.build(weeks, null));
        }
        final progress = await provider.getAnnualEventProgress(
          catalogue['year'] as int,
        );
        if (!mounted || request != _request) return;
        _weeks = RaEventWeek.build(weeks, progress);
        _failed = progress == null;
        if (!provider.gotwLoaded) await provider.fetchGOTW();
      } else {
        // The completion-progress endpoint includes hidden games, while the
        // public awards endpoint supplies the best icons and titles. Keep the
        // cabinet useful when either endpoint is temporarily unavailable.
        var progress = <RetroAchievementCompletionProgressItem>[];
        Object? progressError;
        try {
          progress = await provider.getAwardProgress();
        } catch (error) {
          progressError = error;
        }
        Object? awardsError;
        if (!provider.userAwardsLoaded) {
          try {
            await provider.fetchUserAwards();
          } catch (error) {
            awardsError = error;
          }
        }
        if (!mounted || request != _request) return;
        _awards = RaCabinetAward.merge(
          progress.where((a) => a.consoleId != 101).toList(),
          provider.userAwards?.visibleUserAwards ?? [],
        );
        _failed =
            _awards.isEmpty &&
            (progressError != null ||
                awardsError != null ||
                provider.userAwardsError != null);
      }
    } catch (_) {
      if (mounted && request == _request) _failed = true;
    }
    if (mounted && request == _request) {
      setState(() {
        _loading = false;
        _selected = _selected.clamp(0, (_count - 1).clamp(0, 1 << 30));
      });
    }
  }

  bool move(int dx, int dy) {
    if (_count == 0) return false;
    // The grid is the only focusable surface in this tab. Returning false at
    // Its top edge lets a parent surface decide what receives focus next.
    if (dy < 0 && _selected < _columns) return false;
    final next = (_selected + dx + dy * _columns).clamp(
      0,
      (_count - 1).clamp(0, 1 << 30),
    );
    setState(() => _selected = next);
    if (_scroll.hasClients) {
      final top = (_selected ~/ _columns) * _rowExtent;
      final p = _scroll.position;
      final target = top < p.pixels
          ? top
          : top + _rowExtent > p.pixels + p.viewportDimension
          ? top + _rowExtent - p.viewportDimension
          : p.pixels;
      _scroll.animateTo(
        target.clamp(0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    }
    return true;
  }

  void selectCurrent() => _open();

  void _open() {
    if (_count == 0) return;
    if (!widget.events) {
      final a = _awards[_selected];
      widget.onOpenGame(a.gameId, a.title);
      return;
    }
    final week = _weeks[_selected];
    final current = _provider!.gotw;
    if (current != null && current.startDateUtc == week.start) {
      widget.onOpenGame(current.game.id, current.game.title);
      return;
    }
    final id = week.achievement?.id;
    if (id == null) return;
    unawaited(
      launchUrl(Uri.parse('https://retroachievements.org/achievement/$id')),
    );
  }

  String _status(RaEventStatus status) => _s(switch (status) {
    RaEventStatus.upcoming => AppLocale.raUpcoming,
    RaEventStatus.current => AppLocale.raCurrent,
    RaEventStatus.missed => AppLocale.raMissed,
    RaEventStatus.casual => AppLocale.raCasual,
    RaEventStatus.hardcore => AppLocale.raHardcore,
    RaEventStatus.unknown => AppLocale.unknown,
  });
  Color _statusColor(RaEventStatus status) => switch (status) {
    RaEventStatus.casual => RaEarnedBadge.silver,
    RaEventStatus.hardcore => RaEarnedBadge.gold,
    RaEventStatus.missed => Theme.of(context).colorScheme.error,
    RaEventStatus.current => Theme.of(context).colorScheme.primary,
    _ => Theme.of(context).dividerColor,
  };
  String _weekLabel(RaEventWeek week) =>
      _s(AppLocale.raWeek).replaceFirst('{week}', '${week.week}');

  String _weekFooterLabel(RaEventWeek week, DateTime now) {
    final weekLabel = _weekLabel(week);
    final title = week.achievement?.title.trim();
    if (title == null || title.isEmpty) {
      return '$weekLabel: ${_status(week.statusAt(now))}';
    }

    // Some event sets already include the week prefix in the achievement
    // title. Keep the useful game name while normalizing the separator.
    final weekPrefix = RegExp(
      '^Week\\s+${week.week}\\s*[:\\-]\\s*',
      caseSensitive: false,
    );
    if (weekPrefix.hasMatch(title)) {
      return title.replaceFirst(weekPrefix, '$weekLabel: ');
    }

    // The live AOTW payload carries the game separately. Use it when the
    // annual achievement title only contains the achievement name.
    final current = _provider?.gotw;
    final currentStart = current?.startDateUtc;
    final gameTitle =
        current != null &&
            currentStart != null &&
            currentStart.isAtSameMomentAs(week.start)
        ? current.game.title.trim()
        : '';
    if (gameTitle.isNotEmpty &&
        !title.toLowerCase().contains(gameTitle.toLowerCase())) {
      return '$weekLabel: $gameTitle - $title';
    }
    return '$weekLabel: $title';
  }

  String _awardLabel(RaCabinetAward a) =>
      '${_s(a.kind == 'mastered'
          ? AppLocale.raMasteryLabel
          : a.kind == 'completed'
          ? AppLocale.raCompletionLabel
          : AppLocale.raFilterBeaten)} · ${_s(a.hardcore ? AppLocale.raHardcore : AppLocale.raCasual)}';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final current = _provider?.gotw;
    final earned = _weeks
        .where(
          (week) =>
              week.statusAt(now) == RaEventStatus.casual ||
              week.statusAt(now) == RaEventStatus.hardcore,
        )
        .length;
    final missed = _weeks
        .where((week) => week.statusAt(now) == RaEventStatus.missed)
        .length;
    return ScrollConfiguration(
      behavior: CustomScrollBehavior(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.events && current != null)
            Text(
              '${_s(AppLocale.raAotw)}: ${current.achievement.title} · ${current.game.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_failed)
            Text(
              _s(
                widget.events
                    ? AppLocale.raEventUnavailable
                    : AppLocale.raErrorAwardsUnavailable,
              ),
            ),
          if (widget.events && _weeks.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: 6.r),
              child: Row(
                children: [
                  for (final week in _weeks)
                    Expanded(
                      child: Tooltip(
                        message:
                            '${_weekLabel(week)}: ${_status(week.statusAt(now))}',
                        child: Container(
                          height: 8.r,
                          margin: const EdgeInsets.symmetric(horizontal: .5),
                          color: _statusColor(week.statusAt(now)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              '${_s(AppLocale.raAchievementProgress).replaceFirst('{earned}', '$earned').replaceFirst('{total}', '${_weeks.length}')} · ${_s(AppLocale.raMissed)}: $missed',
              textAlign: TextAlign.left,
            ),
            Wrap(
              spacing: 12.r,
              children: [
                for (final status in RaEventStatus.values)
                  Text(
                    '${_status(status)}: ${_weeks.where((w) => w.statusAt(now) == status).length}',
                  ),
              ],
            ),
          ],
          Expanded(
            child: _count == 0
                ? Center(
                    child: Text(
                      _s(
                        _loading
                            ? AppLocale.progress
                            : widget.events
                            ? AppLocale.raEventUnavailable
                            : AppLocale.noAwardsYet,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      _columns = (constraints.maxWidth / 92.r).floor().clamp(
                        3,
                        14,
                      );
                      final tile =
                          (constraints.maxWidth - (_columns - 1) * 8.r) /
                          _columns;
                      _rowExtent = tile + 28.r + 8.r;
                      return GridView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.symmetric(vertical: 8.r),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _columns,
                          mainAxisExtent: tile + 28.r,
                          crossAxisSpacing: 8.r,
                          mainAxisSpacing: 8.r,
                        ),
                        itemCount: _count,
                        itemBuilder: (context, index) {
                          final week = widget.events ? _weeks[index] : null;
                          final award = widget.events ? null : _awards[index];
                          final status = week?.statusAt(now);
                          final upcoming = status == RaEventStatus.upcoming;
                          final badge = week?.achievement?.badgeName ?? '';
                          final icon =
                              award?.icon ??
                              (badge.isEmpty || upcoming
                                  ? ''
                                  : '/Badge/$badge.png');
                          final label = week != null
                              ? _weekLabel(week)
                              : award!.title;
                          final earned =
                              award != null ||
                              status == RaEventStatus.casual ||
                              status == RaEventStatus.hardcore;
                          return Semantics(
                            label:
                                '$label · ${week != null ? _status(status!) : _awardLabel(award!)}',
                            selected: index == _selected,
                            button: true,
                            child: InkWell(
                              onTap: () => setState(() {
                                _selected = index;
                              }),
                              onDoubleTap: () {
                                setState(() => _selected = index);
                                _open();
                              },
                              child: Padding(
                                padding: EdgeInsets.all(4.r),
                                child: Column(
                                  children: [
                                    AspectRatio(
                                      aspectRatio: 1,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            width:
                                                index == _selected &&
                                                    widget.focused
                                                ? 3.r
                                                : 2.r,
                                            color:
                                                index == _selected &&
                                                    widget.focused
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : earned
                                                ? (award?.hardcore == true ||
                                                          status ==
                                                              RaEventStatus
                                                                  .hardcore
                                                      ? RaEarnedBadge.gold
                                                      : RaEarnedBadge.silver)
                                                : _statusColor(status!),
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6.r,
                                          ),
                                        ),
                                        child: Center(
                                          child: icon.isEmpty
                                              ? Icon(
                                                  upcoming
                                                      ? Icons.question_mark
                                                      : Icons
                                                            .emoji_events_outlined,
                                                  size: 30.r,
                                                )
                                              : Image.network(
                                                  icon.startsWith('http')
                                                      ? icon
                                                      : 'https://media.retroachievements.org$icon',
                                                  fit: BoxFit.contain,
                                                  errorBuilder: (_, _, _) =>
                                                      const Icon(
                                                        Icons
                                                            .emoji_events_outlined,
                                                      ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (status == RaEventStatus.missed)
                                          Icon(Icons.close, size: 12.r),
                                        Expanded(
                                          child: Text(
                                            label,
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelSmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
          if (_count > 0)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 8.r),
              child: widget.events
                  ? Text(
                      '${_weekFooterLabel(_weeks[_selected], now)}\n${_weeks[_selected].start.toIso8601String().substring(0, 10)} – ${_weeks[_selected].end.subtract(const Duration(seconds: 1)).toIso8601String().substring(0, 10)} · ${_status(_weeks[_selected].statusAt(now))}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Text(
                      '${_awards[_selected].title}\n${_awardLabel(_awards[_selected])} · ${_awards[_selected].date?.toLocal().toString().split(' ').first ?? _s(AppLocale.unknown)}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
        ],
      ),
    );
  }
}
