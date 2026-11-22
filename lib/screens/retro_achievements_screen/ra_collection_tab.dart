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
import '../../themes/corner_radii.dart';
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

  /// Whether the cursor is in the grid's first column, where Left leaves it.
  bool get atRowStart => _count == 0 || _selected % _columns == 0;

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

  /// The selected award, under the grid: its icon, the game, and what was
  /// earned (mastery, completion or beaten), in which mode, and when.
  Widget _awardDetails(BuildContext context, RaCabinetAward award) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final medal = award.hardcore ? RaEarnedBadge.gold : RaEarnedBadge.silver;
    final kind = _s(
      award.kind == 'mastered'
          ? AppLocale.raMasteryLabel
          : award.kind == 'completed'
          ? AppLocale.raCompletionLabel
          : AppLocale.raFilterBeaten,
    );
    final date = award.date?.toLocal().toString().split(' ').first;
    Widget pill(String text, {Color? color}) => Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 1.r),
      decoration: BoxDecoration(
        color: (color ?? scheme.onSurface).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (color ?? scheme.onSurface).withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8.r,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
    final icon = award.icon;
    return Container(
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: radii.radiusInternal,
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Container(
            width: 34.r,
            height: 34.r,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(color: medal, width: 2.r),
            ),
            clipBehavior: Clip.antiAlias,
            child: icon.isEmpty
                ? Icon(Icons.emoji_events_outlined, size: 22.r)
                : Image.network(
                    icon.startsWith('http')
                        ? icon
                        : 'https://media.retroachievements.org$icon',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Icon(Icons.emoji_events_outlined, size: 22.r),
                  ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  award.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                SizedBox(height: 3.r),
                Wrap(
                  spacing: 5.r,
                  runSpacing: 4.r,
                  children: [
                    pill(kind, color: medal),
                    pill(
                      _s(
                        award.hardcore
                            ? AppLocale.raHardcore
                            : AppLocale.raCasual,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            date ?? _s(AppLocale.unknown),
            style: TextStyle(
              fontSize: 8.r,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  /// The selected week, under the grid: its badge, the week and its
  /// achievement, the status as a pill, and the dates on the right.
  Widget _weekDetails(BuildContext context, RaEventWeek week, DateTime now) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final status = week.statusAt(now);
    final color = _statusColor(status);
    final badge = week.achievement?.badgeName ?? '';
    final upcoming = status == RaEventStatus.upcoming;
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    return Container(
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: radii.radiusInternal,
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Container(
            width: 34.r,
            height: 34.r,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(color: color, width: 2.r),
            ),
            clipBehavior: Clip.antiAlias,
            child: badge.isEmpty || upcoming
                ? Icon(
                    upcoming
                        ? Icons.question_mark
                        : Icons.emoji_events_outlined,
                    size: 18.r,
                  )
                : Image.network(
                    'https://media.retroachievements.org/Badge/$badge.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Icon(Icons.emoji_events_outlined, size: 18.r),
                  ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _weekFooterLabel(week, now),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                SizedBox(height: 3.r),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 1.r),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: color.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    _status(status),
                    style: TextStyle(
                      fontSize: 8.r,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            '${day(week.start)} – ${day(week.end.subtract(const Duration(seconds: 1)))}',
            style: TextStyle(
              fontSize: 8.r,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
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
            // One quiet line under the strip: the year so far, and the
            // weeks missed. The strip's colours carry the rest.
            Text(
              '${_s(AppLocale.raAchievementProgress).replaceFirst('{earned}', '$earned').replaceFirst('{total}', '${_weeks.length}')} · ${_s(AppLocale.raMissed)}: $missed',
              style: TextStyle(
                fontSize: 8.r,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
            SizedBox(height: 4.r),
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
                      // Awards show just their icons, smaller and closer;
                      // the selected one is named in the card below. Event
                      // weeks keep their date under the badge.
                      // Just the icons, like Games and Unlocks; the
                      // selected one is named in the card below.
                      final gap = 6.r;
                      const labelHeight = 0.0;
                      _columns = (constraints.maxWidth / 42.r).floor().clamp(
                        3,
                        18,
                      );
                      final tile =
                          (constraints.maxWidth - (_columns - 1) * gap) /
                          _columns;
                      _rowExtent = tile + labelHeight + gap;
                      return GridView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.symmetric(vertical: 8.r),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _columns,
                          mainAxisExtent: tile + labelHeight,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
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
                                padding: EdgeInsets.all(1.r),
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
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
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
                                    if (labelHeight > 0)
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
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(fontSize: 10.r),
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
              // No gap under it, so the card sits at the foot like the
              // Games and Unlocks ones.
              padding: EdgeInsets.only(top: 8.r),
              child: widget.events
                  ? _weekDetails(context, _weeks[_selected], now)
                  : _awardDetails(context, _awards[_selected]),
            ),
        ],
      ),
    );
  }
}
