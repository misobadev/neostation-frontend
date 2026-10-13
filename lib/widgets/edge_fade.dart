import 'package:flutter/material.dart';

/// Fades whichever edge of a list has content beyond it, as the header's sort
/// menu does, so rows dissolve into the list's padding instead of being sliced
/// off. An edge with nothing beyond it keeps a hard stop, so the first and last
/// rows, and their glow, are never dimmed.
///
/// The mask is only there while an edge is faded: it composites the whole list
/// offscreen every frame, which a list that fits never needs.
class EdgeFade extends StatefulWidget {
  /// How far in from each edge the fade runs.
  final double extent;
  final Widget child;

  const EdgeFade({super.key, required this.extent, required this.child});

  @override
  State<EdgeFade> createState() => _EdgeFadeState();
}

class _EdgeFadeState extends State<EdgeFade> {
  /// Moves the list in and out of the mask without remounting it, which would
  /// lose its scroll position each time it reached an end.
  final _childKey = GlobalKey();
  bool _before = false;
  bool _after = false;

  /// Never stops the notification, so it reaches anything else listening.
  bool _update(ScrollMetrics metrics) {
    final before = metrics.extentBefore > 0;
    final after = metrics.extentAfter > 0;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    // Metrics cover the first layout and changes of length; updates cover
    // scrolling.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => n.depth == 0 && _update(n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => n.depth == 0 && _update(n.metrics),
        child: !_before && !_after
            ? child
            : ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  final stop = bounds.height > 0
                      ? (widget.extent / bounds.height).clamp(0.0, 0.5)
                      : 0.0;
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, _before ? stop : 0, _after ? 1 - stop : 1, 1],
                    colors: const [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                  ).createShader(bounds);
                },
                child: child,
              ),
      ),
    );
  }
}
