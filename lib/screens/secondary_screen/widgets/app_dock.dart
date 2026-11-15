import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/secondary_apps_service.dart';

import '../../../models/config_model.dart';
import '../../../models/secondary_display_state.dart';
import '../now_playing_helpers.dart';

/// The bottom app dock on the Now Playing screen: a centered row of launch
/// slots. Filled slots launch their app (long-press clears); empty slots open
/// the app picker for that index.
///
/// Pure, input-driven subtree — the owning [SecondaryScreen] passes the current
/// state snapshot plus the three slot callbacks, so the dock re-reads no
/// provider state of its own. Mounting is the owner's call: it keeps the dock
/// alive through its slide-out after `dockEnabled` flips false, so this widget
/// deliberately does not blank itself on that flag.
class AppDock extends StatelessWidget {
  const AppDock({
    super.key,
    required this.value,
    required this.onLaunchApp,
    required this.onPickSlot,
    required this.onClearSlot,
    required this.onOpenAccessibilitySettings,
  });

  final SecondaryDisplayStateData value;

  /// Launches the docked app in [package] (prefers the bottom display).
  final void Function(String package) onLaunchApp;

  /// Opens the app picker to assign an app to the empty slot [index].
  final void Function(int index) onPickSlot;

  /// Clears the app assigned to slot [index].
  final void Function(int index) onClearSlot;

  /// Opens the Screen Return accessibility explainer/settings. Filled slots
  /// route here instead of launching when the service is off — launching an app
  /// without it would strand the user with no way back to the home screen.
  final VoidCallback onOpenAccessibilitySettings;

  @override
  Widget build(BuildContext context) {
    final apps = ConfigModel.normalizeDock(value.dockApps);
    final scheme = panelScheme(value);
    // Screen Return off → guard filled slots (see [onOpenAccessibilitySettings]).
    final accessOk = value.screenshotAccessEnabled;
    final visibleSlots = value.dockSlotCount.clamp(
      ConfigModel.dockMinSlotCount,
      ConfigModel.dockMaxSlotCount,
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 20.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < visibleSlots; i++) ...[
            if (i > 0) SizedBox(width: 14.r),
            _buildDockSlot(i, apps[i], scheme, accessOk),
          ],
        ],
      ),
    );
  }

  /// A single dock slot. [package] empty = free slot. When [accessOk] is false,
  /// a filled slot is guarded: tapping opens the Screen Return explainer instead
  /// of launching, and the slot wears an accent border to nudge the user to
  /// enable the service for the best experience. Empty slots are unaffected —
  /// assigning an app doesn't launch anything, so there's nothing to strand.
  Widget _buildDockSlot(
    int index,
    String package,
    ColorScheme scheme,
    bool accessOk,
  ) {
    final filled = package.isNotEmpty;
    final guarded = filled && !accessOk;
    return GestureDetector(
      onTap: () {
        if (!filled) {
          onPickSlot(index);
        } else if (guarded) {
          onOpenAccessibilitySettings();
        } else {
          onLaunchApp(package);
        }
      },
      onLongPress: filled ? () => onClearSlot(index) : null,
      child: Container(
        width: 56.r,
        height: 56.r,
        decoration: BoxDecoration(
          // Fully-opaque chip in the panel's own surface colour so slots stay
          // legible over busy background art, with a bright border + drop
          // shadow to separate them from the dark backing and the art.
          color: Color.alphaBlend(
            scheme.onSurface.withValues(alpha: filled ? 0.14 : 0.08),
            scheme.surface,
          ),
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: guarded
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: filled ? 0.55 : 0.40),
            width: guarded ? 2.r : 1.5.r,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 12.r,
              spreadRadius: 1.r,
              offset: Offset(0, 3.r),
            ),
          ],
        ),
        child: filled
            ? Padding(
                padding: EdgeInsets.all(8.r),
                child: buildDockIcon(package),
              )
            : Icon(
                Symbols.add_rounded,
                color: scheme.onSurface.withValues(alpha: 0.45),
                size: 26.r,
              ),
      ),
    );
  }
}

/// The all-apps launcher button, pinned to the bottom-left of the secondary
/// display alongside the [AppDock]. Normally opens the app picker in launch
/// mode. When the Screen Return accessibility service isn't enabled, it's
/// highlighted with an accent border + warning badge and instead opens
/// accessibility settings — launching an app without that service would strand
/// the user with no way back to the home screen.
///
/// Pure, input-driven subtree — the owner passes the current state snapshot and
/// the two callbacks, so the button re-reads no provider state of its own.
class DockLauncherButton extends StatelessWidget {
  const DockLauncherButton({
    super.key,
    required this.value,
    required this.onOpenLauncher,
    required this.onOpenAccessibilitySettings,
  });

  final SecondaryDisplayStateData value;

  /// Opens the app picker in launch mode (all-apps launcher).
  final VoidCallback onOpenLauncher;

  /// Opens Android accessibility settings to enable the Screen Return service.
  final VoidCallback onOpenAccessibilitySettings;

  @override
  Widget build(BuildContext context) {
    final scheme = panelScheme(value);
    final accessOk = value.screenshotAccessEnabled;
    return GestureDetector(
      onTap: accessOk ? onOpenLauncher : onOpenAccessibilitySettings,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 56.r,
            height: 56.r,
            decoration: BoxDecoration(
              // Opaque chip (see [AppDock]) so it reads over background art.
              color: accessOk
                  ? Color.alphaBlend(
                      scheme.onSurface.withValues(alpha: 0.08),
                      scheme.surface,
                    )
                  : Color.alphaBlend(
                      scheme.primary.withValues(alpha: 0.30),
                      scheme.surface,
                    ),
              borderRadius: BorderRadius.circular(14.r),
              border: Border.all(
                color: accessOk
                    ? scheme.onSurface.withValues(alpha: 0.40)
                    : scheme.primary,
                width: accessOk ? 1.5.r : 2.r,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 12.r,
                  spreadRadius: 1.r,
                  offset: Offset(0, 3.r),
                ),
              ],
            ),
            child: Icon(
              Symbols.apps_rounded,
              color: accessOk
                  ? scheme.onSurface.withValues(alpha: 0.65)
                  : scheme.primary,
              size: 28.r,
            ),
          ),
          if (!accessOk)
            Positioned(
              top: -4.r,
              right: -4.r,
              child: Container(
                width: 20.r,
                height: 20.r,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2.r),
                ),
                child: Icon(
                  Symbols.priority_high_rounded,
                  size: 12.r,
                  color: scheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lazily loads and renders a docked app's launcher icon (cached in
/// [SecondaryAppsService]). Shared by the dock slots and the app-picker tiles.
Widget buildDockIcon(String package) {
  return FutureBuilder<Uint8List?>(
    future: SecondaryAppsService.getAppIcon(package),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // Native side already rasterizes to ~56dp; cap the decode so the
          // engine keeps a small texture in memory rather than a full-res one.
          cacheWidth: 112,
        );
      }
      return Icon(
        Symbols.android_rounded,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        size: 24.r,
      );
    },
  );
}
