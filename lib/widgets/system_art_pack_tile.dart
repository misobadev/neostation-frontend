import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/neo_assets_service.dart';

/// A compact system art pack row: a square mosaic of the pack's first images
/// and its key details. Tapping it (or pressing A) opens [SystemArtPackDialog]
/// with the full description and the apply/support actions.
///
/// Shared by the System Art settings list and the setup wizard.
class SystemArtPackTile extends StatelessWidget {
  /// The pack metadata to render.
  final NeoAssetsTheme pack;

  /// Whether this pack is the one currently applied.
  final bool isActive;

  /// Whether the row is focused by gamepad/keyboard navigation.
  final bool isFocused;

  /// Whether the row is selected (used by the wizard's list).
  final bool isSelected;

  /// Side length of the square mosaic.
  final double mosaicSize;

  /// Row tap (touch) handler.
  final VoidCallback? onTap;

  const SystemArtPackTile({
    super.key,
    required this.pack,
    this.isActive = false,
    this.isFocused = false,
    this.isSelected = false,
    this.mosaicSize = 56,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final highlighted = isFocused || isSelected;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 2.r),
        padding: EdgeInsets.all(6.r),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: highlighted
                ? primary
                : (isActive
                      ? Colors.greenAccent.withValues(alpha: 0.7)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.12)),
            width: highlighted ? 2.r : 1.r,
          ),
          boxShadow: highlighted
              ? [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.25),
                    blurRadius: 8.r,
                    spreadRadius: 1.r,
                  ),
                ]
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SystemArtPackMosaic(images: pack.mosaicImages, size: mosaicSize),
            SizedBox(width: 10.r),
            Expanded(child: _buildDetails(context, theme)),
            Icon(
              Symbols.chevron_right_rounded,
              size: 18.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context, ThemeData theme) {
    final onSurface = theme.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                pack.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontSize: 12.r,
                  fontWeight: FontWeight.bold,
                  color: onSurface,
                ),
              ),
            ),
            if (pack.isAi)
              Container(
                margin: EdgeInsets.only(left: 6.r),
                padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 1.r),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(999.r),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.r,
                  ),
                ),
                child: Text(
                  'AI',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 8.r,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            if (isActive)
              Padding(
                padding: EdgeInsets.only(left: 6.r),
                child: Icon(
                  Symbols.check_circle_rounded,
                  size: 15.r,
                  color: Colors.greenAccent,
                ),
              ),
          ],
        ),
        SizedBox(height: 2.r),
        Text(
          [
            if (pack.author.isNotEmpty)
              AppLocale.systemArtByAuthor
                  .getString(context)
                  .replaceAll('{author}', pack.author),
            if (pack.version.isNotEmpty)
              AppLocale.systemArtVersion
                  .getString(context)
                  .replaceAll('{version}', pack.version),
          ].join('  ·  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9.r,
            color: onSurface.withValues(alpha: 0.65),
          ),
        ),
        SizedBox(height: 4.r),
        Wrap(
          spacing: 5.r,
          runSpacing: 3.r,
          children: [
            if (pack.systemsCovered > 0)
              SystemArtPackChip(
                icon: Symbols.devices_rounded,
                label: AppLocale.systemArtSystemsCovered
                    .getString(context)
                    .replaceAll('{count}', '${pack.systemsCovered}'),
              ),
            if (pack.downloads > 0)
              SystemArtPackChip(
                icon: Symbols.download_rounded,
                label: AppLocale.systemArtDownloads
                    .getString(context)
                    .replaceAll('{count}', '${pack.downloads}'),
              ),
          ],
        ),
      ],
    );
  }
}

/// The square mosaic of up to four pack images (2x2). Public so the pack
/// detail dialog can render the same artwork.
class SystemArtPackMosaic extends StatelessWidget {
  final List<String> images;
  final double size;

  const SystemArtPackMosaic({
    super.key,
    required this.images,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (images.isEmpty) {
      return Container(
        width: size.r,
        height: size.r,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8.r),
        ),
        child: Center(
          child: Icon(
            Symbols.image_rounded,
            size: (size * 0.45).r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
        ),
      );
    }

    Widget cell(int index) {
      if (index >= images.length) {
        return Container(color: theme.colorScheme.surface);
      }
      return Image.network(
        images[index],
        fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : Container(color: theme.colorScheme.surface),
        errorBuilder: (_, _, _) => Container(color: theme.colorScheme.surface),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8.r),
      child: SizedBox(
        width: size.r,
        height: size.r,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: cell(0)),
                  SizedBox(width: 2.r),
                  Expanded(child: cell(1)),
                ],
              ),
            ),
            SizedBox(height: 2.r),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: cell(2)),
                  SizedBox(width: 2.r),
                  Expanded(child: cell(3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SystemArtPackChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const SystemArtPackChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 1.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11.r, color: color),
          SizedBox(width: 3.r),
          Text(
            label,
            style: TextStyle(fontSize: 8.r, color: color),
          ),
        ],
      ),
    );
  }
}
