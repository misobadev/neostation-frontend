import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/selection_grid/selection_grid_geometry.dart';

/// Builds the widget for the item at [index]; [cellSize] is the card's
/// resolved size from the grid geometry.
typedef SelectionGridItemBuilder = Widget Function(
  BuildContext context,
  int index,
  Size cellSize,
);

/// A virtualized, row-major grid with an animated selection highlight that is
/// aligned with the cards **by construction**.
///
/// Unlike ad-hoc grids that overlay the selector on top of a scroll view with
/// manually duplicated padding constants and runtime scroll-offset
/// compensation, here the cards AND the highlight are `Positioned` inside the
/// same scrollable `Stack`, both placed from the same [SelectionGridGeometry]
/// rectangles. They share one coordinate space, so they cannot drift apart —
/// not on density changes, style switches, resizes, or scrolls.
///
/// Scrolling to keep the selection centered is automatic: whenever
/// [selectedIndex] or [geometry] changes, the grid animates the viewport to
/// the selected card. Cards are built lazily — only the rows intersecting the
/// viewport (plus a small buffer) are inflated, so the grid scales to
/// thousands of items.
class SelectionGrid extends StatefulWidget {
  /// Layout snapshot shared by cards and highlight. Treat as immutable;
  /// pass a freshly computed instance to re-layout (the highlight then jumps
  /// instead of animating when [highlightKey] also changes).
  final SelectionGridGeometry geometry;

  /// Empty space around the grid content (applies to the scroll view, so the
  /// content coordinate space starts at the padded origin).
  final EdgeInsets padding;

  final int selectedIndex;

  /// Shortens highlight/scroll animations while the user navigates quickly.
  final bool isNavigatingFast;

  /// Bump this key when the layout changes discontinuously (e.g. column
  /// count or card style) so the highlight re-creates instead of animating
  /// across the jump.
  final Key? highlightKey;

  final SelectionGridItemBuilder itemBuilder;

  /// Monotonic counter the parent bumps whenever card *content* (not
  /// selection) changes — e.g. scrape progress, favorite toggles, or a games
  /// list swap. Cached card widgets are rebuilt when this changes; leaving it
  /// at its default means a selection move alone never rebuilds cards.
  final int revision;

  /// Optional custom visuals for the selection highlight. Defaults to the
  /// standard primary-gradient frame used across the app.
  final WidgetBuilder? highlightBuilder;

  const SelectionGrid({
    super.key,
    required this.geometry,
    required this.padding,
    required this.selectedIndex,
    required this.itemBuilder,
    this.revision = 0,
    this.isNavigatingFast = false,
    this.highlightKey,
    this.highlightBuilder,
  });

  @override
  State<SelectionGrid> createState() => SelectionGridState();
}

class SelectionGridState extends State<SelectionGrid> {
  final ScrollController _scrollController = ScrollController();

  /// Currently inflated row range (inclusive). Buffer rows are included.
  int _firstRow = 0;
  int _lastRow = -1;

  static const int _rowBuffer = 4;

  // ---- Card cell cache (per index) ----
  // Cards are cached individually by item index and the *same widget instance*
  // is reused across rebuilds. Two payoffs:
  //   1. A selection move (range unchanged) rebuilds no cards — only the
  //      highlight repositions, like the pre-#188 scroll-driven overlay.
  //   2. When the scroll animation shifts the visible window by a row, only
  //      the newly-entered indices are built; the rest are reused. This is the
  //      key win — the old list cache rebuilt the *entire* window on every
  //      shift (~70 cards → measured 20–28ms build frames), whereas building
  //      one new row is a handful of cards.
  // Passing identical instances lets Flutter skip diffing those subtrees.
  final Map<int, Widget> _cellCache = {};
  SelectionGridGeometry? _cacheGeometry;
  int _cacheEpoch = -1;
  int _cacheRevision = -1;

  /// Extra indices kept warm on each side of the visible window so scrolling
  /// back a little reuses cells instead of rebuilding them.
  static const int _cacheMargin = 60;

  /// Bumped when an inherited dependency (theme, media query, …) changes, so
  /// cached card widgets — which capture theme-derived values — are rebuilt.
  int _depEpoch = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _depEpoch++;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncVisibleRange);
    // Until the first layout reports a viewport, inflate the first page plus
    // the selected row so the initial frame is complete.
    _firstRow = 0;
    _lastRow = _rowBuffer;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncVisibleRange();
      _ensureSelectedVisible();
    });
  }

  @override
  void didUpdateWidget(SelectionGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.geometry != widget.geometry ||
        oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncVisibleRange();
        _ensureSelectedVisible();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncVisibleRange);
    _scrollController.dispose();
    super.dispose();
  }

  /// Recomputes the inflated row range from the live scroll offset.
  /// Only triggers a rebuild when the range actually changes.
  void _syncVisibleRange() {
    if (!mounted || !_scrollController.hasClients) return;
    final rows = widget.geometry.rows;
    if (rows.isEmpty) return;

    final startY = _scrollController.offset;
    final endY = startY + _scrollController.position.viewportDimension;

    // Rows are sorted by vertical position, so binary-search the visible
    // window instead of scanning every row on each scroll frame (a large
    // library can have thousands of rows).
    int first = _firstRowAtOrBelow(rows, startY);
    int last = _lastRowAbove(rows, endY, first);

    first = (first - _rowBuffer).clamp(0, rows.length - 1);
    last = (last + _rowBuffer).clamp(first, rows.length - 1);

    if (first != _firstRow || last != _lastRow) {
      setState(() {
        _firstRow = first;
        _lastRow = last;
      });
    }
  }

  /// First row whose bottom edge is at or below [y] (i.e. still visible).
  static int _firstRowAtOrBelow(List<GridRowInfo> rows, double y) {
    int lo = 0, hi = rows.length - 1, result = rows.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].bottom >= y) {
        result = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return result;
  }

  /// Last row whose top edge is at or above [y], searching from [from].
  static int _lastRowAbove(List<GridRowInfo> rows, double y, int from) {
    int lo = from, hi = rows.length - 1, result = rows.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].top > y) {
        result = mid - 1;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return result.clamp(from, rows.length - 1);
  }

  /// Animates the viewport so the selected card sits centered.
  void _ensureSelectedVisible() {
    if (!_scrollController.hasClients) return;
    final rect = widget.geometry.rectFor(widget.selectedIndex);
    final position = _scrollController.position;
    final viewportH = position.viewportDimension;
    final target = (rect.top - viewportH / 2 + rect.height / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: Duration(milliseconds: widget.isNavigatingFast ? 220 : 500),
      curve: Curves.easeOutQuart,
    );
  }

  @override
  Widget build(BuildContext context) {
    final geometry = widget.geometry;
    final rows = geometry.rows;

    final children = <Widget>[];

    if (rows.isNotEmpty) {
      // Defensive clamp: the geometry may have been replaced with fewer rows
      // before the post-frame range sync had a chance to run.
      var first = _firstRow.clamp(0, rows.length - 1);
      var last = _lastRow.clamp(first, rows.length - 1);
      // Always keep the selected card inflated so tap/scroll animations never
      // reference a card that hasn't been built.
      final selectedRow = (widget.selectedIndex ~/ geometry.columns).clamp(
        0,
        rows.length - 1,
      );
      if (selectedRow < first) first = selectedRow;
      if (selectedRow > last) last = selectedRow;

      // Drop the whole cache when something that affects *card content* (not
      // selection or scroll position) changed: a new geometry (rects moved),
      // a revision bump (scrape/favorite/games swap), or an inherited
      // dependency (theme). Otherwise cells survive across rebuilds.
      if (!identical(_cacheGeometry, geometry) ||
          _cacheEpoch != _depEpoch ||
          _cacheRevision != widget.revision) {
        _cellCache.clear();
        _cacheGeometry = geometry;
        _cacheEpoch = _depEpoch;
        _cacheRevision = widget.revision;
      }

      // Build only indices not already cached; reuse the rest by identity so a
      // one-row window shift builds one row of cards, not the whole window.
      final firstIndex = rows[first].startIndex;
      final lastRow = rows[last];
      final lastIndex = lastRow.startIndex + lastRow.count - 1;

      for (int index = firstIndex; index <= lastIndex; index++) {
        final cell = _cellCache[index] ??= () {
          final rect = geometry.cardRects[index];
          return Positioned(
            key: ValueKey('selection_grid_cell_$index'),
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: widget.itemBuilder(
              context,
              index,
              Size(rect.width, rect.height),
            ),
          );
        }();
        children.add(cell);
      }

      // Evict cells well outside the visible window to bound memory during a
      // long scroll (kept generous so small back-scrolls still hit the cache).
      if (_cellCache.length > (lastIndex - firstIndex + 1) + 4 * _cacheMargin) {
        final keepFrom = firstIndex - _cacheMargin;
        final keepTo = lastIndex + _cacheMargin;
        _cellCache.removeWhere((i, _) => i < keepFrom || i > keepTo);
      }
    }

    // Selection highlight — same content coordinate space as the cards.
    // Inset by the card's own outer padding (2.r per side) so the frame
    // traces the visible card surface, not the grid cell.
    final selRect = geometry.rectFor(widget.selectedIndex);
    children.add(
      AnimatedPositioned(
        key: widget.highlightKey,
        duration: Duration(milliseconds: widget.isNavigatingFast ? 120 : 300),
        curve: Curves.easeOutQuart,
        left: selRect.left + 2.r,
        top: selRect.top + 2.r,
        width: selRect.width - 4.r,
        height: selRect.height - 4.r,
        child: IgnorePointer(
          child:
              widget.highlightBuilder?.call(context) ??
              _buildDefaultHighlight(context),
        ),
      ),
    );

    return SingleChildScrollView(
      controller: _scrollController,
      padding: widget.padding,
      child: SizedBox(
        width: geometry.contentWidth,
        height: geometry.totalHeight,
        child: Stack(children: children),
      ),
    );
  }

  Widget _buildDefaultHighlight(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
            BorderRadius.circular(14.r),
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.28),
            theme.colorScheme.primary.withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const [0.0, 0.35, 1.0],
        ),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.55),
          width: 2.r,
        ),
      ),
    );
  }
}
