import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/providers/recent_games_cycler.dart';
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
/// With fewer than two games, or no cycler above it, this is just [card].
class RecentCardCycle extends StatelessWidget {
  const RecentCardCycle({super.key, required this.gameKey, required this.card});

  final String? gameKey;
  final Widget card;

  static const Duration _slideDuration = Duration(milliseconds: 350);

  @override
  Widget build(BuildContext context) {
    final cycler = context.watch<RecentGamesCycler?>();
    if (cycler == null || cycler.count < 2) return card;
    final direction = cycler.direction.toDouble();

    return Stack(
      fit: StackFit.passthrough,
      children: [
        ClipRect(
          child: AnimatedSwitcher(
            duration: _slideDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            // Both cards fill the slot; the default centres them loosely.
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.passthrough,
              children: [...previous, ?current],
            ),
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
            child: KeyedSubtree(key: ValueKey(gameKey), child: card),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          // Just above the "time played" footer, over the artwork (the 2.r is
          // the card's own outer padding).
          bottom: SystemCard.gameFooterHeight + 2.r + 8.r,
          child: IgnorePointer(
            child: RecentCardDots(count: cycler.count, index: cycler.index),
          ),
        ),
      ],
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
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 4),
              ],
            ),
          ),
      ],
    );
  }
}
