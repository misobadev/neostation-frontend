import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_rom.dart';
import '../../providers/romm_provider.dart';
import '../../services/romm/romm_cover_image_provider.dart';
import '../../utils/cover_decode.dart';
import '../../widgets/romm_sync_banner.dart' show rommFormatBytes;

/// How a [RommRomCard] arranges itself. Mirrors the local library's view modes
/// so the remote browser offers the same three ways to read a list of games.
enum RommRomLayout {
  /// Artwork-forward tile with the name beneath — used by the ROM grid.
  grid,

  /// Full-width row: thumbnail, name, metadata lines and a download control.
  list,
}

/// A single ROM tile: cover art, name, and a download/progress/done control.
class RommRomCard extends StatefulWidget {
  final RommRom rom;
  final RommProvider provider;
  final List<String> romFolders;
  final bool isFocused;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onTap;
  final RommRomLayout layout;

  /// Logical size of the grid cell this card fills, so the cover can be
  /// decoded at exactly the size it is drawn. The grid already computes both,
  /// so it passes them rather than having every card measure itself; when
  /// absent the card measures its own constraints. Unused by the list layout,
  /// whose thumbnail is a fixed size.
  ///
  /// Both matter: the tile crops with [BoxFit.cover], so which axis bounds the
  /// decode depends on the box's shape (see `coverDecodeHint`).
  final double? tileWidth;
  final double? tileHeight;

  const RommRomCard({
    super.key,
    required this.rom,
    required this.provider,
    required this.romFolders,
    required this.isFocused,
    required this.onDownload,
    required this.onCancel,
    required this.onTap,
    this.layout = RommRomLayout.grid,
    this.tileWidth,
    this.tileHeight,
  });

  @override
  State<RommRomCard> createState() => RommRomCardState();
}

class RommRomCardState extends State<RommRomCard> {
  bool _alreadyDownloaded = false;

  /// Index into `RommService.tileCoverUrlCandidates` of the cover being drawn.
  /// A failed load advances it rather than settling for the placeholder: which
  /// of RomM's cover sources a given library populated is not knowable up
  /// front, and only the load can tell us the first one was a dead end.
  int _coverAttempt = 0;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
  }

  @override
  void didUpdateWidget(RommRomCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Grid tiles recycle across ROMs; the previous ROM's dead sources say
    // nothing about this one's.
    if (oldWidget.rom.id != widget.rom.id) _coverAttempt = 0;
  }

  Future<void> _checkDownloaded() async {
    final exists = await widget.provider.isDownloadedCached(
      widget.rom,
      widget.romFolders,
    );
    if (mounted && exists != _alreadyDownloaded) {
      setState(() => _alreadyDownloaded = exists);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Server thumbnail first: tiles are small, and RomM's cached small file is
    // the cheapest thing to fetch and decode.
    final covers = widget.provider.service.tileCoverUrlCandidates(widget.rom);
    // Skip sources already known to answer with nothing. `_coverAttempt` is
    // State, so a tile disposed by the grid's cache extent and scrolled back
    // to starts again at zero — without this it re-requests the same dead
    // URL on every scrollback, for the life of the library.
    var attempt = _coverAttempt;
    while (attempt < covers.length &&
        widget.provider.service.isDeadCover(covers[attempt])) {
      attempt++;
    }
    final coverUrl = attempt < covers.length ? covers[attempt] : null;
    final download = widget.provider.downloadFor(widget.rom.id);
    final scheme = theme.colorScheme;

    switch (widget.layout) {
      case RommRomLayout.list:
        return _buildListTile(theme, scheme, coverUrl, download);
      case RommRomLayout.grid:
        return _buildArtCard(theme, scheme, coverUrl, download);
    }
  }

  /// Bare artwork tile: the cover fills the cell, with the RetroAchievements
  /// badge and the download affordance floated over it.
  ///
  /// No name label — the grid names the focused ROM in its footer instead,
  /// matching the local game views (where the card is artwork only and the
  /// footer carries the title).
  Widget _buildArtCard(
    ThemeData theme,
    ColorScheme scheme,
    String? coverUrl,
    RommDownload? download,
  ) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        // No fill: the cover art is the tile's backdrop; a smaller radius
        // matches the artwork's rounded corners.
        decoration: rommFocusDecoration(
          scheme,
          widget.isFocused,
          radius: 8,
          fill: false,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6.r),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildTileCover(theme, coverUrl),
              if (widget.rom.hasRetroAchievements) _buildRaBadge(),
              _buildOverlay(theme, download),
            ],
          ),
        ),
      ),
    );
  }

  /// The art tile's cover at the cell size the grid handed us, or — when no
  /// size was given — at whatever the parent lays us out to.
  Widget _buildTileCover(ThemeData theme, String? coverUrl) {
    final width = widget.tileWidth;
    final height = widget.tileHeight;
    if (width != null) {
      return _buildCover(
        theme,
        coverUrl,
        logicalWidth: width,
        logicalHeight: height,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => _buildCover(
        theme,
        coverUrl,
        logicalWidth: constraints.hasBoundedWidth ? constraints.maxWidth : null,
        logicalHeight: constraints.hasBoundedHeight
            ? constraints.maxHeight
            : null,
      ),
    );
  }

  /// Full-width list row: square thumbnail (with RA badge) + name, and a compact
  /// trailing download control. Shares all download state with the grid card;
  /// only the arrangement differs, so the overlay is swapped for a right-hand
  /// control that reads clearly at row scale.
  Widget _buildListTile(
    ThemeData theme,
    ColorScheme scheme,
    String? coverUrl,
    RommDownload? download,
  ) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: rommFocusDecoration(scheme, widget.isFocused, radius: 8),
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
        child: Row(
          children: [
            // Fixed square thumbnail — a hard size avoids any intrinsic/aspect
            // sizing negotiation inside the Row.
            SizedBox(
              width: 72.r,
              height: 72.r,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.r),
                child: _buildCover(
                  theme,
                  coverUrl,
                  logicalWidth: 72.r,
                  logicalHeight: 72.r,
                ),
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nudge the title down so it doesn't sit flush with the
                  // thumbnail's top edge.
                  SizedBox(height: 4.r),
                  Text(
                    widget.rom.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.r,
                      fontWeight: widget.isFocused
                          ? FontWeight.w700
                          : FontWeight.w500,
                      // Keep the title high-contrast when focused: the focus fill
                      // is a primary tint, so primary-coloured text washes out —
                      // white reads cleanly over it.
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 3.r),
                  _buildListMeta(theme, scheme),
                  SizedBox(height: 2.r),
                  _buildListBottomLine(scheme, download),
                  SizedBox(height: 2.r),
                  _buildListSubtitle(scheme),
                ],
              ),
            ),
            SizedBox(width: 8.r),
            _buildListControl(theme, download),
          ],
        ),
      ),
    );
  }

  /// Secondary metadata line for the list layout: platform, RA progress, file
  /// size, and a multi-disc marker — the extra room a taller row buys us.
  Widget _buildListMeta(ThemeData theme, ColorScheme scheme) {
    final rom = widget.rom;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    final chips = <Widget>[];

    final platform = _platformLabel();
    if (platform != null) {
      chips.add(_metaChip(Symbols.videogame_asset_rounded, platform, muted));
    }

    if (rom.hasRetroAchievements) {
      final earned = widget.provider.raEarnedFor(rom);
      final label = earned != null
          ? '$earned/${rom.raTotalAchievements}'
          : '${rom.raTotalAchievements}';
      chips.add(
        _metaChip(
          Symbols.emoji_events_rounded,
          label,
          Colors.orangeAccent.withValues(alpha: earned != null ? 0.9 : 0.55),
        ),
      );
    }

    final size = _sizeLabel(rom.fsSizeBytes);
    if (size != null) {
      chips.add(_metaChip(null, size, muted));
    }

    if (rom.isMultiFile) {
      chips.add(_metaChip(Symbols.album_rounded, 'Multi', muted));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) SizedBox(width: 8.r),
          Flexible(fit: FlexFit.loose, child: chips[i]),
        ],
      ],
    );
  }

  /// Third metadata line: the actual ROM file name (region tags, revision,
  /// extension) — distinct from the cleaned display name above.
  Widget _buildListSubtitle(ColorScheme scheme) {
    final file = widget.rom.fsName;
    if (file.isEmpty) return const SizedBox.shrink();
    return Text(
      file,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 9.r,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface.withValues(alpha: 0.45),
      ),
    );
  }

  /// Fourth line: the ROM's genre when known — the right-hand control already
  /// conveys download state, so the genre is the more useful use of this line.
  /// While a download is in progress the live percentage takes over (the extra
  /// feedback is worth it), and when no genre is available the line falls back
  /// to the download-state chip so the row is never left blank.
  Widget _buildListBottomLine(ColorScheme scheme, RommDownload? download) {
    if (download != null && download.status == RommDownloadStatus.downloading) {
      final fraction = download.fraction;
      final pct = fraction != null
          ? ' ${(fraction * 100).clamp(0, 100).round()}%'
          : '';
      return _metaChip(
        Symbols.downloading_rounded,
        '${AppLocale.rommDownloading.getString(context)}$pct',
        scheme.primary,
      );
    }

    final genre = widget.rom.genre;
    if (genre != null && genre.isNotEmpty) {
      return _metaChip(
        Symbols.category_rounded,
        genre,
        scheme.onSurface.withValues(alpha: 0.6),
      );
    }

    final isDone =
        _alreadyDownloaded ||
        (download != null && download.status == RommDownloadStatus.completed);
    if (isDone) {
      return _metaChip(
        Symbols.check_circle_rounded,
        AppLocale.rommDownloaded.getString(context),
        Colors.greenAccent.withValues(alpha: 0.9),
      );
    }
    return _metaChip(
      Symbols.cloud_download_rounded,
      AppLocale.download.getString(context),
      scheme.onSurface.withValues(alpha: 0.5),
    );
  }

  /// A single icon+text metadata pill (icon optional).
  Widget _metaChip(IconData? icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12.r, color: color),
          SizedBox(width: 3.r),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.r,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  /// Human-readable platform name for this ROM, resolved from the loaded
  /// platform list (falls back to the upper-cased slug).
  String? _platformLabel() {
    final slug = widget.rom.platformSlug;
    if (slug.isEmpty) return null;
    for (final p in widget.provider.platforms) {
      if (p.slug == slug) return p.name;
    }
    return slug.toUpperCase();
  }

  /// Compact size label (e.g. "2.1 MB"); null when the size is unknown.
  String? _sizeLabel(int bytes) => bytes <= 0 ? null : rommFormatBytes(bytes);

  /// Compact trailing download control for the list layout: live progress +
  /// cancel while downloading, otherwise a download / done affordance.
  Widget _buildListControl(ThemeData theme, RommDownload? download) {
    final scheme = theme.colorScheme;
    if (download != null && download.status == RommDownloadStatus.downloading) {
      final fraction = download.fraction;
      return GestureDetector(
        onTap: widget.onCancel,
        child: SizedBox(
          width: 30.r,
          height: 30.r,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  strokeWidth: 3.r,
                  value: fraction,
                  color: scheme.primary,
                ),
              ),
              Icon(Symbols.close_rounded, size: 14.r, color: scheme.onSurface),
            ],
          ),
        ),
      );
    }

    final isDone =
        _alreadyDownloaded ||
        (download != null && download.status == RommDownloadStatus.completed);
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: 34.r, height: 34.r),
      iconSize: 22.r,
      onPressed: isDone
          ? null
          : () {
              widget.onDownload();
              // Re-check presence shortly after a completed download.
              Future.delayed(const Duration(seconds: 1), _checkDownloaded);
            },
      icon: Icon(
        isDone ? Symbols.check_circle_rounded : Symbols.download_rounded,
        color: isDone ? Colors.greenAccent : scheme.onSurface,
      ),
    );
  }

  /// Advances past the candidate that just failed, on the next frame —
  /// `errorBuilder` runs *during* build, where `setState` is illegal. Guarded
  /// on the attempt that failed so repeated error frames for the same source
  /// only skip it once.
  ///
  /// This moves [_coverAttempt] on by one rather than to the index actually
  /// drawn, which can be further along when the skip loop in [build] stepped
  /// over dead sources. That still converges: an absent cover is recorded in
  /// the service's dead-cover set before the error frame, so the next build's
  /// skip loop walks past it and every other known-dead entry in one go.
  void _tryNextCover() {
    final failed = _coverAttempt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _coverAttempt != failed) return;
      setState(() => _coverAttempt = failed + 1);
    });
  }

  /// The cover for [coverUrl], decoded no larger than the
  /// [logicalWidth] x [logicalHeight] box needs on this display and cropped
  /// (never letterboxed) to it.
  ///
  /// A decode hint makes Flutter wrap the provider in a `ResizeImage`, which
  /// both bounds decode memory and keys the `ImageCache` by size — so the grid
  /// and list each keep their own right-sized entry. Which of `cacheWidth` /
  /// `cacheHeight` carries it is `coverDecodeHint`'s call: under [BoxFit.cover]
  /// the axis that bounds the paint depends on the box's shape, and hinting
  /// the wrong one caps an off-ratio cover below the size it is drawn at.
  /// `gaplessPlayback` keeps the previous cover painted while a recycled tile
  /// loads its new one, instead of flashing the placeholder on every scroll.
  /// Nothing is written to disk: the `ImageCache` is the only cache.
  Widget _buildCover(
    ThemeData theme,
    String? coverUrl, {
    required double? logicalWidth,
    double? logicalHeight,
  }) {
    if (coverUrl == null) {
      return _coverPlaceholder(theme);
    }
    final hint = coverDecodeHint(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    // The placeholder sits *under* the image rather than in a loadingBuilder:
    // a loadingBuilder replaces the retained frame with the placeholder for
    // the whole download, which is exactly the flash gaplessPlayback exists
    // to avoid. An image with nothing decoded yet paints nothing, so the
    // placeholder shows through until the first frame and the previous cover
    // stays on top while a recycled tile re-decodes.
    return Stack(
      fit: StackFit.expand,
      children: [
        _coverPlaceholder(theme),
        Image(
          image: _coverProvider(coverUrl, hint),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) {
            _tryNextCover();
            return _coverPlaceholder(theme);
          },
        ),
      ],
    );
  }

  /// The provider for [coverUrl], decoded no wider than the tile needs.
  ///
  /// [RommCoverImage] rather than `NetworkImage` so the fetch goes through
  /// [RommService]'s client under a concurrency bound. `NetworkImage` runs on
  /// Flutter's own process-wide `HttpClient` with no per-host connection
  /// limit, so a screenful of tiles opened a socket each and starved the
  /// request fetching the next page of games on the same host.
  ///
  /// [ResizeImage] is what `Image.network`'s `cacheWidth` does internally, so
  /// the decode bound and the size-keyed `ImageCache` entry are unchanged — an
  /// unknown width (unbounded parent) skips the hint rather than decoding to a
  /// one-pixel bitmap, exactly as before.
  ImageProvider _coverProvider(
    String coverUrl,
    ({int? cacheWidth, int? cacheHeight}) hint,
  ) {
    final provider = RommCoverImage(coverUrl, widget.provider.service);
    if (hint.cacheWidth == null && hint.cacheHeight == null) return provider;
    return ResizeImage(
      provider,
      width: hint.cacheWidth,
      height: hint.cacheHeight,
    );
  }

  Widget _coverPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      child: Center(
        child: Icon(
          Symbols.videogame_asset_rounded,
          size: 28.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    );
  }

  /// Top-left badge showing the ROM has RetroAchievements and, when RomM has
  /// synced the user's progression, their earned/total count. The download
  /// badge owns the bottom-right corner, so this sits top-left.
  Widget _buildRaBadge() {
    final rom = widget.rom;
    final earned = widget.provider.raEarnedFor(rom);
    final total = rom.raTotalAchievements;
    final hasProgress = earned != null;
    final label = hasProgress ? '$earned/$total' : '$total';

    return Positioned.fill(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: Semantics(
            label: hasProgress
                ? 'RetroAchievements: $earned of $total earned'
                : 'RetroAchievements: $total achievements',
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 3.r),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.emoji_events_rounded,
                    size: 14.r,
                    // Dim the trophy when progress isn't synced.
                    color: Colors.orangeAccent.withValues(
                      alpha: hasProgress ? 1.0 : 0.6,
                    ),
                  ),
                  SizedBox(width: 3.r),
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10.r,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(ThemeData theme, RommDownload? download) {
    // Active download: prominent, unambiguous progress + cancel affordance.
    if (download != null && download.status == RommDownloadStatus.downloading) {
      final fraction = download.fraction;
      final pctLabel = fraction != null
          ? '${(fraction * 100).clamp(0, 100).round()}%'
          : null;
      return GestureDetector(
        onTap: widget.onCancel,
        child: Container(
          color: Colors.black.withValues(alpha: 0.72),
          padding: EdgeInsets.symmetric(horizontal: 4.r),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Spinner with the live percentage stacked in its centre.
                SizedBox(
                  width: 34.r,
                  height: 34.r,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          strokeWidth: 3.r,
                          value: fraction,
                          color: theme.colorScheme.primary,
                          backgroundColor: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                      if (pctLabel != null)
                        Text(
                          pctLabel,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 6.r),
                Text(
                  AppLocale.rommDownloading.getString(context),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 5.r),
                // Explicit cancel chip so it's obvious a press stops the download.
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  child: Text(
                    AppLocale.cancel.getString(context),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isDone =
        _alreadyDownloaded ||
        (download != null && download.status == RommDownloadStatus.completed);

    return Positioned.fill(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: GestureDetector(
            onTap: isDone
                ? null
                : () {
                    widget.onDownload();
                    // Re-check presence shortly after a completed download.
                    Future.delayed(
                      const Duration(seconds: 1),
                      _checkDownloaded,
                    );
                  },
            child: Container(
              padding: EdgeInsets.all(5.r),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDone
                    ? Symbols.check_circle_rounded
                    : Symbols.download_rounded,
                size: 18.r,
                color: isDone ? Colors.greenAccent : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared focus/selection decoration for RomM browse tiles: a subtle primary
/// fill (list tiles), a primary border, and a soft primary glow when focused.
///
/// [radius] and [fill] are the only per-tile variations: image tiles (ROM
/// cards) pass `fill: false` so the cover art shows through, with a tighter
/// [radius] to match the artwork's corners.
BoxDecoration rommFocusDecoration(
  ColorScheme scheme,
  bool isFocused, {
  double radius = 12,
  bool fill = true,
}) {
  return BoxDecoration(
    color: fill
        ? (isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5))
        : null,
    borderRadius: BorderRadius.circular(radius.r),
    border: Border.all(
      color: isFocused ? scheme.primary : Colors.transparent,
      width: 2.r,
    ),
    boxShadow: isFocused
        ? [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.3),
              blurRadius: 8.r,
              spreadRadius: 1.r,
            ),
          ]
        : null,
  );
}
