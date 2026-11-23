/// Geometry for the header strip (`lib/widgets/header.dart`).
///
/// The header is a [Stack] of three independently positioned children — the
/// left dropdown, the centred tab strip, and the right status pill — so nothing
/// structurally stops them colliding. The tab strip is centred on the *screen*,
/// which means every tab added grows it by half a slot on each side while the
/// status pill stays pinned right; enough tabs (or a wide enough clock string)
/// and the two meet.
///
/// These helpers are pure so the arithmetic can be tested without standing up
/// the widget, its providers, and a battery stream. Callers pass values that
/// are already screen-scaled (`.r`).
library;

/// Width of the centred tab strip: an `LB` glyph, the tab pill, and an `RB`
/// glyph.
///
/// Mirrors the widths in `header.dart`: each shoulder button is a 24-wide
/// bumper glyph with 6 of padding either side (36 total), and the pill is 4 of
/// padding either side around [tabCount] slots of [slot] each.
double navStripWidth({
  required int tabCount,
  double slot = 32,
  double shoulder = 36,
  double pillPadding = 4,
}) => (shoulder * 2) + (pillPadding * 2) + (slot * tabCount);

/// Natural width of the right-hand status pill.
///
/// Mirrors the row in `header.dart`: horizontal padding either side,
/// optionally the clock glyph and its gap, the clock
/// label, and optionally the battery block. [bell] and [bellGap] cover a
/// notification bell inside the pill; pass 0 when it lives elsewhere. Text widths are measured by the
/// caller (they depend on the string, the locale and the text scaler), so this
/// stays pure.
///
/// Pass [batteryTextWidth] as 0 when the battery block is hidden — it is
/// suppressed on TVs, on devices reporting no battery, and on XS handhelds.
double statusPillWidth({
  required double clockTextWidth,
  double batteryTextWidth = 0,
  bool withClockGlyph = true,
  double horizontalPadding = 10,
  double bell = 14,
  double bellGap = 10,
  double glyph = 14,
  double glyphGap = 4,
  double batteryGap = 12,
  double batteryIcon = 16,
  double batteryIconGap = 4,
}) {
  var width = (horizontalPadding * 2) + bell + bellGap + clockTextWidth;
  if (withClockGlyph) width += glyph + glyphGap;
  if (batteryTextWidth > 0) {
    width += batteryGap + batteryIcon + batteryIconGap + batteryTextWidth;
  }
  return width;
}

/// Space the right-hand status pill may occupy before it would touch the
/// centred tab strip.
///
/// The strip is centred, so it reaches [navStripWidth] / 2 either side of the
/// midpoint; whatever is left on the right, minus the pill's own [margin] and a
/// visual [gutter], is what the pill can have. Never negative — a strip wider
/// than the screen would otherwise ask for a negative constraint and throw.
double statusPillMaxWidth({
  required double totalWidth,
  required double navStripWidth,
  double margin = 8,
  double gutter = 4,
}) {
  final free = ((totalWidth - navStripWidth) / 2) - margin - gutter;
  return free < 0 ? 0 : free;
}

/// How many tab slots the centred strip may show before it would meet the
/// right-hand status pill.
///
/// The inverse of [statusPillMaxWidth]. The strip is centred, so the pill and
/// its [margin] and [gutter] are mirrored on the left when working out what is
/// left for the strip; the shoulder glyphs and the pill's own padding come off
/// that, and the rest divides into slots.
///
/// Pass a *worst-case* [statusPillWidth] — the widest clock string the locale
/// and 12/24-hour setting can produce, with the battery block reserved whenever
/// the device has one. Sizing off the live pill would let the slot count flip
/// as the clock ticked past a digit or the battery fell to one.
///
/// Never returns fewer than [minSlots]: a screen too narrow even for those is
/// handled by the pill scaling itself down, not by shrinking the strip further.
int navStripMaxSlots({
  required double totalWidth,
  required double statusPillWidth,
  double slot = 32,
  double shoulder = 36,
  double pillPadding = 4,
  double margin = 8,
  double gutter = 4,
  int minSlots = 5,
}) {
  final free = totalWidth - (2 * (statusPillWidth + margin + gutter));
  final slots = (free - (shoulder * 2) - (pillPadding * 2)) ~/ slot;
  return slots < minSlots ? minSlots : slots;
}
