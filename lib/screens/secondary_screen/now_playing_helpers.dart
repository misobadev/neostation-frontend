import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/providers/theme_provider.dart';
import '../../models/secondary_display_state.dart';
import '../../l10n/app_locale.dart';
import '../../widgets/monospaced_clock.dart';

/// Pure presentation helpers for the secondary display's Now Playing / panel
/// chrome — theme + colour-scheme resolution and the leaf builders/formatters.
///
/// Extracted verbatim from `_SecondaryScreenState`; every function is a pure
/// mapping from its inputs to a value/widget with no widget-state reads, so the
/// rendered output is unchanged.

/// Resolves the full user-selected theme for the secondary display from the
/// theme name pushed by the main engine. The secondary display runs in the
/// same isolate as the main app, so [ThemeProvider.availableThemes] is the
/// source of truth. Falls back to the brightness-appropriate neostation
/// theme for 'system' mode or an unknown/absent name.
ThemeData resolveTheme(String? themeName) {
  final themes = ThemeProvider.availableThemes;
  final direct = themeName != null ? themes[themeName] : null;
  if (direct != null) return direct;
  final brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  return brightness == Brightness.dark ? themes['dark']! : themes['light']!;
}

/// WCAG contrast ratio between two opaque colors (1.0 = identical, 21.0 =
/// black-on-white).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Builds the effective color scheme for the Now Playing panel. Text colors
/// are derived from the *actual* painted background luminance (not the
/// theme's own on-colors, which can mismatch the pushed background and
/// collapse contrast on light themes), while the theme's primary accent is
/// preserved as long as it stays legible on that background.
ColorScheme panelScheme(SecondaryDisplayStateData value) {
  final base = resolveTheme(value.themeName).colorScheme;
  final bg = value.backgroundColor != null
      ? Color(value.backgroundColor!)
      : base.surface;
  final fg = bg.computeLuminance() > 0.5
      ? const Color(0xFF14161A)
      : Colors.white;
  final accent = contrastRatio(base.primary, bg) >= 3.0 ? base.primary : fg;
  return base.copyWith(surface: bg, onSurface: fg, primary: accent);
}

Widget buildNowPlayingBoxart(String? path) {
  Widget placeholder() => Container(
    width: 184.r,
    height: 264.r,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12.r),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    ),
    child: Icon(
      Symbols.videogame_asset_rounded,
      color: Colors.white24,
      size: 64.r,
    ),
  );

  if (path == null) return placeholder();
  final file = File(path);
  if (!file.existsSync()) return placeholder();

  return ClipRRect(
    borderRadius: BorderRadius.circular(12.r),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 360.r, maxWidth: 200.r),
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => placeholder(),
      ),
    ),
  );
}

Widget buildNowPlayingStat({
  required ColorScheme scheme,
  required IconData icon,
  required String label,
  required String text,
}) {
  final muted = scheme.onSurface.withValues(alpha: 0.55);
  return Row(
    children: [
      Icon(icon, color: muted, size: 20.r),
      SizedBox(width: 10.r),
      Text(
        '$label  ',
        style: TextStyle(color: muted, fontSize: 14.r, letterSpacing: 1.r),
      ),
      // Translated labels and values ("ZULETZT GESPIELT  Vor 365 Tagen") can
      // nearly fill the column; clip the value rather than overflow.
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 16.r,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

/// Total play time in the app language's short units ("1h 30m", "12m",
/// "<1m"): [text] looks up an [AppLocale] key, as for [formatLastPlayed].
String formatPlayTime(int? seconds, String Function(String key) text) {
  if (seconds == null || seconds <= 0) return '—';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) {
    return text(
      AppLocale.playTimeHoursMinutes,
    ).replaceFirst('{h}', '$h').replaceFirst('{m}', '$m');
  }
  if (m > 0) return text(AppLocale.playTimeMinutes).replaceFirst('{m}', '$m');
  return text(AppLocale.playTimeUnderMinute);
}

/// The running session length as a digital HH:MM:SS reading, shown alongside
/// the (static) total play time while a game is active. It reads the same in
/// every language and shows the per-second tick.
String formatSessionTime(int seconds) => MonospacedClock.format(seconds);

/// How long ago [millis] was, in the app language: [text] looks up an
/// [AppLocale] key (the panel passes `(key) => key.getString(context)`).
String formatLastPlayed(int? millis, String Function(String key) text) {
  if (millis == null) return text(AppLocale.timeNever);
  final then = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(then);
  String count(String key, int n) => text(key).replaceFirst('{count}', '$n');
  if (diff.inDays >= 1) {
    final d = diff.inDays;
    return d == 1
        ? text(AppLocale.timeYesterday)
        : count(AppLocale.timeDaysAgo, d);
  }
  if (diff.inHours >= 1) return count(AppLocale.timeHoursAgo, diff.inHours);
  if (diff.inMinutes >= 1) {
    return count(AppLocale.timeMinutesAgo, diff.inMinutes);
  }
  return text(AppLocale.timeJustNow);
}
