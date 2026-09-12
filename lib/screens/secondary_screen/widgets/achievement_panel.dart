import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../l10n/app_locale.dart';
import '../../../models/secondary_achievement_item.dart';
import '../../../models/secondary_display_state.dart';

/// The subset of a game's achievements visible on the secondary display.
enum AchievementFilter { all, locked, missables }

/// Returns the achievements represented by [filter].
///
/// Missables deliberately excludes earned achievements: once it has been
/// earned, it is no longer something the player can miss.
List<SecondaryAchievementItem> filterAchievements(
  List<SecondaryAchievementItem> achievements,
  AchievementFilter filter,
) {
  return switch (filter) {
    AchievementFilter.all => achievements,
    AchievementFilter.locked => achievements.where((a) => !a.earned).toList(),
    AchievementFilter.missables =>
      achievements.where((a) => !a.earned && a.isMissable).toList(),
  };
}

/// The RetroAchievements panel shown on the secondary display: game title,
/// earned/total + points header, progress bar, and a touch-scrollable badge
/// grid or detail list (toggle in the header). Tapping a badge opens its
/// comments page.
///
/// Pure, input-driven subtree — the owning [SecondaryScreen] passes the state
/// snapshot, the two view-state flags ([listView] / [celebrate]), the l10n
/// context, and the tap callbacks, so the panel re-reads no state of its own.
class AchievementPanel extends StatelessWidget {
  const AchievementPanel({
    super.key,
    required this.value,
    required this.listView,
    required this.filter,
    required this.celebrate,
    required this.l10nContext,
    required this.onToggleListView,
    required this.onCycleFilter,
    required this.onSelectAchievement,
  });

  final SecondaryDisplayStateData value;

  /// Whether the list view (vs. the badge grid) is currently shown.
  final bool listView;

  /// The subset currently displayed in either the badge grid or detail list.
  final AchievementFilter filter;

  /// Whether the "freshly earned" celebration banner should be shown.
  final bool celebrate;

  /// Context used for localized strings (the host's stored MaterialApp context);
  /// falls back to this widget's own context when null.
  final BuildContext? l10nContext;

  /// Toggles between the badge grid and the detail list.
  final VoidCallback onToggleListView;

  /// Advances through All, Locked, and Missables.
  final VoidCallback onCycleFilter;

  /// Opens the comments page for the tapped achievement.
  final void Function(SecondaryAchievementItem a) onSelectAchievement;

  @override
  Widget build(BuildContext context) {
    final sortedAchievements =
        List<SecondaryAchievementItem>.from(value.achievements!)..sort((a, b) {
          if (a.earned != b.earned) return a.earned ? -1 : 1;
          return a.displayOrder.compareTo(b.displayOrder);
        });
    final achievements = filterAchievements(sortedAchievements, filter);

    final newlyEarned = value.newlyEarnedIds?.toSet() ?? const <int>{};
    final progress = value.raTotal > 0 ? value.raEarned / value.raTotal : 0.0;
    final title = (value.raGameTitle != null && value.raGameTitle!.isNotEmpty)
        ? value.raGameTitle!
        : value.systemName;

    return Container(
      width: double.infinity,
      height: double.infinity,
      // Opaque background so the underlying game screenshot doesn't bleed
      // through; matches the secondary display's themed background color.
      color: value.backgroundColor != null
          ? Color(value.backgroundColor!)
          : Colors.black,
      padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 20.r),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header: title + earned/total + points.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Symbols.trophy_rounded,
                    color: const Color(0xFFFFC107),
                    size: 26.r,
                  ),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18.r,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5.r,
                        fontFamily: 'Anta',
                      ),
                    ),
                  ),
                  SizedBox(width: 12.r),
                  Text(
                    '${value.raEarned}/${value.raTotal}',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.r,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Anta',
                    ),
                  ),
                  SizedBox(width: 12.r),
                  Text(
                    '${value.raPoints}/${value.raPointsTotal}p',
                    style: TextStyle(
                      color: const Color(0xFFFFC107),
                      fontSize: 16.r,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Anta',
                    ),
                  ),
                  SizedBox(width: 8.r),
                  _buildFilterButton(context),
                  SizedBox(width: 8.r),
                  // Touch toggle: grid <-> list. Shows the icon of the view
                  // you'll switch to. The bottom screen is touch-only since
                  // the gamepad is driving the game on the main screen.
                  GestureDetector(
                    onTap: onToggleListView,
                    child: Container(
                      padding: EdgeInsets.all(8.r),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10.r),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Icon(
                        listView
                            ? Symbols.grid_view_rounded
                            : Symbols.view_list_rounded,
                        color: Colors.white,
                        size: 22.r,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.r),
              ClipRRect(
                borderRadius: BorderRadius.circular(4.r),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 6.r,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFFFFC107),
                  ),
                ),
              ),
              SizedBox(height: 16.r),
              // Content: badge grid or list, both touch-scrollable. Unlocked
              // achievements are sorted first within the selected filter.
              Expanded(
                child: achievements.isEmpty
                    ? _buildEmptyFilterState(context)
                    : listView
                    ? _buildAchievementListView(achievements, newlyEarned)
                    : SingleChildScrollView(
                        child: Wrap(
                          spacing: 8.r,
                          runSpacing: 8.r,
                          children: [
                            for (final a in achievements)
                              buildAchievementBadge(
                                a,
                                isNew: newlyEarned.contains(a.id),
                                onTap: () => onSelectAchievement(a),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),

          // Celebration banner for freshly-earned achievements.
          if (celebrate && newlyEarned.isNotEmpty)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: EdgeInsets.only(top: 2.r),
                padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 10.r),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107),
                  borderRadius: BorderRadius.circular(20.r),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFC107).withValues(alpha: 0.5),
                      blurRadius: 24.r,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.celebration_rounded,
                      color: Colors.black,
                      size: 22.r,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      '+${newlyEarned.length} this session',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16.r,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Anta',
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterButton(BuildContext context) {
    final label = switch (filter) {
      AchievementFilter.all => AppLocale.filterAll,
      AchievementFilter.locked => AppLocale.raFilterLocked,
      AchievementFilter.missables => AppLocale.raFilterMissables,
    }.getString(l10nContext ?? context);

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onCycleFilter,
        child: Container(
          constraints: BoxConstraints(minHeight: 38.r),
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.filter_list_rounded,
                color: Colors.white,
                size: 19.r,
              ),
              SizedBox(width: 4.r),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11.r,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Anta',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyFilterState(BuildContext context) {
    return Center(
      child: Text(
        AppLocale.raNoAchievementsForFilter.getString(l10nContext ?? context),
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white60, fontSize: 14.r),
      ),
    );
  }

  /// Touch-scrollable list of achievements: badge + title + description, with
  /// points and an earned/locked indicator. Shows detail the grid can't.
  Widget _buildAchievementListView(
    List<SecondaryAchievementItem> achievements,
    Set<int> newlyEarned,
  ) {
    return ListView.separated(
      padding: EdgeInsets.only(bottom: 8.r),
      itemCount: achievements.length,
      separatorBuilder: (_, _) => SizedBox(height: 8.r),
      itemBuilder: (context, i) {
        final a = achievements[i];
        final isNew = newlyEarned.contains(a.id);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelectAchievement(a),
          child: Container(
            padding: EdgeInsets.all(8.r),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: a.earned ? 0.08 : 0.03),
              borderRadius: BorderRadius.circular(10.r),
              border: isNew
                  ? Border.all(color: const Color(0xFFFFC107), width: 1.5.r)
                  : null,
            ),
            child: Row(
              children: [
                buildAchievementBadge(a, isNew: false),
                SizedBox(width: 12.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              a.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15.r,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'Anta',
                              ),
                            ),
                          ),
                          if (a.isMissable) ...[
                            SizedBox(width: 6.r),
                            Center(
                              child: buildMissablePill(
                                context,
                                l10nContext: l10nContext,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (a.description.isNotEmpty) ...[
                        SizedBox(height: 2.r),
                        Text(
                          a.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 12.r,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: 10.r),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${a.points}p',
                      style: TextStyle(
                        color: const Color(0xFFFFC107),
                        fontSize: 13.r,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Anta',
                      ),
                    ),
                    SizedBox(height: 4.r),
                    Icon(
                      a.earned
                          ? Symbols.check_circle_rounded
                          : Symbols.lock_rounded,
                      color: a.earned
                          ? const Color(0xFF66BB6A)
                          : Colors.white24,
                      size: 18.r,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The small "MISSABLE" pill shown next to missable achievements. Shared by the
/// achievement list and the comments page. Localized strings resolve against
/// [l10nContext] (the host's stored MaterialApp context) when provided, else
/// [context].
Widget buildMissablePill(BuildContext context, {BuildContext? l10nContext}) {
  return Container(
    padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
    decoration: BoxDecoration(
      color: const Color(0xFFE65100),
      borderRadius: BorderRadius.circular(8.r),
    ),
    child: Text(
      AppLocale.raMissable.getString(l10nContext ?? context),
      style: TextStyle(
        color: Colors.white,
        fontSize: 9.r,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.6.r,
        fontFamily: 'Anta',
      ),
    ),
  );
}

/// A single achievement badge: full-color when earned, dimmed locked icon
/// otherwise, with a gold glow when earned during the current session. Shared
/// by the achievement panel/list and the comments page.
Widget buildAchievementBadge(
  SecondaryAchievementItem a, {
  required bool isNew,
  VoidCallback? onTap,
}) {
  final double size = 46.r;
  final url = a.earned
      ? 'https://media.retroachievements.org/Badge/${a.badgeName}.png'
      : 'https://media.retroachievements.org/Badge/${a.badgeName}_lock.png';

  Widget badge = ClipRRect(
    borderRadius: BorderRadius.circular(8.r),
    child: Image.network(
      url,
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => Container(
        width: size,
        height: size,
        color: Colors.white10,
        child: Icon(Symbols.trophy_rounded, color: Colors.white24, size: 24.r),
      ),
    ),
  );

  if (!a.earned) {
    badge = Opacity(opacity: 0.45, child: badge);
  }

  Widget result = Container(
    decoration: isNew
        ? BoxDecoration(
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: const Color(0xFFFFC107), width: 2.r),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFC107).withValues(alpha: 0.6),
                blurRadius: 12.r,
              ),
            ],
          )
        : null,
    padding: EdgeInsets.all(isNew ? 2.r : 0),
    child: badge,
  );
  if (a.isMissable) {
    result = Stack(
      clipBehavior: Clip.none,
      children: [
        result,
        Positioned(
          top: -4.r,
          right: -4.r,
          child: Container(
            padding: EdgeInsets.all(2.r),
            decoration: const BoxDecoration(
              color: Color(0xFFE65100),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Symbols.warning_rounded,
              color: Colors.white,
              size: 13.r,
            ),
          ),
        ),
      ],
    );
  }
  return onTap == null
      ? result
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(padding: EdgeInsets.all(3.r), child: result),
        );
}
