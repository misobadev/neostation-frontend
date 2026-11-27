import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

/// A game's cover in a square slot: covers come in every shape, so the whole
/// image is fitted inside the square (never cropped or stretched) and only
/// the image itself gets the rounded corners.
class RaCoverSquare extends StatelessWidget {
  final String url;
  final double size;

  const RaCoverSquare({super.key, required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Icon(
      Symbols.videogame_asset_rounded,
      color: theme.colorScheme.primary,
      size: size * 0.45,
    );
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: url.isEmpty
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(5.r),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  // One side only, so the image keeps its own shape.
                  cacheHeight: (size * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
      ),
    );
  }
}
