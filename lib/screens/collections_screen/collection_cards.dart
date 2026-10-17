import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/services/sfx_service.dart';

import '../../themes/corner_radii.dart';

/// Fallback tint for a collection that has no artwork and no stored colours,
/// matching the Collections virtual system's own palette.
const String kCollectionFallbackColor = '#7C4DFF';

/// Presents [collection] to the systems-card widgets.
///
/// Collections are not systems, but they are shown with the same card, so they
/// are handed to it as a [SystemInfo]: the artwork becomes the card background,
/// the name becomes both the title and the logo fallback text (there is no
/// `assets/images/logos/collection:<uuid>.webp`, so `SystemCard` falls through
/// to [SystemLogoFallback], which renders the name), and the game count feeds
/// the footer.
///
/// [imageVersion] must be `CollectionsProvider.imageVersion`: replacing the
/// artwork writes to the same path, so only a changing version busts the
/// `ValueKey` the card keys its `Image.file` on.
///
/// [mosaicPaths] are covers of the games the collection holds — a collection
/// has no theme background to fall back on, so without them the card is a flat
/// tint. Drawn when the user has chosen no artwork, and also when chosen
/// artwork fails to load: `SystemCard` gives a custom background precedence,
/// so passing them alongside one only furnishes its `errorBuilder`. Pass them
/// unconditionally — a card whose artwork file has gone missing is otherwise
/// blank with no way to tell why.
SystemInfo collectionToSystemInfo(
  CollectionModel collection, {
  required int imageVersion,
  List<String> mosaicPaths = const [],
}) {
  return SystemInfo(
    isSmartCollection: collection.isSmart,
    title: collection.name,
    shortName: collection.name,
    folderName: '${SystemFolderNames.collectionPrefix}${collection.id}',
    numOfRoms: collection.gameCount,
    color1: collection.color1 ?? kCollectionFallbackColor,
    color2: collection.color2,
    customBackgroundPath: collection.imagePath,
    imageVersion: imageVersion,
    mosaicPaths: mosaicPaths,
  );
}

/// Whether [collection]'s cover mosaic is worth resolving.
///
/// Deliberately **not** conditional on the collection having artwork of its
/// own. `SystemCard` paints chosen artwork through `Image.file` and falls back
/// to the mosaic from its `errorBuilder`, so the mosaic is precisely what a
/// card needs when its artwork file has gone missing or will not decode.
/// Skipping the resolve for collections with an `imagePath` left that fallback
/// with nothing to draw and the card painted a flat tint — a blank card with
/// no way to tell why, recoverable only via "Remove artwork", which worked
/// only because clearing the path started the resolve again. Observed on the
/// Thor against a collection whose file was gone from `media/collections/`.
///
/// A card with *working* artwork is unaffected: `SystemCard` gives a custom
/// background precedence over the mosaic, so the covers are only ever reached
/// down the error path.
bool collectionWantsMosaic(CollectionModel collection) =>
    collection.gameCount > 0;

/// Folder name of the synthetic trailing entry.
///
/// It rides in the same `List<SystemInfo>` the real collections do so the
/// systems grid/carousel lay it out, navigate to it and select it exactly as
/// they do any other card; only its *rendering* is overridden (see
/// [SystemCardOverrideBuilder]). The colon-free form keeps it out of
/// `SystemFolderNames.isCollection`, which matches `collection:<uuid>`.
const String kNewCollectionCardFolder = 'collections__new';

/// The trailing "New collection" entry, as the systems widgets see it.
SystemInfo newCollectionCardInfo(String label) => SystemInfo(
  title: label,
  shortName: label,
  folderName: kNewCollectionCardFolder,
);

/// Lines the "New collection" caption is allowed to wrap onto.
const int kCaptionMaxLines = 2;

/// Shrinks [style] until [text] renders *whole* inside a [maxWidth] x
/// [maxHeight] box across at most [kCaptionMaxLines] lines.
///
/// A `FittedBox` cannot do this on its own. It scales what the `Text` reports,
/// and a `Text` pinned to the card's width reports exactly that width even when
/// one unbreakable word ("COLLECTION") is wider than it — the word is quietly
/// ellipsized instead of the box being flagged as too small. Measuring
/// [TextPainter.minIntrinsicWidth] (the longest word) is what catches that case,
/// and it is the case that rendered "NEW COLLECTI…" on a card at size S.
///
/// [letterSpacing] is an absolute value, so it is scaled with the font size;
/// otherwise a shrunken label keeps a spacing that no longer fits either.
TextStyle fitCaptionStyle({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  double minFontSize = 5.0,
}) {
  final double baseSize = style.fontSize ?? 10.0;
  final double baseSpacing = style.letterSpacing ?? 0.0;
  if (maxWidth <= 0 || maxHeight <= 0) return style;

  for (double size = baseSize; size > minFontSize; size -= 0.5) {
    final candidate = style.copyWith(
      fontSize: size,
      letterSpacing: baseSpacing * (size / baseSize),
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: candidate),
      maxLines: kCaptionMaxLines,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    final fits =
        !painter.didExceedMaxLines &&
        painter.minIntrinsicWidth <= maxWidth &&
        painter.height <= maxHeight;
    painter.dispose();
    if (fits) return candidate;
  }

  return style.copyWith(
    fontSize: minFontSize,
    letterSpacing: baseSpacing * (minFontSize / baseSize),
  );
}

/// The trailing card of the collections browser: activating it creates a new
/// collection.
///
/// It cannot be a [SystemInfo] fed to `SystemCard` — that card always paints an
/// image (or a colour wash) plus a logo, and this one is deliberately an icon
/// and a label. The surrounding chrome is copied so the two sit flush in the
/// same grid.
class NewCollectionCard extends StatelessWidget {
  const NewCollectionCard({
    super.key,
    required this.label,
    required this.isSelected,
    this.onTap,
  });

  /// Already-localized caption ("New collection").
  final String label;

  /// Whether the grid's cursor is on this card. Only changes the tap sound —
  /// the focus ring is drawn by the grid, as it is for system cards.
  final bool isSelected;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>();

    return Padding(
      padding: EdgeInsets.all(2.r),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: radii?.radiusExternal ?? BorderRadius.circular(14.r),
            border: Border.all(color: theme.colorScheme.outline, width: 1.r),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radii?.radiusInternal ?? BorderRadius.circular(9.r),
            child: InkWell(
              onTap: () {
                if (isSelected) {
                  SfxService().playEnterSound();
                } else {
                  SfxService().playNavSound();
                }
                onTap?.call();
              },
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: Padding(
                padding: EdgeInsets.only(
                  top: 4.r,
                  bottom: 0.r,
                  left: 4.r,
                  right: 4.r,
                ),
                child: Column(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius:
                            radii?.radiusInternal ?? BorderRadius.circular(9.r),
                        child: Container(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          child: Center(
                            child: Icon(
                              Symbols.add_rounded,
                              size: 64.r,
                              weight: 700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // "New collection" is wider than a card at every size but
                    // XL, so the caption is measured against the band it has to
                    // fit and shrunk until the whole label lands inside it.
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.r),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final base = TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 10.r,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.0,
                              height: 1.15,
                            );
                            final text = label.toUpperCase();
                            final fitted = fitCaptionStyle(
                              text: text,
                              style: base,
                              maxWidth: constraints.maxWidth,
                              maxHeight: constraints.maxHeight,
                            );
                            return Center(
                              child: Text(
                                text,
                                maxLines: kCaptionMaxLines,
                                textAlign: TextAlign.center,
                                style: fitted,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
