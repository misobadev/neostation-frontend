import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

/// A performant, dependency-free frosted-glass surface.
///
/// It replicates the cheap "frosted" path of the liquid-glass packages we
/// evaluated: a single engine [BackdropFilter] blur pass over a translucent
/// tint, clipped to the panel's own shape, with a canvas-drawn specular rim.
///
/// Deliberately does NOT do the expensive parts of a full liquid-glass
/// package — refraction, distortion, chromatic aberration and the shader that
/// re-samples the live backdrop every frame. Those shader passes are what made
/// the previous dependency heavy on low-end GPUs (Android TV included). The
/// engine blur is optimized and clipped to the small panel area, so this stays
/// cheap even when the content behind the glass changes every frame.
///
/// Structure is intentionally flat: the frosted surface is one clipped node
/// and the rim is a single [CustomPaint] foreground pass on top of it — no
/// stacked sibling layer, no per-pass painters.
///
/// The blur sigma, the tint opacity (transparency) and the rim border width are
/// user-configurable. They are read from [SqliteConfigProvider] at build time
/// unless overridden via the corresponding constructor parameter, so changing
/// them in Settings > Themes applies immediately to every glass surface.
class NeoGlass extends StatelessWidget {
  const NeoGlass({
    super.key,
    required this.child,
    this.cornerRadius = 14,
    this.blur,
    this.tint,
    this.padding,
    this.rimIntensity = 1,
    this.borderWidth,
    this.transparency,
  });

  final Widget child;

  /// Corner radius of the glass panel.
  final double cornerRadius;

  /// Gaussian blur sigma applied to the backdrop.
  ///
  /// `0` disables the blur entirely — the surface becomes a flat translucent
  /// panel (the cheapest mode, zero backdrop cost). Keep it modest on low-end
  /// GPUs; the cost scales with the blurred area. When null, the user's
  /// configured blur is used.
  final double? blur;

  /// Translucent fill tinted over the blurred backdrop. Defaults to a
  /// scaffold-background tint.
  final Color? tint;

  /// Inset applied inside the glass around [child].
  final EdgeInsetsGeometry? padding;

  /// Strength of the specular rim highlight (0.0–1.0). The rim blends with the
  /// image behind the glass, so it appears as the backdrop colour lifted
  /// brighter.
  final double rimIntensity;

  /// Width of the specular rim stroke. When null, the user's configured border
  /// width is used.
  final double? borderWidth;

  /// Transparency of the tint fill on a 0–20 scale (stepped by 5). `0` means no
  /// transparency (opaque tint), `20` means the maximum transparency (backdrop
  /// shows through the most). When null, the user's configured transparency is
  /// used.
  final int? transparency;

  /// Reads the user's NeoGlass preferences from [SqliteConfigProvider], falling
  /// back to the feature defaults when the provider is absent (e.g. a preview
  /// subtree built without it).
  static ({double blur, int transparency, double borderWidth}) _prefs(
    BuildContext context,
  ) {
    try {
      final config = context.watch<SqliteConfigProvider>().config;
      return (
        blur: config.neoglassBlur.toDouble(),
        transparency: config.neoglassTransparency,
        borderWidth: config.neoglassBorderWidth,
      );
    } catch (_) {
      return (blur: 0, transparency: 5, borderWidth: 2);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs(context);
    final effectiveBlur = blur ?? prefs.blur;
    final effectiveTransparency = transparency ?? prefs.transparency;
    final effectiveBorderWidth = borderWidth ?? prefs.borderWidth;
    // Transparency 0–20 maps to the tint alpha: 0 → opaque (1.0), 20 → the
    // maximum see-through.
    final effectiveOpacity = (20 - effectiveTransparency) / 20.0;

    // Semi-transparent so the image behind shows through and the rim (drawn
    // beneath it) glows with the backdrop's colours.
    final glassTint =
        tint ??
        Theme.of(
          context,
        ).scaffoldBackgroundColor.withValues(alpha: effectiveOpacity);

    Widget surface = ColoredBox(
      color: glassTint,
      child: padding != null ? Padding(padding: padding!, child: child) : child,
    );

    // One engine blur pass over the backdrop, clipped to the panel shape.
    // This is the whole "frost" — no refraction shader, no per-frame capture.
    if (effectiveBlur > 0) {
      surface = BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: effectiveBlur,
          sigmaY: effectiveBlur,
        ),
        child: surface,
      );
    }

    return CustomPaint(
      foregroundPainter: rimIntensity > 0
          ? _GlassRimPainter(
              cornerRadius: cornerRadius,
              intensity: rimIntensity,
              strokeWidth: effectiveBorderWidth,
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cornerRadius),
        child: surface,
      ),
    );
  }
}

/// Paints the glass rim: a soft specular highlight sweeping with the light
/// direction, matching how the liquid-glass packages shade their borders — but
/// in a single plain-Canvas stroke blended over the backdrop.
class _GlassRimPainter extends CustomPainter {
  _GlassRimPainter({
    required this.cornerRadius,
    required this.intensity,
    required this.strokeWidth,
  }) : _colors = [
         Colors.white.withValues(alpha: 0.96 * intensity),
         Colors.white.withValues(alpha: 0.64 * intensity),
         Colors.white.withValues(alpha: 0.16 * intensity),
       ];

  final double cornerRadius;
  final double intensity;
  final double strokeWidth;

  // Precomputed, size-independent gradient stops (alpha depends only on
  // [intensity]); the shader itself is built per paint from the panel size.
  final List<Color> _colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0 || strokeWidth <= 0) return;

    // Rounded-rect outline offset OUTWARD by half the stroke width, so the
    // border sits outside the card's edge (external, not inset/middle) and
    // blends with the backdrop image behind the card.
    final extent = strokeWidth / 2;
    final rect = (Offset.zero & size).inflate(extent);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius + extent)),
      );

    // Light from the top-left. The rim stays light all around — it only fades
    // in strength towards the far edge, it never turns dark. Blended with
    // BlendMode.overlay so the edge reads as the backdrop colour lifted
    // brighter (overlay preserves the hue instead of washing it to white).
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..isAntiAlias = true
        ..blendMode = BlendMode.overlay
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _colors,
          stops: const [0.0, 0.60, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.intensity != intensity ||
      oldDelegate.strokeWidth != strokeWidth;
}
