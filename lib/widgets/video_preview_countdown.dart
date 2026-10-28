import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Small circular countdown shown over a screenshot while a preview video
/// waits to start.
class VideoPreviewCountdown extends StatelessWidget {
  const VideoPreviewCountdown({
    super.key,
    required this.remaining,
    required this.total,
  });

  /// Time left before playback starts.
  final Duration remaining;

  /// Full delay configured by the user, used to keep the ring in step when the
  /// countdown starts after the game was already selected.
  final Duration total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalMs = total.inMilliseconds;
    final remainingMs = remaining.inMilliseconds.clamp(0, totalMs);
    final initial = totalMs <= 0 ? 1.0 : 1.0 - remainingMs / totalMs;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: initial.clamp(0.0, 1.0), end: 1),
      duration: Duration(milliseconds: remainingMs),
      builder: (context, progress, _) {
        return Container(
          width: 26.r,
          height: 26.r,
          padding: EdgeInsets.all(4.r),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.9),
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.3),
                blurRadius: 4.r,
                offset: Offset(0, 2.r),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.r,
                  backgroundColor: scheme.onSurface.withValues(alpha: 0.15),
                  color: scheme.primary,
                ),
              ),
              Icon(
                Symbols.play_arrow_rounded,
                size: 9.r,
                color: scheme.onSurface,
              ),
            ],
          ),
        );
      },
    );
  }
}
