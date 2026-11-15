import 'package:test/test.dart';
import 'package:neostation/utils/header_layout.dart';

/// The header's tab strip is centred on the screen while the status pill is
/// pinned right, so they are only kept apart by arithmetic — there is no
/// constraint between them in the widget tree. Adding the RomM tab took the
/// gap on a Thor-class display from ~14px to about -7px with a 12-hour clock,
/// which is the collision these functions exist to prevent.
void main() {
  group('navStripWidth', () {
    test('is the two bumpers, the pill padding, and one slot per tab', () {
      // 36 + 36 shoulders, 4 + 4 padding, 32 per tab.
      expect(navStripWidth(tabCount: 0), 80);
      expect(navStripWidth(tabCount: 6), 272);
      expect(navStripWidth(tabCount: 7), 304);
    });

    test('each additional tab costs exactly one slot', () {
      for (var n = 0; n < 8; n++) {
        expect(navStripWidth(tabCount: n + 1) - navStripWidth(tabCount: n), 32);
      }
    });
  });

  group('statusPillWidth', () {
    test('the clock glyph and its gap are the only difference', () {
      expect(
        statusPillWidth(clockTextWidth: 50, withClockGlyph: true) -
            statusPillWidth(clockTextWidth: 50, withClockGlyph: false),
        14 + 4,
      );
    });

    test('a hidden battery block costs nothing', () {
      expect(
        statusPillWidth(clockTextWidth: 50, batteryTextWidth: 0),
        statusPillWidth(clockTextWidth: 50),
      );
      expect(
        statusPillWidth(clockTextWidth: 50, batteryTextWidth: 20),
        greaterThan(statusPillWidth(clockTextWidth: 50)),
      );
    });

    test('12-hour time is wider than 24-hour, which is the trigger', () {
      // "11:59 PM" against "23:59" at the same style.
      expect(
        statusPillWidth(clockTextWidth: 48),
        greaterThan(statusPillWidth(clockTextWidth: 30)),
      );
    });
  });

  group('statusPillMaxWidth', () {
    test('never lets the pill reach the centred strip', () {
      // The invariant that matters: the strip occupies half its width either
      // side of the midpoint, so the pill's allowance plus that half plus the
      // margin and gutter must still fit in half the screen.
      for (final total in <double>[560, 640, 832, 1280, 1920]) {
        for (var tabs = 1; tabs <= 7; tabs++) {
          final strip = navStripWidth(tabCount: tabs);
          final allowed = statusPillMaxWidth(
            totalWidth: total,
            navStripWidth: strip,
          );
          expect(
            allowed + (strip / 2) + 8 + 4,
            lessThanOrEqualTo(total / 2 + 0.001),
            reason: 'tabs=$tabs total=$total must not overlap the strip',
          );
        }
      }
    });

    test('adding a tab costs the pill exactly half a slot', () {
      double allowanceFor(int tabs) => statusPillMaxWidth(
        totalWidth: 832,
        navStripWidth: navStripWidth(tabCount: tabs),
      );

      expect(allowanceFor(6) - allowanceFor(7), 16);
    });

    test('the RomM tab shrinks the allowance on a Thor-class display', () {
      // Measured on an AYN Thor: 1080x1920 at density 369 gives dpr 2.31, so
      // the logical width is ~832 and ScreenUtil resolves `.r` to scaleWidth
      // 832/640 = 1.30. Widths below are therefore scaled the way the widget
      // scales them. The 12-hour status pill measured ~217 logical px there
      // (bell, clock icon, "11:40 PM", battery icon, "78%").
      const totalWidth = 832.0;
      const scale = 1.301;
      const measuredPillWidth = 217.0;

      double allowanceFor(int tabs) => statusPillMaxWidth(
        totalWidth: totalWidth,
        navStripWidth: navStripWidth(
          tabCount: tabs,
          slot: 32 * scale,
          shoulder: 36 * scale,
          pillPadding: 4 * scale,
        ),
        margin: 8 * scale,
        gutter: 4 * scale,
      );

      // Six tabs fit — that is why this was never seen before RomM.
      expect(allowanceFor(6), greaterThan(measuredPillWidth));
      // Seven do not: the pill must now be constrained rather than overlap.
      expect(allowanceFor(7), lessThan(measuredPillWidth));
    });

    test('the clock glyph is dropped at seven tabs and returns at six', () {
      // Thor metrics as above; text widths measured from the rendered pill
      // ("11:59 PM" and "78%" at fontSize 12).
      const totalWidth = 832.0;
      const scale = 1.301;

      double allowanceFor(int tabs) => statusPillMaxWidth(
        totalWidth: totalWidth,
        navStripWidth: navStripWidth(
          tabCount: tabs,
          slot: 32 * scale,
          shoulder: 36 * scale,
          pillPadding: 4 * scale,
        ),
        margin: 8 * scale,
        gutter: 4 * scale,
      );

      double pill({required bool withClockGlyph}) => statusPillWidth(
        clockTextWidth: 48 * scale,
        batteryTextWidth: 22 * scale,
        withClockGlyph: withClockGlyph,
        horizontalPadding: 10 * scale,
        bell: 14 * scale,
        bellGap: 10 * scale,
        glyph: 14 * scale,
        glyphGap: 4 * scale,
        batteryGap: 12 * scale,
        batteryIcon: 16 * scale,
        batteryIconGap: 4 * scale,
      );

      // Seven tabs: the glyph no longer fits, but the pill does without it —
      // so it is dropped rather than the whole pill being scaled down.
      expect(pill(withClockGlyph: true), greaterThan(allowanceFor(7)));
      expect(pill(withClockGlyph: false), lessThan(allowanceFor(7)));

      // Hide one tab in settings and the room comes back, so does the glyph.
      expect(pill(withClockGlyph: true), lessThan(allowanceFor(6)));
    });

    test('clamps to zero rather than going negative on a narrow screen', () {
      expect(
        statusPillMaxWidth(
          totalWidth: 200,
          navStripWidth: navStripWidth(tabCount: 7),
        ),
        0,
      );
    });
  });
}
