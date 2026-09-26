import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Marks a game that is filed in at least one collection.
///
/// It answers "is this in a collection", not "which one": a game can be in
/// several, and a card has room for a mark, not a list. The Y menu's
/// `Remove from…` submenu is where the memberships themselves are shown, and
/// this uses the same bookmark glyph as its `Add to…` entry so the mark and the
/// action that produces it read as the same thing.
///
/// Membership comes from `CollectionsProvider.isInAnyCollection`, which holds
/// the whole set in memory, so badging a grid of hundreds of tiles costs no
/// query per card.
class CollectionBadge extends StatelessWidget {
  /// The plate drawn over artwork, matching the favourite heart's circle.
  ///
  /// [size] is the plate diameter: the grid draws 22.r circles, the carousel
  /// 32.r, so the badge takes the host's rather than picking one.
  const CollectionBadge({super.key, required this.size})
    : compact = false,
      color = null,
      inlineSize = 11;

  /// Glyph only, for a text row with no artwork to sit on. [color] follows the
  /// row's foreground so the mark stays legible on a selected row.
  const CollectionBadge.inline({
    super.key,
    required this.color,
    this.inlineSize = 11,
  }) : compact = true,
       size = 0;

  final bool compact;
  final Color? color;
  final double size;
  final double inlineSize;

  @override
  Widget build(BuildContext context) {
    final label = AppLocale.inACollection.getString(context);
    if (compact) {
      return Semantics(
        label: label,
        child: Icon(Symbols.bookmark_rounded, size: inlineSize.r, color: color),
      );
    }

    return Semantics(
      label: label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Symbols.bookmark_rounded,
          size: size * 0.56,
          fill: 1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
