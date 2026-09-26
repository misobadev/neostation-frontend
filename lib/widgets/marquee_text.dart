import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:marquee/marquee.dart';

class MarqueeText extends StatelessWidget {
  final String text;
  final bool isActive;
  final TextStyle? style;
  final TextAlign? textAlign;
  final double? height;

  const MarqueeText({
    super.key,
    required this.text,
    required this.isActive,
    this.style,
    this.textAlign,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use TextPainter to measure if the text overflows the available width
        // and to get the exact height of the text
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: effectiveStyle),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: double.infinity);

        final bool overflows = textPainter.size.width > constraints.maxWidth;
        final double textHeight = textPainter.size.height;
        // Some display fonts draw descenders (y, g, p) below their reported
        // metric line height. The Marquee branch below scrolls inside a
        // ListView, which clips to this box, so a box sized to exactly
        // `textHeight` shears the bottoms off those glyphs. Add a small
        // descender allowance (font-size relative) so the clip region covers
        // them. Only applied when no explicit height is supplied.
        final double descenderGuard =
            (effectiveStyle.fontSize ?? textHeight) * 0.2;
        final double contentHeight = height ?? (textHeight + descenderGuard);

        return SizedBox(
          width: double.infinity,
          height: contentHeight,
          child: (overflows && isActive)
              ? Marquee(
                  text: text,
                  style: effectiveStyle,
                  scrollAxis: Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  blankSpace:
                      24.r, // Space between the end and the start of the text
                  velocity: 50.0, // Smooth scrolling speed
                  pauseAfterRound: const Duration(
                    seconds: 3,
                  ), // Pause at the end of each round
                  accelerationDuration: const Duration(seconds: 1),
                  accelerationCurve: Curves.linear,
                  decelerationDuration: const Duration(milliseconds: 500),
                  decelerationCurve: Curves.easeOut,
                )
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    text,
                    style: effectiveStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: textAlign,
                  ),
                ),
        );
      },
    );
  }
}
