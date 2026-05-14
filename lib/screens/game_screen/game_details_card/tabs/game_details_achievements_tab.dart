import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../../../models/retro_achievements_game_info.dart';

/// An overlay component that renders RetroAchievements progress, stats, and a navigable grid.
///
/// Handles heuristic sorting (unlocked first), percentage calculation, and
/// bidirectional gamepad navigation for trophy exploration.
class GameDetailsAchievementsTab extends StatefulWidget {
  final GameInfoAndUserProgress? gameInfo;
  final bool isLoading;
  final VoidCallback onRefresh;

  const GameDetailsAchievementsTab({
    super.key,
    this.gameInfo,
    required this.isLoading,
    required this.onRefresh,
  });

  @override
  State<GameDetailsAchievementsTab> createState() =>
      GameDetailsAchievementsTabState();
}

class GameDetailsAchievementsTabState
    extends State<GameDetailsAchievementsTab> {
  int _selectedAchievementIndex = 0;
  final Map<int, GlobalKey> _achievementKeys = {};
  final ScrollController _scrollController = ScrollController();

  /// Lazily retrieves or creates a GlobalKey for an achievement item to enable 'ensureVisible' logic.
  GlobalKey _getAchievementKey(int index) {
    return _achievementKeys.putIfAbsent(index, () => GlobalKey());
  }

  /// Sorts achievements by unlock status (priority) and then by original display order.
  List<Achievement> _getSortedAchievements() {
    if (widget.gameInfo == null) return [];
    final achievements = widget.gameInfo!.achievements.values.toList();
    achievements.sort((Achievement a, Achievement b) {
      final aUnlocked = a.dateEarned != null && a.dateEarned!.isNotEmpty;
      final bUnlocked = b.dateEarned != null && b.dateEarned!.isNotEmpty;

      // Secondary-sort unlocked achievements to the top of the grid.
      if (aUnlocked != bUnlocked) {
        return aUnlocked ? -1 : 1;
      }
      return a.displayOrder.compareTo(b.displayOrder);
    });
    return achievements;
  }

  /// Ensures the currently focused achievement is scrolled into the viewport.
  void _scrollToSelectedAchievement() {
    final key = _achievementKeys[_selectedAchievementIndex];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    }
  }

  /// Gamepad navigation delegate: Move focus up by one grid row (6 items).
  void moveUp() {
    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      if (_selectedAchievementIndex >= 6) {
        _selectedAchievementIndex -= 6;
      }
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus down by one grid row (6 items).
  void moveDown() {
    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      if (_selectedAchievementIndex + 6 < count) {
        _selectedAchievementIndex += 6;
      }
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus left by one item.
  void moveLeft() {
    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex =
          (_selectedAchievementIndex - 1 + count) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus right by one item.
  void moveRight() {
    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex = (_selectedAchievementIndex + 1) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Action trigger delegate: Currently unused for achievements (selection is purely visual).
  void trigger() {}

  @override
  Widget build(BuildContext context) {
    // Scenario 1: Metadata is being fetched.
    if (widget.gameInfo == null) {
      if (widget.isLoading) {
        return Positioned(
          left: 12.r,
          right: 12.r,
          top: 55.r,
          bottom: 98.r,
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2.r,
                  offset: Offset(2.0.r, 2.0.r),
                ),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  SizedBox(height: 16.r),
                  Text(
                    AppLocale.loadingAchievements.getString(context),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 12.r,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      // Scenario 2: Data is missing or system is unsupported.
      return Positioned(
        left: 12.r,
        right: 12.r,
        top: 55.r,
        bottom: 98.r,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.videogame_asset_off_rounded,
                  size: 48.r,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                SizedBox(height: 16.r),
                Text(
                  AppLocale.noAchievementsFound.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14.r,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Scenario 3: Achievements resolved successfully.
    final achievements = _getSortedAchievements();
    final total = achievements.length;
    final unlocked = achievements
        .where((a) => a.dateEarned != null && a.dateEarned!.isNotEmpty)
        .length;
    final percentage = total > 0
        ? (unlocked / total * 100).toStringAsFixed(0)
        : '0';

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: 98.r,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Contains progress stats and the manual refresh action.
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Symbols.emoji_events_rounded,
                            color: Colors.orange,
                            size: 13.r,
                          ),
                          SizedBox(width: 6.r),
                          Text(
                            AppLocale.achievements.getString(context),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 12.r,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.onSurface,
                              borderRadius: BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              '$unlocked / $total ($percentage%)',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.surface,
                                fontSize: 9.r,
                                fontWeight: FontWeight.w200,
                              ),
                            ),
                          ),
                          SizedBox(width: 6.r),
                          _HeaderActionButton(
                            icon: Image.asset(
                              'assets/images/gamepad/Xbox_Menu_button.png',
                              width: 12.r,
                              height: 12.r,
                            ),
                            label: AppLocale.refresh
                                .getString(context)
                                .toUpperCase(),
                            onTap: widget.onRefresh,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimary,
                          ),
                        ],
                      ),
                    ],
                  ),
                  Divider(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    height: 10.r,
                  ),
                ],
              ),
            ),

            // Content: Dual-pane layout (Metadata on left, Grid on right).
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.r),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: _SelectedAchievementInfo(
                        achievements: achievements,
                        selectedIndex: _selectedAchievementIndex,
                      ),
                    ),
                    SizedBox(width: 12.r),
                    Expanded(
                      flex: 6,
                      child: _AchievementsGrid(
                        achievements: achievements,
                        selectedIndex: _selectedAchievementIndex,
                        scrollController: _scrollController,
                        getKey: _getAchievementKey,
                        onSelect: (index) {
                          SfxService().playNavSound();
                          setState(() {
                            _selectedAchievementIndex = index;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 8.r),
          ],
        ),
      ),
    );
  }
}

/// A compact button styled for the achievement header.
class _HeaderActionButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final Color backgroundColor;
  final Color foregroundColor;

  const _HeaderActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(4.r),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4.r),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 3.r),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              SizedBox(width: 4.r),
              Text(
                label,
                style: TextStyle(
                  color: foregroundColor,
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pane that displays the title, description, and point value of the focused achievement.
class _SelectedAchievementInfo extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;

  const _SelectedAchievementInfo({
    required this.achievements,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    if (achievements.isEmpty) return const SizedBox.shrink();
    final safeIndex = selectedIndex.clamp(0, achievements.length - 1);
    final achievement = achievements[safeIndex];
    final isUnlocked =
        achievement.dateEarned != null && achievement.dateEarned!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            achievement.title,
            style: TextStyle(
              color: isUnlocked
                  ? Colors.orange
                  : Theme.of(context).colorScheme.onSurface,
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: 4.r),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              achievement.description,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 9.r,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        SizedBox(height: 4.r),
        Center(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondary,
              borderRadius: BorderRadius.circular(4.r),
            ),
            child: Text(
              '${achievement.points} ${AppLocale.points.getString(context)}',
              style: TextStyle(color: Colors.white, fontSize: 9.r),
            ),
          ),
        ),
        if (isUnlocked) ...[
          SizedBox(height: 4.r),
          Center(
            child: Text(
              AppLocale.unlocked.getString(context),
              style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 10.r,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Navigable grid of trophy badges loaded dynamically from RetroAchievements infrastructure.
class _AchievementsGrid extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;
  final ScrollController scrollController;
  final GlobalKey Function(int) getKey;
  final ValueChanged<int> onSelect;

  const _AchievementsGrid({
    required this.achievements,
    required this.selectedIndex,
    required this.scrollController,
    required this.getKey,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      controller: scrollController,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 4.r,
        mainAxisSpacing: 4.r,
        childAspectRatio: 1.0,
      ),
      itemCount: achievements.length,
      itemBuilder: (context, index) {
        final achievement = achievements[index];
        final isUnlocked =
            achievement.dateEarned != null &&
            achievement.dateEarned!.isNotEmpty;
        final isSelected = index == selectedIndex;

        return GestureDetector(
          key: getKey(index),
          onTap: () => onSelect(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.secondary
                    : (isUnlocked
                          ? Colors.orange.withValues(alpha: 0.5)
                          : Colors.transparent),
                width: isSelected ? 2.r : 1.r,
              ),
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4.r),
              child: Image.network(
                // Use the standard RA Badge CDN protocol for locked vs unlocked icons.
                isUnlocked
                    ? 'https://media.retroachievements.org/Badge/${achievement.badgeName}.png'
                    : 'https://media.retroachievements.org/Badge/${achievement.badgeName}_lock.png',
                cacheWidth: 64,
                fit: BoxFit.cover,
              ),
            ),
          ),
        );
      },
    );
  }
}
