import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../models/secondary_display_state.dart';
import '../../widgets/shaders/shader_gif_widget.dart';
import '../../utils/image_utils.dart' as image_utils;

/// Pure background/artwork builders for the secondary display.
///
/// Extracted verbatim from `_SecondaryScreenState` — every function is a pure
/// mapping from a [SecondaryDisplayStateData] snapshot (plus constant styling)
/// to a widget subtree, with no reference to widget state. Behaviour and the
/// rendered tree are unchanged.

Widget buildBackgroundBytes(Uint8List bytes, {BoxFit fit = BoxFit.contain}) {
  return Image.memory(
    bytes,
    fit: fit,
    errorBuilder: (context, error, stackTrace) => buildDefaultBackground(),
  );
}

Widget buildBackground(String path, {BoxFit fit = BoxFit.contain}) {
  final file = File(path);
  if (file.existsSync()) {
    if (image_utils.ImageUtils.isGif(path)) {
      return ShaderGifWidget(
        imagePath: path,
        key: ValueKey('secondary_bg_$path'),
        fit: fit,
      );
    }
    return Image.file(file, fit: fit);
  }
  return buildDefaultBackground();
}

Widget buildDefaultBackground() {
  return const SizedBox.shrink();
}

/// How far the media matte blends the theme background towards black.
const double _matteBlend = 0.88;

/// Dark matte for letterboxed game media — the preview video and the
/// contain-fitted screenshot — drawn above the app background and below the
/// media itself.
///
/// Without it the bars around a 4:3 snap on this wide panel show the theme's
/// background, so a light theme frames a dark, moving video in white: the eye
/// adapts to the bright surround and the video reads as muddy. Blending the
/// theme background most of the way to black keeps a hint of the user's theme
/// rather than punching a black hole in the UI, and is a no-op for the dark and
/// OLED themes that already sit near black.
///
/// A flat [ColoredBox] rather than a blurred copy of the frame: compositing
/// over this panel's video layer is what stalled the main display's raster
/// thread before, so the backdrop stays free of extra layers.
///
/// Fades on the same 256ms curve as the media it backs, so a screenshot giving
/// way to the video stays a single crossfade.
Widget buildMediaMatte(BuildContext context, {required bool visible}) {
  return AnimatedOpacity(
    opacity: visible ? 1.0 : 0.0,
    duration: const Duration(milliseconds: 256),
    child: ColoredBox(
      color: Color.lerp(
        Theme.of(context).scaffoldBackgroundColor,
        Colors.black,
        _matteBlend,
      )!,
    ),
  );
}

/// Offset of the wheel logo's drop shadow on the secondary display.
///
/// Derived from the main screen's treatment rather than picked by eye: it
/// offsets by 6.r on a 280.r-wide logo, so the shadow sits at ~2.1% of the
/// logo's width. This display renders the same logo at 600.r, so matching that
/// proportion is what makes the two screens read alike.
double get _wheelShadowOffset => 600.r * (6 / 280);

/// Mirrors the main screen's game art as a fallback when no screenshot or
/// video is available: fanart filling the screen (cover) with the game's
/// wheel/logo centered on top. Either asset is optional — a logo-only game
/// shows just the centered logo over the app background, and a fanart-only
/// game shows just the fanart.
Widget buildFanartWithLogo(SecondaryDisplayStateData value) {
  return Stack(
    fit: StackFit.expand,
    children: [
      if (value.gameFanart != null)
        buildBackground(value.gameFanart!, fit: BoxFit.cover),
      // Optional scrim over the fanart only (below the logo) so a busy
      // background doesn't clash with the logo. The logo, drawn next, stays
      // at full brightness.
      if (value.gameFanart != null && value.fanartDimLevel > 0)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(
              alpha: value.fanartDimLevel.clamp(0, 100) / 100.0,
            ),
          ),
        ),
      if (value.gameWheel != null)
        Center(
          child: Padding(
            padding: EdgeInsets.all(48.r),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Drop shadow: tinted copy offset behind the logo, mirroring
                // the main screen's wheel shadow treatment (see the general
                // details tab) — same tint and the same offset *relative to
                // the logo*. The offset has to be scaled, not copied: this
                // logo renders at 600.r against the main screen's 280.r, so
                // the main screen's 6.r would tuck under the artwork here
                // instead of reading as a shadow.
                //
                // Decoded at the same cacheWidth as the logo below it. That is
                // not just for fidelity — at 600.r a smaller decode is visibly
                // blocky — but also cheaper: cacheWidth is part of the
                // ResizeImage cache key, so matching it means both copies share
                // one decode instead of each holding its own bitmap.
                Builder(
                  builder: (context) => Transform.translate(
                    offset: Offset(_wheelShadowOffset, _wheelShadowOffset),
                    child: Image.file(
                      File(value.gameWheel!),
                      fit: BoxFit.contain,
                      width: 600.r,
                      filterQuality: FilterQuality.low,
                      isAntiAlias: false,
                      cacheWidth: 640,
                      color: Theme.of(context).colorScheme.shadow
                          .withValues(alpha: 0.5),
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                Image.file(
                  File(value.gameWheel!),
                  fit: BoxFit.contain,
                  width: 600.r,
                  cacheWidth: 640,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

Widget buildUnifiedAppBackground(SecondaryDisplayStateData value) {
  if (value.isOled) {
    return Container(
      color: value.backgroundColor != null
          ? Color(value.backgroundColor!)
          : Colors.black,
    );
  }

  return Builder(
    builder: (context) {
      final bg = Theme.of(context).scaffoldBackgroundColor;
      return Container(decoration: BoxDecoration(color: bg));
    },
  );
}

Widget buildSystemBackground(SecondaryDisplayStateData value) {
  // Note: OLED is intentionally NOT short-circuited here. For a highlighted
  // system the console artwork IS the background, so blacking it out would
  // leave only the console name on screen. The black/background-color
  // fallback below (via buildShaderFallback) still applies when no system
  // image is available, preserving the OLED look in the empty case.
  final bgPath = value.systemBackground;
  final hasBg = bgPath != null && bgPath.isNotEmpty;

  if (hasBg) {
    final isGif = image_utils.ImageUtils.isGif(bgPath);

    Widget? art;
    if (value.isBackgroundAsset) {
      if (isGif) {
        art = ShaderGifWidget(
          imagePath: bgPath,
          key: ValueKey('secondary_system_bg_$bgPath'),
        );
      } else {
        art = Image.asset(
          bgPath,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              buildShaderFallback(value),
        );
      }
    } else {
      final file = File(bgPath);
      if (file.existsSync()) {
        if (isGif) {
          art = ShaderGifWidget(
            imagePath: bgPath,
            key: ValueKey('secondary_system_bg_$bgPath'),
          );
        } else {
          art = Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                buildShaderFallback(value),
          );
        }
      }
    }

    if (art != null) {
      return _withFanartDim(art, value);
    }
  }

  return buildShaderFallback(value);
}

/// Overlays the same dim scrim used behind game logos so system console
/// artwork doesn't clash with the system name/logo drawn on top. Mirrors the
/// scrim in [buildFanartWithLogo]; a no-op when the dim level is 0.
Widget _withFanartDim(Widget art, SecondaryDisplayStateData value) {
  if (value.fanartDimLevel <= 0) return art;
  return Stack(
    fit: StackFit.expand,
    children: [
      art,
      Positioned.fill(
        child: ColoredBox(
          color: Colors.black.withValues(
            alpha: value.fanartDimLevel.clamp(0, 100) / 100.0,
          ),
        ),
      ),
    ],
  );
}

Widget buildShaderFallback(SecondaryDisplayStateData value) {
  if (value.backgroundColor != null) {
    return Container(color: Color(value.backgroundColor!));
  }
  // No background pushed yet — the WELCOME screen during startup, before the
  // main engine has sent one. Falling back to the theme rather than a hardcoded
  // black keeps the panel in the user's theme instead of showing a dark screen
  // for the whole of the boot. OLED resolves to black here anyway, so the
  // empty-case OLED look described above is preserved.
  return Builder(
    builder: (context) =>
        Container(color: Theme.of(context).scaffoldBackgroundColor),
  );
}
