import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class ThemeCard extends StatefulWidget {
  const ThemeCard({
    super.key,
    required this.themeName,
    required this.displayName,
    this.onTap,
    this.onLongPress,
    this.onDelete,
    this.isSelected = false,
    this.isFocused = false,
  });

  final String themeName;
  final String displayName;
  final VoidCallback? onTap;

  /// Optional long-press handler, used to delete imported (custom) themes.
  final VoidCallback? onLongPress;

  /// When set, a small ✕ badge is shown on the card to delete the theme (used
  /// for imported/custom themes). Complements [onLongPress] and gamepad delete.
  final VoidCallback? onDelete;
  final bool isSelected;
  final bool isFocused;

  @override
  State<ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<ThemeCard> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(skipTraversal: true);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 4:3 app mockup. The grid sizes its cells from their width alone,
        // while the caption below follows the screen scale and text size, so
        // the preview takes the height the caption leaves (Flexible) and keeps
        // its shape by narrowing, instead of pushing the caption out of the
        // cell.
        Flexible(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              margin: EdgeInsets.symmetric(vertical: 4.h),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: widget.isFocused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2.r,
                ),
                boxShadow: widget.isFocused
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.3,
                          ),
                          blurRadius: 8.r,
                          spreadRadius: 1.r,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.r),
                child: Stack(
                  children: [
                    // 1. App Mockup
                    Positioned.fill(
                      child: Builder(
                        builder: (context) {
                          ThemeData themeData;
                          if (widget.themeName == 'system') {
                            final brightness = WidgetsBinding
                                .instance
                                .platformDispatcher
                                .platformBrightness;
                            themeData = AppThemes.getThemeDataByName(
                              brightness == Brightness.dark ? 'dark' : 'light',
                            );
                          } else {
                            themeData = AppThemes.getThemeDataByName(
                              widget.themeName,
                            );
                          }

                          return CustomPaint(
                            painter: _AppMockupPainter(
                              surface: themeData.colorScheme.surface,
                              primary: themeData.colorScheme.primary,
                              secondary: themeData.colorScheme.secondary,
                            ),
                          );
                        },
                      ),
                    ),

                    // Selection indicator: centered checkmark, only when selected
                    if (widget.isSelected)
                      Center(
                        child: Container(
                          width: 36.r,
                          height: 36.r,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.greenAccent,
                          ),
                          child: Icon(
                            Symbols.check_rounded,
                            color: Colors.black,
                            size: 24.r,
                          ),
                        ),
                      ),
                    // 5. InkWell Layer
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          focusNode: _focusNode,
                          onTap: () {
                            SfxService().playEnterSound();
                            widget.onTap?.call();
                          },
                          onLongPress: widget.onLongPress,
                        ),
                      ),
                    ),
                    // Delete badge for imported themes (on top of the InkWell so
                    // it receives its own taps).
                    if (widget.onDelete != null)
                      Positioned(
                        top: 4.r,
                        right: 4.r,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            canRequestFocus: false,
                            onTap: () {
                              SfxService().playEnterSound();
                              widget.onDelete!.call();
                            },
                            child: Padding(
                              padding: EdgeInsets.all(3.r),
                              child: Icon(
                                Symbols.close_rounded,
                                color: Colors.white,
                                size: 16.r,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 4.r),
        // Theme Name Text Below
        Text(
          widget.displayName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: widget.isFocused || widget.isSelected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.r,
          ),
        ),
      ],
    );
  }
}

class _AppMockupPainter extends CustomPainter {
  final Color surface;
  final Color primary;
  final Color secondary;

  const _AppMockupPainter({
    required this.surface,
    required this.primary,
    required this.secondary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final p = Paint();

    // Background
    p.color = surface;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), p);

    // ── Top nav bar ──
    final topH = h * 0.15;
    p.color = primary.withValues(alpha: 0.07);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, topH), p);

    // "View Mode" pill (top-left)
    p.color = primary.withValues(alpha: 0.55);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.02, topH * 0.28, w * 0.12, topH * 0.44),
        Radius.circular(topH * 0.22),
      ),
      p,
    );

    // Centered nav icons (6 tabs)
    final iconR = topH * 0.18;
    const iconCount = 6;
    final spacing = iconR * 3.0;
    final startX = (w - (iconCount - 1) * spacing) / 2;
    for (int i = 0; i < iconCount; i++) {
      p.color = i == 1 ? primary : primary.withValues(alpha: 0.22);
      canvas.drawCircle(Offset(startX + i * spacing, topH / 2), iconR, p);
    }

    // Clock strip (top-right)
    p.color = primary.withValues(alpha: 0.3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.86, topH * 0.28, w * 0.1, topH * 0.44),
        Radius.circular(2),
      ),
      p,
    );

    // ── Bottom bar ──
    final bottomH = h * 0.22;
    final bottomY = h - bottomH;
    p.color = secondary.withValues(alpha: 0.12);
    canvas.drawRect(Rect.fromLTWH(0, bottomY, w, bottomH), p);

    // System filter chips
    final chipH = bottomH * 0.38;
    final chipW = w * 0.055;
    final chipY = bottomY + bottomH * 0.12;
    final chipGap = w * 0.008;
    for (int i = 0; i < 11; i++) {
      final cx = w * 0.015 + i * (chipW + chipGap);
      p.color = i == 0
          ? primary.withValues(alpha: 0.75)
          : primary.withValues(alpha: 0.18);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx, chipY, chipW, chipH),
          Radius.circular(chipH / 2),
        ),
        p,
      );
    }

    // Action buttons row (bottom-right)
    final btnH = bottomH * 0.48;
    final btnY2 = bottomY + bottomH * 0.52;
    // Settings pill
    p.color = secondary.withValues(alpha: 0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.72, btnY2, w * 0.12, btnH),
        Radius.circular(btnH / 2),
      ),
      p,
    );
    // Enter button (primary)
    p.color = primary.withValues(alpha: 0.9);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.86, btnY2, w * 0.12, btnH),
        Radius.circular(btnH / 2),
      ),
      p,
    );

    // ── Carousel ──
    final carouselTop = topH + h * 0.025;
    final carouselBottom = bottomY - h * 0.025;
    final carouselH = carouselBottom - carouselTop;

    // Left partial card
    final sideW = w * 0.2;
    final sideH = carouselH * 0.78;
    final sideY = carouselTop + (carouselH - sideH) / 2;
    p.color = secondary.withValues(alpha: 0.38);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-sideW * 0.15, sideY, sideW, sideH),
        Radius.circular(w * 0.012),
      ),
      p,
    );

    // Right partial card
    p.color = secondary.withValues(alpha: 0.38);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w - sideW * 0.85, sideY, sideW, sideH),
        Radius.circular(w * 0.012),
      ),
      p,
    );

    // Center card (dominant)
    final centerW = w * 0.44;
    final centerX = (w - centerW) / 2;
    p.color = primary.withValues(alpha: 0.72);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX, carouselTop, centerW, carouselH),
        Radius.circular(w * 0.014),
      ),
      p,
    );

    // Game count strip on center card bottom
    p.color = surface.withValues(alpha: 0.35);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          centerX + centerW * 0.15,
          carouselTop + carouselH * 0.82,
          centerW * 0.7,
          carouselH * 0.1,
        ),
        Radius.circular(w * 0.006),
      ),
      p,
    );
  }

  @override
  bool shouldRepaint(_AppMockupPainter old) =>
      old.surface != surface ||
      old.primary != primary ||
      old.secondary != secondary;
}

/// Grid tile that triggers the "import custom theme" flow. Rendered as the last
/// item in the theme grid, styled to match [ThemeCard] (same footprint, focus
/// border and label) but with a dashed "+" placeholder instead of a preview.
class ImportThemeCard extends StatelessWidget {
  const ImportThemeCard({
    super.key,
    required this.label,
    this.onTap,
    this.isFocused = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool isFocused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Gives way to the caption like [ThemeCard]'s preview.
        Flexible(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              margin: EdgeInsets.symmetric(vertical: 4.h),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: isFocused
                      ? accent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.25),
                  width: 2.r,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.3),
                          blurRadius: 8.r,
                          spreadRadius: 1.r,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.r),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    canRequestFocus: false,
                    onTap: () {
                      SfxService().playEnterSound();
                      onTap?.call();
                    },
                    child: Center(
                      child: Icon(
                        Symbols.add_rounded,
                        color: isFocused
                            ? accent
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                        size: 32.r,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 4.r),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isFocused
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.r,
          ),
        ),
      ],
    );
  }
}
