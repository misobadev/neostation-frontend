import 'package:flutter/material.dart';
import 'package:spring/spring.dart';

/// Adds a subtle spring lift to the selected systems-grid card and lets the
/// previous card settle back down when the selection moves.
///
/// A new [Spring.scale] is keyed only when this card enters or leaves the
/// selection. Rebuilding the grid for any other reason (theme, artwork, scroll)
/// therefore cannot replay the animation on cards the cursor already passed.
class SpringSelectedCard extends StatefulWidget {
  const SpringSelectedCard({
    super.key,
    required this.selected,
    this.previouslySelected = false,
    required this.child,
  });

  final bool selected;

  /// The card the cursor just left. Only this card gets the settle animation;
  /// older cards snap back so fast navigation never leaves a trail of cards in
  /// motion behind the cursor.
  final bool previouslySelected;
  final Widget child;

  @override
  State<SpringSelectedCard> createState() => _SpringSelectedCardState();
}

class _SpringSelectedCardState extends State<SpringSelectedCard> {
  static const double _rest = 1.0;
  static const double _raised = 1.04;
  static const Duration _raiseDuration = Duration(milliseconds: 240);
  static const Duration _settleDuration = Duration(milliseconds: 320);

  late double _from;
  late double _to;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    // A card that is already selected when the grid is born is drawn in its
    // final raised state. The selection spring only runs when the cursor
    // actually moves to or away from a card.
    _from = widget.selected ? _raised : _rest;
    _to = _from;
  }

  @override
  void didUpdateWidget(SpringSelectedCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.selected) {
      if (oldWidget.selected) return;
      _from = _rest;
      _to = _raised;
      _version++;
    } else if (widget.previouslySelected) {
      if (oldWidget.previouslySelected) return;
      _from = _raised;
      _to = _rest;
      _version++;
    } else if (oldWidget.selected || oldWidget.previouslySelected) {
      // The cursor has moved beyond this card. Stop its old animation
      // immediately instead of letting every previously visited card keep
      // settling while the user keeps navigating.
      _from = _rest;
      _to = _rest;
      _version++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final raising = _to > _from;
    return KeyedSubtree(
      key: ValueKey(_version),
      child: Spring.scale(
        start: _from,
        end: _to,
        animDuration: raising ? _raiseDuration : _settleDuration,
        curve: raising ? Curves.easeOutBack : Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
