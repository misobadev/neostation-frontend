import '../../services/ra_library_match_runner.dart';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/widgets/splash_status_layout.dart';

import '../../../providers/sqlite_config_provider.dart';
import 'my_systems_section/my_systems_grid.dart';
import 'my_systems_section/initial_setup_widget.dart';

/// Orchestrator for the 'Systems' tab content.
///
/// Manages the visual state transition between the initial scanning/loading phase,
/// the setup wizard for first-time users, and the primary system library grid.
class SystemContent extends StatefulWidget {
  const SystemContent({super.key, this.selectedIndex = 0, this.onCardTapped});

  /// Index of the currently selected system card within the grid.
  final int selectedIndex;

  /// Callback invoked when a system card is interactively selected.
  final Function(int index)? onCardTapped;

  @override
  State<SystemContent> createState() => _SystemContentState();
}

class _SystemContentState extends State<SystemContent> {
  @override
  Widget build(BuildContext context) {
    return Consumer2<SqliteConfigProvider, ThemeProvider>(
      builder: (context, configProvider, themeProvider, child) {
        return ValueListenableBuilder<RaMatchProgress?>(
          valueListenable: RaLibraryMatchRunner.progress,
          builder: (context, raProgress, _) =>
              _buildPhase(context, configProvider, raProgress),
        );
      },
    );
  }

  Widget _buildPhase(
    BuildContext context,
    SqliteConfigProvider configProvider,
    RaMatchProgress? raProgress,
  ) {
    // The RetroAchievements pass the startup sequence fires is part of getting
    // the library ready, so the startup screen waits for it exactly as it waits
    // for the ROM scan, rather than handing over a library that is still being
    // matched behind the user's back. Only the startup pass sets this — the one
    // that resumes after a game session must never pull the splash back up.
    final raHoldsSplash = raProgress?.holdsSplash ?? false;

    // Determine the current operational state of the library.
    final isLoading =
        configProvider.isLoading || configProvider.isScanning || raHoldsSplash;
    // No minimum display time: a fast scan is a fast start, and holding the
    // logo up after the library is ready only makes the app feel slower than
    // it is. The 400 ms cross-fade below is what keeps a quick one from
    // reading as a flicker.
    final showSplash = isLoading;

    // Show setup wizard if scan is finished but no systems were resolved.
    final showInitialSetup =
        !showSplash &&
        !configProvider.hasDetectedSystems &&
        configProvider.scanCompleted;

    // Show primary library content only when initialization and scanning are complete.
    final showContent =
        !showSplash && configProvider.scanCompleted && !showInitialSetup;

    // PHASE 1: Loading and Initialization — a shimmering NeoStation logo
    // with a thin progress bar and the current scan step as quiet detail.
    // PHASE 2: First-Run Experience / Initial Setup.
    // PHASE 3: Primary System Library.
    final Widget phase;
    if (showSplash) {
      phase = KeyedSubtree(
        key: const ValueKey('splash'),
        child: _buildSplash(context, configProvider, raProgress),
      );
    } else if (showInitialSetup) {
      phase = KeyedSubtree(
        key: const ValueKey('setup'),
        child: InitialSetupWidget(),
      );
    } else if (showContent) {
      phase = KeyedSubtree(
        key: const ValueKey('content'),
        child: MySystems(
          selectedIndex: widget.selectedIndex,
          onCardTapped: widget.onCardTapped,
        ),
      );
    } else {
      phase = const SizedBox.shrink(key: ValueKey('empty'));
    }

    // Cross-fade the splash into the library instead of a hard cut.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: phase,
    );
  }

  Widget _buildSplash(
    BuildContext context,
    SqliteConfigProvider configProvider,
    RaMatchProgress? raProgress,
  ) {
    // The logo sits at the exact screen centre — the same spot it occupies on
    // the native splash and the startup screens — with the progress detail
    // hung below it, so nothing shifts across the whole intro sequence.
    return SplashStatusLayout(
      // Track the scan only once it is actually progressing. During the
      // waiting-for-storage phase progress sits at 0, which would park the
      // glint off-screen and leave the logo frozen for up to 30s — keep the
      // ambient sweep running until there's real movement.
      progress: raProgress != null
          ? (raProgress.total != null && raProgress.total! > 0
                ? (raProgress.done ?? 0) / raProgress.total!
                : null)
          : (configProvider.isScanning && configProvider.scanProgress > 0
                ? configProvider.scanProgress
                : null),
      children: [
        // The RetroAchievements line replaces the per-system scan line rather
        // than stacking under it: by the time it runs the systems are all in,
        // and one calm line is the whole point.
        if (raProgress != null) ...[
          SizedBox(
            width: 220.r,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2.r),
              child: LinearProgressIndicator(
                value: raProgress.total != null && raProgress.total! > 0
                    ? (raProgress.done ?? 0) / raProgress.total!
                    : null,
                minHeight: 3.r,
                backgroundColor: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.12),
              ),
            ),
          ),
          SizedBox(height: 16.r),
          Text(
            raProgress.done != null && raProgress.total != null
                ? AppLocale.raMatchProgressCounted
                      .getString(context)
                      .replaceFirst('{done}', raProgress.done.toString())
                      .replaceFirst('{total}', raProgress.total.toString())
                : AppLocale.raMatchProgressBusy.getString(context),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 17 * SplashStatusLayout.textScaleOf(context),
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ] else if (configProvider.isScanning) ...[
          SizedBox(
            width: 220.r,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2.r),
              child: LinearProgressIndicator(
                value: configProvider.scanProgress,
                minHeight: 3.r,
                backgroundColor: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.12),
              ),
            ),
          ),
          SizedBox(height: 16.r),
          Text(
            configProvider.scanStatus.isNotEmpty
                ? configProvider.scanStatus
                : AppLocale.scanningSystemsRoms.getString(context),
            // 17 to match the startup screen's status line — the theme's
            // bodySmall (12) reads too small at couch distance.
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 17 * SplashStatusLayout.textScaleOf(context),
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}
