import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/romm_save_game.dart';
import '../../services/romm/romm_cover_image_provider.dart';
import '../../services/romm_service.dart';
import '../../themes/corner_radii.dart';
import '../../utils/cover_decode.dart';

/// Tries existing device artwork, then RomM's stored covers. Failed images
/// advance to the next source without hiding the game or its saves.
class RommSaveArtwork extends StatefulWidget {
  final RommSaveGameInfo? info;
  final RommService service;
  final double width;
  final double height;

  const RommSaveArtwork({
    super.key,
    required this.info,
    required this.service,
    required this.width,
    required this.height,
  });

  @override
  State<RommSaveArtwork> createState() => _RommSaveArtworkState();
}

class _RommSaveArtworkState extends State<RommSaveArtwork> {
  int _attempt = 0;

  @override
  void didUpdateWidget(covariant RommSaveArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info != widget.info) _attempt = 0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = widget.info;
    final sources = <ImageProvider>[
      if (info?.localCover case final path?) FileImage(File(path)),
      for (final url in info?.serverCovers ?? const <String>[])
        RommCoverImage(url, widget.service),
    ];
    var attempt = _attempt;
    while (attempt < sources.length) {
      final source = sources[attempt];
      if (source is! RommCoverImage ||
          !widget.service.isDeadCover(source.url)) {
        break;
      }
      attempt++;
    }
    // The NeoSync save list's thumbnail for a save without art.
    final placeholder = ColoredBox(
      color: scheme.primary.withValues(alpha: 0.1),
      child: Center(
        child: Icon(
          Symbols.videogame_asset_rounded,
          size: widget.width * 0.5,
          color: scheme.primary,
        ),
      ),
    );
    // Cropped to fill, like covers everywhere else in the app.
    final hint = coverDecodeHint(
      logicalWidth: widget.width,
      logicalHeight: widget.height,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: CornerRadii.of(context).radiusInternal,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: attempt >= sources.length
              ? placeholder
              : Image(
                  key: ValueKey(sources[attempt]),
                  image: ResizeImage(
                    sources[attempt],
                    width: hint.cacheWidth,
                    height: hint.cacheHeight,
                  ),
                  fit: BoxFit.cover,
                  frameBuilder: (context, child, frame, synchronouslyLoaded) =>
                      frame == null ? placeholder : child,
                  errorBuilder: (context, error, stackTrace) {
                    final failed = _attempt;
                    final failedInfo = widget.info;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted &&
                          failed == _attempt &&
                          widget.info == failedInfo) {
                        setState(() => _attempt = attempt + 1);
                      }
                    });
                    return placeholder;
                  },
                ),
        ),
      ),
    );
  }
}
