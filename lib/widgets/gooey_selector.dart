import 'dart:math' as math;
import 'dart:ui' show FragmentProgram, FragmentShader;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The grids' liquid selection.
///
/// At rest it is the selected card's frame, drawn behind the card (see
/// [GooeyCardChrome]). When the selection moves it becomes a ring on top of
/// the cards that jumps to the next card on a spring, overshooting a little
/// and settling, with the cards it leaves and lands on dragged along. It keeps
/// the selector's size the whole way. The frame being left empties and the
/// next one fills in under it as it arrives.
///
/// [GooeySelector] is the layer behind the cards and [GooeySelectorRing] the
/// one on top; both follow one [GooeyMotion].
class GooeyMotion extends ChangeNotifier {
  // The spring the liquid travels on: about seven tenths of critical damping,
  // so it overshoots only a few pixels and settles in about half a second.
  static const double _stiffness = 320;
  static const double _damping = 25;
  // Its size follows on a stiff, critically damped spring: it takes the next
  // card's size within a few frames and never grows past it, so leaving a
  // large card doesn't drag an oversized ring across the grid.
  static const double _sizeStiffness = 1400;
  static final double _sizeDamping = 2 * math.sqrt(_sizeStiffness);
  static const double _step = 1 / 240;

  Rect? _from;
  Rect? _to;
  Object? _selection;
  Offset _center = Offset.zero;
  Offset _velocity = Offset.zero;
  Size _size = Size.zero;
  Size _sizeVelocity = Size.zero;
  bool _moving = false;

  /// Whether the liquid is travelling; the ticker runs only while it is.
  bool get moving => _moving;

  /// The frame it left and the one it is heading for.
  Rect? get from => _from;
  Rect? get to => _to;

  /// The liquid's body now: where the spring has it, at its current size.
  Rect get body => Rect.fromCenter(
    center: _center,
    width: _size.width,
    height: _size.height,
  );

  Offset get velocity => _velocity;

  /// How far along the way to [to] the body is, from 0 to 1.
  double get arrival {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return 1;
    final total = (to.center - from.center).distance;
    if (total < 1) return 1;
    return (1 - (to.center - _center).distance / total).clamp(0.0, 1.0);
  }

  /// How far the liquid drags a card while it travels. The next card leans a
  /// little towards the liquid coming for it, then moves with it one for one
  /// while it overshoots and settles, so the ring never leaves the card it
  /// lands on; the card being left is pulled a little along the way the
  /// liquid goes until it lets go. Zero at rest and for every other card.
  Offset dragOf({required bool target}) {
    final from = _from;
    final to = _to;
    if (!_moving || from == null || to == null) return Offset.zero;
    if (target) {
      final offset = _center - to.center;
      final path = to.center - from.center;
      final pathLength = path.distance;
      // Past the card, the overshoot: the card goes with the ring.
      if (pathLength > 0 &&
          (offset.dx * path.dx + offset.dy * path.dy) / pathLength > 0) {
        return offset;
      }
      // Still coming: the card leans towards it, a little.
      final lean = offset * 0.08;
      final limit = to.shortestSide * 0.04;
      final length = lean.distance;
      return length <= limit ? lean : lean * (limit / length);
    }
    final away = _center - from.center;
    final distance = away.distance;
    if (distance < 0.5) return Offset.zero;
    // Strongest while the liquid is still joined to the card, gone once the
    // drop it pulls out of it has let go.
    final hold = 1 - Curves.easeOut.transform((arrival / 0.55).clamp(0.0, 1.0));
    final reach = math.min(distance * 0.14, from.shortestSide * 0.04);
    return away / distance * reach * hold;
  }

  /// Points the liquid at [target]. A new [selection] makes it travel there
  /// from wherever it is, keeping its momentum through a quick run of presses;
  /// the same selection with a new frame (a relayout) just moves it.
  void retarget(Object selection, Rect target) {
    if (_to == null || selection == _selection && !_moving) {
      _selection = selection;
      _snap(target);
      return;
    }
    if (selection == _selection) {
      _to = target;
      return;
    }
    _selection = selection;
    _from = _moving ? body : _to;
    _to = target;
    // Keep some of the momentum of a quick run of presses, not all of it, or
    // the run builds up speed and the ring flies past the card it lands on.
    _velocity *= 0.5;
    _moving = true;
    // No notification: this runs while the grid builds, and the layers read
    // the new state as they are built; the ticker notifies from the next frame.
  }

  void _snap(Rect target, {bool notify = false}) {
    _from = target;
    _to = target;
    _center = target.center;
    _size = target.size;
    _velocity = Offset.zero;
    _sizeVelocity = Size.zero;
    _moving = false;
    if (notify) notifyListeners();
  }

  /// Advances the springs by [dt] seconds in fixed steps (semi-implicit Euler).
  void advance(double dt) {
    final to = _to;
    if (!_moving || to == null) return;
    // From far away the spring pulls as if the card were only about one card
    // away, and the speed is capped to match, so a long jump (a tap on the
    // other end of the grid) travels at a steady pace and overshoots no more
    // than a jump to the next card does.
    final reach = to.shortestSide * 1.2;
    final topSpeed = math.sqrt(_stiffness) * reach;
    var left = math.min(dt, 0.1);
    while (left > 0) {
      final h = math.min(_step, left);
      left -= h;
      var offset = to.center - _center;
      final distance = offset.distance;
      if (distance > reach) offset = offset * (reach / distance);
      final pull = offset * _stiffness - _velocity * _damping;
      _velocity += pull * h;
      final speed = _velocity.distance;
      if (speed > topSpeed) _velocity = _velocity * (topSpeed / speed);
      _center += _velocity * h;
      final sw =
          (to.width - _size.width) * _sizeStiffness -
          _sizeVelocity.width * _sizeDamping;
      final sh =
          (to.height - _size.height) * _sizeStiffness -
          _sizeVelocity.height * _sizeDamping;
      _sizeVelocity = Size(
        _sizeVelocity.width + sw * h,
        _sizeVelocity.height + sh * h,
      );
      _size = Size(
        _size.width + _sizeVelocity.width * h,
        _size.height + _sizeVelocity.height * h,
      );
    }
    final settled =
        (to.center - _center).distance < 0.4 &&
        _velocity.distance < 6 &&
        (to.width - _size.width).abs() < 0.4 &&
        (to.height - _size.height).abs() < 0.4;
    if (settled) {
      _snap(to, notify: true);
      return;
    }
    notifyListeners();
  }
}

/// The layer behind the cards: the frames of the cards the liquid sits
/// behind, the frame being left emptying and the next one filling as the
/// liquid travels, and the frame itself at rest.
class GooeySelector extends StatefulWidget {
  const GooeySelector({
    super.key,
    required this.motion,
    required this.selection,
    required this.target,
    required this.color,
    required this.baseColor,
    required this.radius,
    this.baseRects = const [],
  });

  final GooeyMotion motion;

  /// Identifies what is selected; see [GooeyMotion.retarget].
  final Object selection;

  /// The selected card's frame, in the coordinates of this widget.
  final Rect target;
  final Color color;
  final Color baseColor;
  final double radius;

  /// The frames of the cards the liquid sits behind, in [baseColor]: the
  /// selected card's first, then the one it left.
  final List<Rect> baseRects;

  @override
  State<GooeySelector> createState() => _GooeySelectorState();
}

class _GooeySelectorState extends State<GooeySelector>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.motion.addListener(_onMotion);
    widget.motion.retarget(widget.selection, widget.target);
    _onMotion();
    GooeySelectorRing.loadProgram();
  }

  @override
  void didUpdateWidget(GooeySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.motion, widget.motion)) {
      oldWidget.motion.removeListener(_onMotion);
      widget.motion.addListener(_onMotion);
    }
    if (widget.selection != oldWidget.selection ||
        widget.target != oldWidget.target) {
      widget.motion.retarget(widget.selection, widget.target);
      _onMotion();
    }
  }

  void _onMotion() {
    if (widget.motion.moving && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!widget.motion.moving && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    widget.motion.advance(dt);
  }

  @override
  void dispose() {
    widget.motion.removeListener(_onMotion);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FramesPainter(
        motion: widget.motion,
        rects: widget.baseRects,
        color: widget.color,
        baseColor: widget.baseColor,
        radius: widget.radius,
      ),
    );
  }
}

class _FramesPainter extends CustomPainter {
  _FramesPainter({
    required this.motion,
    required this.rects,
    required this.color,
    required this.baseColor,
    required this.radius,
  }) : super(repaint: motion);

  final GooeyMotion motion;
  final List<Rect> rects;
  final Color color;
  final Color baseColor;
  final double radius;

  void _frame(Canvas canvas, Rect rect, Color color) => canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(radius)),
    Paint()..color = color,
  );

  @override
  void paint(Canvas canvas, Size size) {
    // The base frames are the selected card's and the previous one's, in that
    // order; they move with those cards.
    for (var i = 0; i < rects.length; i++) {
      final drag = motion.dragOf(target: i == 0);
      _frame(canvas, rects[i].shift(drag), baseColor);
    }
    final to = motion.to;
    if (to == null) return;
    final from = motion.from;
    if (!motion.moving || from == null) {
      _frame(canvas, to, color);
      return;
    }
    final arrival = motion.arrival;
    // The frame being left empties as the liquid pulls out of it, and the
    // next one fills as it lands.
    final leaving =
        1 - Curves.easeOut.transform((arrival / 0.45).clamp(0.0, 1.0));
    final filling = Curves.easeIn.transform(
      ((arrival - 0.45) / 0.55).clamp(0.0, 1.0),
    );
    // The fills follow their cards as the liquid drags them.
    final fromDrag = motion.dragOf(target: false);
    final toDrag = motion.dragOf(target: true);
    if (leaving > 0) {
      _frame(canvas, from.shift(fromDrag), color.withValues(alpha: leaving));
    }
    if (filling > 0) {
      _frame(canvas, to.shift(toDrag), color.withValues(alpha: filling));
    }
  }

  @override
  bool shouldRepaint(_FramesPainter old) =>
      old.rects != rects ||
      old.color != color ||
      old.baseColor != baseColor ||
      old.radius != radius;
}

/// The layer on top of the cards: the liquid ring while it travels. Draws
/// nothing at rest.
class GooeySelectorRing extends StatelessWidget {
  const GooeySelectorRing({
    super.key,
    required this.motion,
    required this.color,
    required this.radius,
    required this.ringWidth,
  });

  final GooeyMotion motion;
  final Color color;
  final double radius;

  /// The ring's thickness: the selected card's visible frame.
  final double ringWidth;

  /// The shader, shared by every grid; null until loaded, and for good if it
  /// fails to (the ring is then drawn without its liquid joins).
  static FragmentProgram? _program;
  static Future<void>? _loading;

  static void loadProgram() {
    _loading ??= FragmentProgram.fromAsset('assets/shaders/gooey_selector.frag')
        .then<void>((program) => _program = program, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _RingPainter(
          motion: motion,
          color: color,
          radius: radius,
          ringWidth: ringWidth,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.motion,
    required this.color,
    required this.radius,
    required this.ringWidth,
  }) : super(repaint: motion);

  final GooeyMotion motion;
  final Color color;
  final double radius;
  final double ringWidth;

  static const int _maxShapes = 8;
  FragmentShader? _shader;

  @override
  void paint(Canvas canvas, Size size) {
    final from = motion.from;
    if (!motion.moving || from == null) return;
    // The ring keeps the selector's size and shape the whole way; only its
    // place moves, on the spring.
    final body = motion.body;
    final shapes = <(Rect, double)>[(body, radius)];
    final reach = math.max(6.0, radius * 0.9);
    final program = GooeySelectorRing._program;
    if (program == null) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth;
      for (final (rect, r) in shapes) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.deflate(ringWidth / 2),
            Radius.circular(math.max(0, r - ringWidth / 2)),
          ),
          paint,
        );
      }
      return;
    }
    final shader = _shader ??= program.fragmentShader();
    var bounds = body;
    for (final (rect, _) in shapes) {
      bounds = bounds.expandToInclude(rect);
    }
    bounds = bounds.inflate(reach + 2);
    var i = 0;
    void set(double value) => shader.setFloat(i++, value);
    set(size.width);
    set(size.height);
    set(color.r);
    set(color.g);
    set(color.b);
    set(color.a);
    set(reach);
    set(0.75);
    set(shapes.length.toDouble());
    set(ringWidth);
    for (var s = 0; s < _maxShapes; s++) {
      if (s < shapes.length) {
        final rect = shapes[s].$1;
        set(rect.center.dx);
        set(rect.center.dy);
        set(rect.width / 2);
        set(rect.height / 2);
      } else {
        for (var k = 0; k < 4; k++) {
          set(0);
        }
      }
    }
    for (var s = 0; s < _maxShapes; s++) {
      set(s < shapes.length ? shapes[s].$2 : 0);
    }
    canvas.drawRect(bounds, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.radius != radius || old.ringWidth != ringWidth;
}

/// Moves a card with the liquid's drag (see [GooeyMotion.dragOf]). Wraps
/// every card of a grid the same way, so the cards' subtrees keep their shape
/// as the selection moves; only the selected card and the one it left move.
class GooeyCardDrag extends StatelessWidget {
  const GooeyCardDrag({
    super.key,
    required this.motion,
    required this.role,
    required this.child,
  });

  final GooeyMotion motion;

  /// True for the selected card, false for the one it left, null for the
  /// rest, which never move.
  final bool? role;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final role = this.role;
    return AnimatedBuilder(
      animation: motion,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: role == null ? Offset.zero : motion.dragOf(target: role),
        child: child,
      ),
    );
  }
}

/// Tells a card whether the [GooeySelector] behind it draws its frame, so the
/// card leaves its own frame transparent and lets the liquid show through.
///
/// Every card of a grid gets one, with only [liquid] changing, so the cards'
/// subtrees keep their shape as the selection moves.
class GooeyCardChrome extends InheritedWidget {
  const GooeyCardChrome({
    super.key,
    required this.enabled,
    required this.liquid,
    required this.selected,
    required super.child,
  });

  /// Whether the grid draws its selection as liquid at all. Off in
  /// performance mode, where the cards draw their selection as before.
  final bool enabled;

  /// The frame is drawn behind the card.
  final bool liquid;

  /// Whether this card is the one selected.
  final bool selected;

  static GooeyCardChrome? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GooeyCardChrome>();

  /// The span a card's text changes colour in: about the liquid's jump.
  static const Duration textFade = Duration(milliseconds: 480);

  /// The colour a card's text or logo should take: faded towards [color]
  /// over [textFade] when the liquid selection is on, so it changes with the
  /// frame under it; at once otherwise.
  static Widget fadeColor(
    BuildContext context, {
    required Color color,
    required Widget Function(Color color) builder,
  }) {
    final chrome = maybeOf(context);
    if (!(chrome?.enabled ?? false)) return builder(color);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: textFade,
      // The next card's text turns as its frame fills; the one being left
      // turns as its frame empties.
      curve: chrome!.selected
          ? const Interval(0.35, 0.8, curve: Curves.easeOut)
          : const Interval(0.3, 0.65, curve: Curves.easeOut),
      builder: (context, value, _) => builder(value ?? color),
    );
  }

  @override
  bool updateShouldNotify(GooeyCardChrome oldWidget) =>
      enabled != oldWidget.enabled ||
      liquid != oldWidget.liquid ||
      selected != oldWidget.selected;
}
