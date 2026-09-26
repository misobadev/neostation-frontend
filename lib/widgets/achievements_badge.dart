import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/game_model.dart';
import '../utils/ra_coverage.dart';

/// Trophy + achievement count drawn on a library tile.
///
/// Everything it renders comes from columns the library query already returns —
/// the RetroAchievements match and the count the bundled snapshot lists for it —
/// so a grid of hundreds of tiles costs no API call and no extra query.
///
/// It renders nothing unless the ROM is matched *and* the snapshot lists at
/// least one achievement. That is deliberate: "not matched" covers a system
/// RetroAchievements does not carry, a disc image the app cannot hash yet, a ROM
/// nothing has hashed, and a ROM that genuinely has no set, and stamping one
/// "no achievements" marker across all four would report facts about
/// RetroAchievements' catalogue as gaps in the library. An absent badge is
/// silence, not a claim; the search screen's Achievements filter is where the
/// distinction is spelled out.
class AchievementsBadge extends StatelessWidget {
  /// The pill drawn over artwork: dark plate, trophy, achievement count.
  const AchievementsBadge({super.key, required this.game})
    : compact = false,
      color = null,
      inlineSize = 11;

  /// Trophy only, no plate or count — for a text row that has no artwork to sit
  /// on and no vertical room for a pill. [color] follows the row's foreground so
  /// the marker stays legible on the selected row's inverted background.
  const AchievementsBadge.inline({
    super.key,
    required this.game,
    required this.color,
    this.inlineSize = 11,
  }) : compact = true;

  final GameModel game;
  final bool compact;
  final Color? color;
  final double inlineSize;

  /// Whether [game] would draw anything, so callers can skip the `Positioned`
  /// wrapper entirely rather than stacking an invisible child on every tile.
  static bool showsFor(GameModel game) =>
      game.raCoverage == RaCoverage.matched &&
      (game.raNumAchievements ?? 0) > 0;

  /// Trophy and count share one colour on purpose: the badge sits on artwork
  /// that is already busy, so it reads as a single mark rather than an icon with
  /// a label stuck to it. A coloured trophy also competes with the box art it is
  /// drawn over, and there is no second state for a colour to distinguish.
  static const Color _plateForeground = Colors.white;

  @override
  Widget build(BuildContext context) {
    if (!showsFor(game)) return const SizedBox.shrink();
    final total = game.raNumAchievements!;

    if (compact) {
      return Semantics(
        label: 'RetroAchievements: $total achievements',
        child: Icon(
          Symbols.emoji_events_rounded,
          size: inlineSize.r,
          color: color,
        ),
      );
    }

    return Semantics(
      label: 'RetroAchievements: $total achievements',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 2.r),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(9.r),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.emoji_events_rounded,
              size: 12.r,
              color: _plateForeground,
            ),
            SizedBox(width: 3.r),
            Text(
              '$total',
              style: TextStyle(
                color: _plateForeground,
                fontSize: 9.r,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
