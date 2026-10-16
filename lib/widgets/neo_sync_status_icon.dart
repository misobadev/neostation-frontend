import '../constants/system_folder_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/game_model.dart';
import '../models/neo_sync_models.dart';
import '../models/system_model.dart';
import '../sync/i_sync_provider.dart';
import '../themes/chrome_surface.dart';
import '../themes/corner_radii.dart';

/// Compact icon-only NeoSync status indicator.
///
/// Renders a small descriptive icon whose color reflects the current cloud
/// synchronization state for the selected game. No text is shown, making it
/// suitable for tight spaces such as the game views' footers.
class NeoSyncStatusIcon extends StatefulWidget {
  final SystemModel system;
  final GameModel? game;
  final ISyncProvider syncProvider;
  final double size;

  /// Spacing applied *only* when the icon actually renders. Every state that
  /// says nothing collapses to [SizedBox.shrink], so a caller cannot wrap this
  /// in a spacer of its own without leaving a hole when sync is unavailable.
  final EdgeInsetsGeometry? margin;

  /// Whether to draw the rounded surface chip behind the glyph.
  ///
  /// True in the grid/carousel footer, where this icon is one pill among a row
  /// of them and has to match. False on the details card, where it sits beside
  /// the filename painted straight onto the game's fanart: there the chip read
  /// as a button, so the glyph goes bare and carries a drop shadow instead —
  /// same treatment as the text it sits next to.
  final bool showBackground;

  /// Colour for the states that have no status colour of their own.
  ///
  /// "Sync is off for this game" and "no save found yet" are absences rather
  /// than conditions, so they take the colour of the text around them and read
  /// as part of the line instead of as a warning on it. That colour is the
  /// theme's `onSurface` by default, which is wrong for a caller drawing on an
  /// inverted background — the game list's selected row paints its foreground
  /// in `onPrimary`, and an `onSurface` glyph there is the one mark on the row
  /// that disappears into the highlight. Such a caller passes its own
  /// foreground here; null keeps `onSurface`, which is right everywhere else.
  ///
  /// The states that *do* mean something — uploading, downloading, an error, a
  /// full quota — keep their own colours regardless: those are the point.
  final Color? mutedColor;

  /// Overrides the chip's corner, for a caller whose row is fully rounded.
  ///
  /// Only meaningful when [showBackground] is true. Null keeps the theme's own
  /// internal radius, which is what every other caller wants.
  final BorderRadius? borderRadius;

  /// Whether the bare glyph carries the drop shadow that lifts it off artwork.
  ///
  /// Only meaningful when [showBackground] is false. True on the details card,
  /// which paints straight onto the game's fanart. False in the grid and
  /// carousel footer, which sits on the flat scaffold surface — there the
  /// shadow has nothing to lift the glyph off and reads as grime, the same
  /// reason that footer drops the shadows from its text.
  final bool showGlyphShadow;

  const NeoSyncStatusIcon({
    super.key,
    required this.system,
    required this.game,
    required this.syncProvider,
    this.size = 24.0,
    this.margin,
    this.showBackground = true,
    this.showGlyphShadow = true,
    this.mutedColor,
    this.borderRadius,
  });

  /// Whether this icon will draw anything at all for the given game.
  ///
  /// The widget collapses to [SizedBox.shrink] in every "nothing to say" state,
  /// which is invisible to a caller laying out around it. A caller that has to
  /// reserve the icon's width up front — the details card measures its filename
  /// against the space left over — asks here rather than re-deriving these
  /// conditions and drifting out of step with them.
  static bool willRender({
    required SystemModel system,
    required GameModel? game,
    required ISyncProvider syncProvider,
  }) {
    if (!system.neosync.sync) return false;
    if (SystemFolderNames.isAndroidApps(system.folderName)) return false;
    if (!syncProvider.isAuthenticated) return false;
    if (system.screenscraperId == null || system.screenscraperId == 0) {
      return false;
    }
    return game != null;
  }

  @override
  State<NeoSyncStatusIcon> createState() => _NeoSyncStatusIconState();
}

class _NeoSyncStatusIconState extends State<NeoSyncStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!NeoSyncStatusIcon.willRender(
      system: widget.system,
      game: widget.game,
      syncProvider: widget.syncProvider,
    )) {
      return const SizedBox.shrink();
    }

    final status = _resolveStatus();
    if (status.isSyncing && !_rotationController.isAnimating) {
      _rotationController.repeat();
    } else if (!status.isSyncing && _rotationController.isAnimating) {
      _rotationController.stop();
    }

    final theme = Theme.of(context);
    final cornerRadius =
        widget.borderRadius ??
        theme.extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(8.r);

    // Bare glyph: no chip, so `size` is the glyph itself rather than the box
    // around it, and the shadow moves onto the icon to keep it legible where a
    // pale patch of artwork runs underneath.
    if (!widget.showBackground) {
      return Padding(
        padding: widget.margin ?? EdgeInsets.zero,
        child: AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) => Transform.rotate(
            angle: status.icon == Symbols.sync_rounded
                ? _rotationController.value * 2 * 3.14159
                : 0,
            child: child,
          ),
          child: Icon(
            status.icon,
            color: status.color,
            size: widget.size.r,
            shadows: widget.showGlyphShadow
                ? [
                    Shadow(
                      blurRadius: 1.r,
                      color: Colors.black,
                      offset: const Offset(2, 2),
                    ),
                  ]
                : null,
          ),
        ),
      );
    }

    return Padding(
      padding: widget.margin ?? EdgeInsets.zero,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: widget.size.r,
        height: widget.size.r,
        decoration: BoxDecoration(
          // The same fill every other chip in a footer row uses, rather than an
          // opaque surface. This one sits among them, and at full opacity it
          // was the only chip on the row the artwork did not show through.
          color: ChromeSurface.fill(context),
          borderRadius: cornerRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _rotationController,
            builder: (context, child) {
              return Transform.rotate(
                angle: status.icon == Symbols.sync_rounded
                    ? _rotationController.value * 2 * 3.14159
                    : 0,
                child: child,
              );
            },
            child: Icon(
              status.icon,
              color: status.color,
              size: (widget.size * 0.6).r,
            ),
          ),
        ),
      ),
    );
  }

  _NeoSyncStatus _resolveStatus() {
    final game = widget.game!;
    final muted = widget.mutedColor;
    final cloudSyncEnabled = game.cloudSyncEnabled ?? true;
    final gameState = widget.syncProvider.getGameSyncState(game.romname);
    final isSyncing = widget.syncProvider.status == SyncProviderStatus.syncing;

    if (!cloudSyncEnabled) {
      return _NeoSyncStatus(
        icon: Symbols.cloud_off_rounded,
        color: muted ?? Theme.of(context).colorScheme.onSurface,
        isSyncing: false,
      );
    }
    if (isSyncing) {
      return _NeoSyncStatus(
        icon: Symbols.sync_rounded,
        color: Colors.lightBlue,
        isSyncing: true,
      );
    }
    if (widget.syncProvider.lastError != null) {
      return _NeoSyncStatus(
        icon: Symbols.error_outline_rounded,
        color: const Color(0xFFE53E3E),
        isSyncing: false,
      );
    }

    if (gameState != null) {
      switch (gameState.status) {
        case GameSyncStatus.upToDate:
          return _NeoSyncStatus(
            icon: Symbols.check_circle_outline_rounded,
            color: const Color(0xFF79AA41),
            isSyncing: false,
          );
        case GameSyncStatus.localOnly:
          return _NeoSyncStatus(
            icon: Symbols.cloud_upload_rounded,
            color: Colors.orange,
            isSyncing: false,
          );
        case GameSyncStatus.cloudOnly:
          return _NeoSyncStatus(
            icon: Symbols.cloud_download_rounded,
            color: Colors.lightBlue,
            isSyncing: false,
          );
        case GameSyncStatus.syncing:
          return _NeoSyncStatus(
            icon: Symbols.sync_rounded,
            color: Colors.lightBlue,
            isSyncing: true,
          );
        case GameSyncStatus.disabled:
          return _NeoSyncStatus(
            icon: Symbols.cloud_off_rounded,
            color: muted ?? Colors.grey,
            isSyncing: false,
          );
        case GameSyncStatus.quotaExceeded:
          return _NeoSyncStatus(
            icon: Symbols.storage_rounded,
            color: Colors.redAccent,
            isSyncing: false,
          );
        case GameSyncStatus.noSaveFound:
          return _NeoSyncStatus(
            icon: Symbols.save_alt_rounded,
            color: muted ?? Colors.grey,
            isSyncing: false,
          );
        case GameSyncStatus.missingEmulator:
          return _NeoSyncStatus(
            icon: Symbols.videogame_asset_off_rounded,
            color: Colors.orange,
            isSyncing: false,
          );
        case GameSyncStatus.error:
          return _NeoSyncStatus(
            icon: Symbols.error_outline_rounded,
            color: Colors.red,
            isSyncing: false,
          );
      }
    }

    return _NeoSyncStatus(
      icon: Symbols.sync_rounded,
      color: Colors.lightBlue,
      isSyncing: true,
    );
  }
}

class _NeoSyncStatus {
  final IconData icon;
  final Color color;
  final bool isSyncing;

  const _NeoSyncStatus({
    required this.icon,
    required this.color,
    required this.isSyncing,
  });
}
