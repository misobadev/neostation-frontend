import 'dart:math' as math;

import 'package:flutter/material.dart';

enum CarouselPageChangeReason { manual, controller }

/// How off-centre pages shrink and fade with distance from the centred card.
///
/// The defaults suit a carousel that fits ~2 pages across the viewport (the
/// games carousel): the neighbours are already half off-screen, so a steep
/// falloff reads as depth. A carousel that fits more pages — the systems
/// carousel gets ~3.6 — needs the floors raised, otherwise everything past the
/// immediate neighbours has collapsed to a dim sliver before it reaches the
/// screen edge.
class CarouselDepth {
  const CarouselDepth({
    this.scaleFalloff = 0.4,
    this.minScale = 0.25,
    this.opacityBase = 0.6,
    this.opacityFalloff = 1.0,
    this.minOpacity = 0.1,
    this.edgePull = 0.0,
  });

  /// Scale lost per page of distance, and the size distant cards settle at.
  final double scaleFalloff;
  final double minScale;

  /// Opacity at the centre, lost per page of distance, and the floor.
  final double opacityBase;
  final double opacityFalloff;
  final double minOpacity;

  /// How far the outer cards are drawn back toward the centre, as a fraction
  /// of the page pitch.
  ///
  /// The pitch is the card width, so a shrunk card leaves a gap proportional
  /// to how much it shrank — the outermost cards drift away from the pack
  /// exactly where they can least afford the room. This pulls them back
  /// (purely visual; scroll positions and snapping are untouched). It ramps in
  /// past the immediate neighbours and caps one page later, so the centre and
  /// its two neighbours keep their spacing and the cards beyond the edge stay
  /// off-screen instead of piling up.
  final double edgePull;
}

/// Page-snapping physics that lets a fling carry across many cards.
///
/// [PageScrollPhysics] — what [PageView] applies when `pageSnapping` is on —
/// deliberately caps a swipe at one page, so a hard fling through a 9,000-game
/// library still advances a single card. This instead lets the normal friction
/// simulation run to wherever momentum would carry it, then settles on the
/// nearest card. Requires `pageSnapping: false` so [PageScrollPhysics] is not
/// layered back on top and re-imposes the one-page cap.
class _FlingPageScrollPhysics extends ScrollPhysics {
  const _FlingPageScrollPhysics({required this.viewportFraction, super.parent});

  final double viewportFraction;

  @override
  _FlingPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _FlingPageScrollPhysics(
        viewportFraction: viewportFraction,
        parent: buildParent(ancestor),
      );

  double _pageExtent(ScrollMetrics position) =>
      math.max(1.0, position.viewportDimension * viewportFraction);

  double _snapTarget(ScrollMetrics position, double pixels) {
    final extent = _pageExtent(position);
    final page = (pixels / extent).roundToDouble();
    return (page * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // Out of range (overscroll): let the parent spring it back.
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }

    // Where unrestricted momentum would come to rest, snapped to a card.
    final friction = super.createBallisticSimulation(position, velocity);
    final settleAt = friction?.x(double.infinity) ?? position.pixels;
    final target = _snapTarget(position, settleAt);

    final tolerance = toleranceFor(position);
    if ((target - position.pixels).abs() < tolerance.distance) return null;

    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

class NativeCarousel extends StatefulWidget {
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final void Function(int index, CarouselPageChangeReason reason)?
  onPageChanged;
  final ValueChanged<double>? onPageScrolled;
  final int initialIndex;

  /// When non-null, each page is sized so the card can keep its natural
  /// square artwork plus this footer height below it (width = height - footerHeight).
  /// This makes the carousel page match the aspect ratio used by SystemCard in
  /// the grid, where the footer is rendered under the artwork.
  final double? footerHeight;

  /// Shrink/fade envelope applied to off-centre pages.
  final CarouselDepth depth;

  /// Whether stepping past either end continues from the other.
  ///
  /// Off by default, which is what the systems carousel wants: it is a short
  /// row the user reads as a row, and running off the end of it is information.
  /// The games carousel is the opposite — thousands of pages with no readable
  /// end — so reaching the last card and having the D-pad do nothing is just a
  /// dead press.
  final bool wrap;

  const NativeCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.onPageScrolled,
    this.initialIndex = 0,
    this.footerHeight,
    this.depth = const CarouselDepth(),
    this.wrap = false,
  });

  @override
  State<NativeCarousel> createState() => NativeCarouselState();
}

class NativeCarouselState extends State<NativeCarousel> {
  PageController? _pageController;
  int _currentIndex = 0;
  double _lastVpFraction = 0;
  int _lastReportedIndex = 0;
  final ValueNotifier<double> _pageNotifier = ValueNotifier(0.0);

  /// True while a controller-driven page animation is running. Gates pointer
  /// input so a stray touch cannot cancel the animation mid-flight.
  final ValueNotifier<bool> _animating = ValueNotifier(false);

  /// Whether a finger is currently on the carousel. A gesture in progress
  /// always outranks the input gate.
  bool _pointerDown = false;

  /// The page a controller-driven move is heading for, or null when the scroll
  /// position is the source of truth (at rest, or while a finger owns it).
  ///
  /// A D-pad step publishes its destination as the move *starts* rather than
  /// when the 260ms slide lands, so an A press 30ms later acts on the card the
  /// user is looking at instead of the one the carousel has not finished
  /// leaving. The frames the slide travels through are travel, not selection,
  /// so [_onPageScroll] stops deriving an index while this is set — otherwise
  /// `page.round()` would drag the selection back to the card behind.
  int? _targetIndex;

  /// Identifies the in-flight controller move. Each new step supersedes the
  /// last, and an interrupted [PageController.animateToPage] still completes
  /// its future — without this, the move that was cut short would clear its
  /// successor's target and lift the successor's input gate.
  int _moveToken = 0;
  CarouselPageChangeReason _pageChangeReason =
      CarouselPageChangeReason.controller;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _lastReportedIndex = widget.initialIndex;
    _pageNotifier.value = widget.initialIndex.toDouble();
  }

  @override
  void didUpdateWidget(NativeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != oldWidget.initialIndex &&
        widget.initialIndex != _currentIndex &&
        _pageController != null) {
      // Reconciling with the parent, not acting on a discrete user input. A
      // fling outruns the parent's index, so this fires mid-swipe — gating
      // input here would kill the gesture the user is still performing.
      // Also not a moment to call back into the parent: didUpdateWidget runs
      // inside its build, and the index being adopted is the parent's own.
      _animateToPage(widget.initialIndex, gateInput: false, notify: false);
    }
  }

  @override
  void dispose() {
    _pageController?.removeListener(_onPageScroll);
    _pageController?.dispose();
    _pageNotifier.dispose();
    _animating.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final page = _pageController?.page;
    if (page == null) return;

    _pageNotifier.value = page;
    // Still reported mid-move: this drives the indicator cursor, which tracks
    // the cards continuously rather than per selection.
    widget.onPageScrolled?.call(page);

    // A controller move has already published where it is going; the pages it
    // slides through are not selections the user made.
    if (_targetIndex != null) return;

    _currentIndex = page.round();
    if (_currentIndex != _lastReportedIndex) {
      final dist = (page - _currentIndex).abs();
      if (dist < 0.05) {
        _lastReportedIndex = _currentIndex;
        final reason = _pageChangeReason;
        _pageChangeReason = CarouselPageChangeReason.controller;
        widget.onPageChanged?.call(_currentIndex, reason);
      }
    }
  }

  void _ensureController(double vpFraction) {
    if (_pageController == null || vpFraction != _lastVpFraction) {
      _pageController?.removeListener(_onPageScroll);
      _pageController?.dispose();
      _lastVpFraction = vpFraction;
      _pageController = PageController(
        viewportFraction: vpFraction,
        initialPage: _currentIndex,
      );
      _pageController!.addListener(_onPageScroll);
      _lastReportedIndex = _currentIndex;
    }
  }

  void nextPage() {
    if (_currentIndex < widget.itemCount - 1) {
      _animateToPage(_currentIndex + 1);
    } else if (_canWrap) {
      _wrapToPage(0);
    }
  }

  void previousPage() {
    if (_currentIndex > 0) {
      _animateToPage(_currentIndex - 1);
    } else if (_canWrap) {
      _wrapToPage(widget.itemCount - 1);
    }
  }

  /// A single-page carousel has no other end to arrive at, and wrapping it
  /// would fire a page change that does not move.
  bool get _canWrap => widget.wrap && widget.itemCount > 1;

  /// The wrap itself, and it is deliberately a jump.
  ///
  /// [_animateToPage] walks the scroll position through every page between here
  /// and the target, so wrapping the far end of a 9,000-game library would
  /// scroll the entire library past the viewport at animation speed. The letter
  /// jump has the same problem and solves it the same way.
  void _wrapToPage(int index) => _jumpToPage(index);

  /// Adopts [index] as the selection the instant a controller move starts, so
  /// a button press landing mid-slide reads the card the user is looking at.
  void _openMove(int index, {bool notify = true}) {
    _pageChangeReason = CarouselPageChangeReason.controller;
    _targetIndex = index;
    _currentIndex = index;
    if (_lastReportedIndex == index) return;
    _lastReportedIndex = index;
    if (notify) {
      widget.onPageChanged?.call(index, CarouselPageChangeReason.controller);
    }
  }

  void _animateToPage(int index, {bool gateInput = true, bool notify = true}) {
    _openMove(index, notify: notify);
    final token = ++_moveToken;
    // Never gate while a finger is on the glass: the user is mid-gesture and
    // owns the carousel until they lift it.
    if (gateInput && !_pointerDown) _animating.value = true;
    _pageController
        ?.animateToPage(
          index,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutQuart,
        )
        // Completing or being interrupted both end the move, so this is where
        // the input gate lifts — unless a newer step has already taken over,
        // which owns the gate and the target from here.
        .whenComplete(() {
          if (!mounted || token != _moveToken) return;
          _animating.value = false;
          _targetIndex = null;
        });
  }

  void jumpToPage(int index) => _jumpToPage(index);

  /// A jump arrives immediately, so it opens and closes its move in one go.
  ///
  /// It also supersedes any slide still in flight — a letter jump fired during
  /// a held D-pad step is exactly that — which means taking over the move token
  /// and lowering the input gate the abandoned slide will no longer lower.
  void _jumpToPage(int index) {
    _openMove(index);
    _moveToken++;
    _animating.value = false;
    _pageController?.jumpToPage(index);
    _targetIndex = null;
  }

  void animateToPage(int index) {
    if (index >= 0 && index < widget.itemCount) {
      _animateToPage(index);
    }
  }

  int get currentIndex => _currentIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;

        final double pageWidth;
        final double pageAspectRatio;
        if (widget.footerHeight != null && widget.footerHeight! > 0) {
          // Match the grid's SystemCard aspect ratio: square artwork plus a
          // footer row below it (page width = page height - footer height).
          pageWidth = (maxHeight - widget.footerHeight!).clamp(0.0, maxHeight);
          pageAspectRatio = maxHeight > 0 ? pageWidth / maxHeight : 1.0;
        } else {
          // Default: square pages that fill the available height.
          pageWidth = maxHeight;
          pageAspectRatio = 1.0;
        }

        final vpFraction = (availableWidth > 0)
            ? (pageWidth / availableWidth).clamp(0.18, 1.0)
            : 0.3;

        _ensureController(vpFraction);

        return SizedBox(
          height: maxHeight,
          // While a page animation is in flight the carousel takes no pointers
          // at all. A touch anywhere on it — including the gaps between cards —
          // otherwise holds the scroll position and cancels the animation
          // part-way, stranding the selection. Held as the builder's `child` so
          // arming/disarming never rebuilds the PageView subtree.
          child: ValueListenableBuilder<bool>(
            valueListenable: _animating,
            builder: (context, animating, child) =>
                IgnorePointer(ignoring: animating, child: child),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _pointerDown = true;
                _pageChangeReason = CarouselPageChangeReason.manual;
                // A finger outranks an ungated move in flight (the parent
                // reconciling its index is the one that is not gated): the
                // scroll position is the source of truth again from here.
                _targetIndex = null;
              },
              onPointerUp: (_) => _pointerDown = false,
              onPointerCancel: (_) => _pointerDown = false,
              child: PageView.builder(
                // A new page pitch is a new scroll geometry. Swapping the
                // controller alone reuses the scroll position, which goes on
                // mapping pages to pixels at the old pitch: the centred card
                // sits off-centre, and every later jump lands on the stale
                // mapping, so the error rides along with the selection instead
                // of washing out. Keying on the fraction retires the position
                // with it, and the replacement is seeded at the current page.
                key: ValueKey<double>(vpFraction),
                controller: _pageController,
                clipBehavior: Clip.none,
                padEnds: true,
                allowImplicitScrolling: true,
                // Snapping is handled by the physics below; leaving it on would
                // layer PageScrollPhysics back over them and restore the
                // one-card-per-swipe cap.
                pageSnapping: false,
                physics: _FlingPageScrollPhysics(viewportFraction: vpFraction),
                itemCount: widget.itemCount,
                itemBuilder: (context, index) {
                  // Build the card exactly once and pass it as the
                  // ValueListenableBuilder's `child`. Only the cheap
                  // Opacity/Transform.scale envelope reacts to per-frame page
                  // scroll updates — the card subtree (which does disk reads and
                  // Image.file decoding) is NOT rebuilt on every scroll frame.
                  // RepaintBoundary lets the card's raster be cached and reused
                  // as the scale/opacity animate.
                  final card = RepaintBoundary(
                    child: AspectRatio(
                      aspectRatio: pageAspectRatio,
                      child: widget.itemBuilder(context, index),
                    ),
                  );
                  return ValueListenableBuilder<double>(
                    valueListenable: _pageNotifier,
                    child: card,
                    builder: (context, page, child) {
                      final distance = (index - page).abs() - 0.6;
                      final depth = widget.depth;
                      final scale = (1.0 - distance * depth.scaleFalloff).clamp(
                        depth.minScale,
                        1.0,
                      );
                      final opacity =
                          (depth.opacityBase - distance * depth.opacityFalloff)
                              .clamp(depth.minOpacity, 1.0);
                      // Ramps in from the neighbours (distance 0.4 at rest) and
                      // caps a page later, then signed toward the centre.
                      final pull = depth.edgePull == 0.0
                          ? 0.0
                          : (distance - 0.4).clamp(0.0, 1.0) *
                                depth.edgePull *
                                pageWidth *
                                (page - index).sign;

                      return Opacity(
                        opacity: opacity,
                        child: Transform.translate(
                          offset: Offset(pull, 0),
                          child: Transform.scale(
                            scale: scale,
                            alignment: Alignment.center,
                            child: child,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
