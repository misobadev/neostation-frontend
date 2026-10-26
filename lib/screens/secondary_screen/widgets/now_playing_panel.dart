import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../models/secondary_display_state.dart';
import '../now_playing_helpers.dart';
import '../../../l10n/app_locale.dart';
import 'status_readout.dart';

/// The Now Playing page shown on the secondary display: boxart + game/system
/// title + play-time / session / last-played stats.
///
/// The app dock and all-apps launcher are no longer part of this panel — they
/// are drawn as a persistent overlay by [SecondaryScreen] so they stay visible
/// in every state (browsing and in-game), not just while a game is active.
///
/// Pure, input-driven subtree — the owning [SecondaryScreen] passes the current
/// state snapshot, the live session readout ([sessionRunning] / [sessionTime]),
/// and the action callbacks, so the panel re-reads no state of its own.
class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({
    super.key,
    required this.value,
    required this.sessionRunning,
    required this.sessionTime,
    required this.use12HourClock,
    required this.onRequestScreenshot,
  });

  final SecondaryDisplayStateData value;

  /// Whether a play session is currently being timed (drives the SESSION stat).
  final bool sessionRunning;

  /// Pre-formatted elapsed session time (`HH:MM:SS`); only shown when
  /// [sessionRunning].
  final String sessionTime;

  /// Whether the corner clock uses the 12-hour (AM/PM) form, mirroring the
  /// user's header-clock preference.
  final bool use12HourClock;

  /// Asks the main engine to capture a screenshot of the main screen.
  final VoidCallback onRequestScreenshot;

  @override
  Widget build(BuildContext context) {
    final title = (value.gameTitle != null && value.gameTitle!.isNotEmpty)
        ? value.gameTitle!
        : value.systemName;
    final scheme = panelScheme(value);

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: scheme.surface,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(44.r, 32.r, 44.r, 96.r),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                buildNowPlayingBoxart(value.gameBoxart),
                SizedBox(width: 32.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        AppLocale.nowPlayingTitle
                            .getString(context)
                            .toUpperCase(),
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 14.r,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 3.r,
                        ),
                      ),
                      SizedBox(height: 12.r),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 30.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8.r),
                      Text(
                        value.systemName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.7),
                          fontSize: 16.r,
                          letterSpacing: 1.5.r,
                        ),
                      ),
                      SizedBox(height: 26.r),
                      buildNowPlayingStat(
                        scheme: scheme,
                        icon: Symbols.schedule_rounded,
                        label: AppLocale.playTime
                            .getString(context)
                            .toUpperCase(),
                        text: formatPlayTime(
                          value.playTimeSeconds,
                          (key) => key.getString(context),
                        ),
                      ),
                      if (sessionRunning) ...[
                        SizedBox(height: 12.r),
                        buildNowPlayingStat(
                          scheme: scheme,
                          icon: Symbols.timer_rounded,
                          label: AppLocale.nowPlayingSession
                              .getString(context)
                              .toUpperCase(),
                          text: sessionTime,
                        ),
                      ],
                      SizedBox(height: 12.r),
                      buildNowPlayingStat(
                        scheme: scheme,
                        icon: Symbols.history_rounded,
                        label: AppLocale.nowPlayingLastPlayed
                            .getString(context)
                            .toUpperCase(),
                        text: formatLastPlayed(
                          value.lastPlayedMillis,
                          (key) => key.getString(context),
                        ),
                      ),
                      if (value.screenshotAccessEnabled) ...[
                        SizedBox(height: 28.r),
                        _buildScreenshotButton(context, scheme),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Clock + battery, pinned to the corner the panel's own content never
          // reaches. The bottom screen is the only place these are readable
          // while a game owns the top screen, and a single wake tap surfaces
          // them alongside the play-time stats.
          Positioned(
            top: 22.r,
            right: 26.r,
            child: StatusReadout(
              scheme: scheme,
              themeName: value.themeName,
              use12HourClock: use12HourClock,
            ),
          ),
        ],
      ),
    );
  }

  /// Tappable pill that asks the main engine to capture a system screenshot of
  /// the main screen.
  Widget _buildScreenshotButton(BuildContext context, ColorScheme scheme) {
    return GestureDetector(
      onTap: onRequestScreenshot,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 12.r),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.photo_camera_rounded,
              color: scheme.onSurface,
              size: 22.r,
            ),
            SizedBox(width: 12.r),
            Text(
              AppLocale.screenshot.getString(context).toUpperCase(),
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14.r,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.r,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
