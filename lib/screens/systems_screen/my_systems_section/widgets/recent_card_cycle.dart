import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/providers/recent_games_cycler.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';

import '../system_card.dart';

/// The systems screen's recent card, sliding between the recently played games
/// [RecentGamesCycler] steps through, with a dot per game beneath the artwork.
///
/// Wraps the card rather than living inside [SystemCard] because the slide
/// needs the outgoing and incoming games on screen at once, and a card's state
/// (its cached wheel art) belongs to one game. [gameKey] identifies the game
/// [card] shows, so a new key is what starts a slide.
///
/// Besides LT/RT, which the host binds while the card is focused, the card
/// moves by touch: a horizontal swipe across it (when [swipeEnabled]), or a tap
/// on the LT/RT glyphs at either end of the dots.
///
/// With fewer than two games, or no cycler above it, this is just [card].
class RecentCardCycle extends StatefulWidget {
  const RecentCardCycle({
    super.key,
    required this.gameKey,
    required this.card,
    this.swipeEnabled = true,
  });

  final String? gameKey;
  final Widget card;

  /// Whether a horizontal swipe across the card moves it. The carousel turns
  /// it off while the card is off centre, so a swipe that starts on it still
  /// scrolls the carousel.
  final bool swipeEnabled;

  @override
  State<RecentCardCycle> createState() => _RecentCardCycleState();
}

class _RecentCardCycleState extends State<RecentCardCycle> {
  static const Duration _slideDuration = Duration(milliseconds: 350);

  /// A swipe this fast moves the card however short it was.
  static const double _flingVelocity = 300;

  /// Horizontal distance accumulated by the current drag.
  double _dragDx = 0;

  void _step(RecentGamesCycler cycler, int delta) {
    SfxService().playNavSound();
    cycler.step(delta);
  }

  void _onDragEnd(RecentGamesCycler cycler, DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = _dragDx;
    _dragDx = 0;
    // A slow drag counts once it has crossed a fifth of the card.
    final width = context.size?.width ?? 0;
    final far = width > 0 && dx.abs() > width / 5;
    if (velocity.abs() < _flingVelocity && !far) return;
    final towardStart = velocity.abs() >= _flingVelocity
        ? velocity < 0
        : dx < 0;
    // Dragging toward the start (left) brings in the next game from the
    // right, like RT.
    _step(cycler, towardStart ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    final cycler = context.watch<RecentGamesCycler?>();
    if (cycler == null || cycler.count < 2) return widget.card;
    final direction = cycler.direction.toDouble();
    final gameKey = widget.gameKey;

    Widget slides = ClipRect(
      child: AnimatedSwitcher(
        duration: _slideDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        // Both cards fill the slot; the default centres them loosely.
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.passthrough, children: [...previous, ?current]),
        // The incoming card enters from the side the user moved toward
        // and the outgoing one leaves by the other. The outgoing card runs
        // its animation in reverse, so its tween ends where it started.
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(gameKey);
          return SlideTransition(
            position: Tween<Offset>(
              begin: Offset(incoming ? direction : -direction, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          );
        },
        child: KeyedSubtree(key: ValueKey(gameKey), child: widget.card),
      ),
    );
    if (widget.swipeEnabled) {
      slides = GestureDetector(
        onHorizontalDragStart: (_) => _dragDx = 0,
        onHorizontalDragUpdate: (d) => _dragDx += d.primaryDelta ?? 0,
        onHorizontalDragEnd: (d) => _onDragEnd(cycler, d),
        onHorizontalDragCancel: () => _dragDx = 0,
        child: slides,
      );
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        slides,
        Positioned(
          left: 0,
          right: 0,
          // Just above the "time played" footer, over the artwork (the 2.r is
          // the card's own outer padding).
          bottom: SystemCard.gameFooterHeight + 2.r + 4.r,
          child: Center(
            child: RecentCardControls(
              count: cycler.count,
              index: cycler.index,
              onPrevious: () => _step(cycler, -1),
              onNext: () => _step(cycler, 1),
            ),
          ),
        ),
      ],
    );
  }
}

/// The dots for the recent games, between the LT and RT glyphs that step
/// through them. The glyphs are also touch targets for the same steps.
class RecentCardControls extends StatelessWidget {
  const RecentCardControls({
    super.key,
    required this.count,
    required this.index,
    this.onPrevious,
    this.onNext,
  });

  final int count;
  final int index;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  static const String _ltAsset = 'assets/images/gamepad/Xbox_LT_trigger.png';
  static const String _rtAsset = 'assets/images/gamepad/Xbox_RT_trigger.png';

  Widget _trigger(String asset, VoidCallback? onTap, Key key) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // Wider than the glyph so it is a fair touch target on a small card.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
        child: Image.asset(
          asset,
          width: 16.r,
          height: 16.r,
          color: Colors.white,
          colorBlendMode: BlendMode.srcIn,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The pill keeps the glyphs and dots legible over any artwork; the
    // glyphs' knocked-out letters show its dark fill.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _trigger(_ltAsset, onPrevious, const ValueKey('recent_card_lt')),
          IgnorePointer(
            child: RecentCardDots(count: count, index: index),
          ),
          _trigger(_rtAsset, onNext, const ValueKey('recent_card_rt')),
        ],
      ),
    );
  }
}

/// A row of [count] dots with the one at [index] filled.
class RecentCardDots extends StatelessWidget {
  const RecentCardDots({super.key, required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: EdgeInsets.symmetric(horizontal: 3.r),
            width: 7.r,
            height: 7.r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i == index
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.15),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.85),
                width: 1.2.r,
              ),
            ),
          ),
      ],
    );
  }
}
