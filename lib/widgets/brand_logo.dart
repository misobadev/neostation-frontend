import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/performance_mode.dart';

/// NeoStation's logo: the eye isotype with the "NeoStation" wordmark, from the
/// brand kit. The wordmark is bone on dark themes and ink on light ones, so it
/// follows the brightness of the theme it is drawn in.
///
/// The eye is painted rather than drawn from an image so it can move: every
/// few seconds it looks up-right, down-left and blinks along the same
/// diagonal, on the brand kit's timeline. It stays still in performance mode
/// and when the system asks for reduced motion.
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    required this.width,
    this.brightness,
    this.animate = true,
  });

  /// Width the logo is drawn at; its height follows [aspectRatio].
  final double width;

  /// Overrides the theme's brightness, for a logo drawn outside a [Theme]
  /// that matches its background.
  final Brightness? brightness;

  /// Whether the eye looks around and blinks.
  final bool animate;

  /// Width over height of the lockup (640.3×109.8 in the brand kit).
  static const double aspectRatio = 640.3 / 109.8;

  /// Where the wordmark starts in the lockup, as a share of its width.
  static const double wordmarkStart = 142.4 / 640.3;

  /// The wordmark alone, on the lockup's canvas: the eye is painted over it.
  static const String darkBackgroundAsset = 'assets/images/logo_wordmark.png';
  static const String lightBackgroundAsset =
      'assets/images/logo_wordmark_light.png';

  /// The wordmark for a background of [brightness].
  static String assetFor(Brightness brightness) =>
      brightness == Brightness.light
      ? lightBackgroundAsset
      : darkBackgroundAsset;

  @override
  Widget build(BuildContext context) {
    final resolved = brightness ?? Theme.of(context).brightness;
    final height = width / aspectRatio;
    // Lockup units to logical pixels.
    final unit = width / 640.3;
    return Semantics(
      label: 'NeoStation',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                assetFor(resolved),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
            // The eye's box in the lockup: 109.5 units square at (0, 0.22).
            Positioned(
              left: 0,
              top: 0.22 * unit,
              width: 109.5 * unit,
              height: 109.5 * unit,
              child: BrandEye(brightness: resolved, animate: animate),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "NeoStation" wordmark on its own, [width] wide.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, required this.width, this.brightness});

  final double width;
  final Brightness? brightness;

  @override
  Widget build(BuildContext context) {
    final resolved = brightness ?? Theme.of(context).brightness;
    final lockupWidth = width / (1 - BrandLogo.wordmarkStart);
    return Semantics(
      label: 'NeoStation',
      image: true,
      excludeSemantics: true,
      child: ClipRect(
        child: Align(
          alignment: Alignment.centerRight,
          widthFactor: 1 - BrandLogo.wordmarkStart,
          child: Image.asset(
            BrandLogo.assetFor(resolved),
            width: lockupWidth,
            height: lockupWidth / BrandLogo.aspectRatio,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

/// The isotype on its own: a two-weight ring around a red pupil. It fills its
/// box, which should be square.
class BrandEye extends StatefulWidget {
  const BrandEye({super.key, this.brightness, this.animate = true});

  /// The brightness of the background it sits on; the theme's by default.
  final Brightness? brightness;

  /// Whether the eye looks around and blinks.
  final bool animate;

  @override
  State<BrandEye> createState() => _BrandEyeState();
}

class _BrandEyeState extends State<BrandEye>
    with SingleTickerProviderStateMixin {
  // The brand kit plays the motion (a little over three seconds) once every
  // nine; the eye rests in between, so no frames are drawn then.
  static const Duration _motion = Duration(milliseconds: 3030);
  static const Duration _period = Duration(seconds: 9);
  static const Duration _firstLook = Duration(milliseconds: 1500);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _motion,
  )..addStatusListener(_onStatus);
  Timer? _rest;
  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BrandEye oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final run = widget.animate && !reduceMotion && !context.performanceMode;
    if (run == _running) return;
    _running = run;
    if (run) {
      _schedule(_firstLook);
    } else {
      _rest?.cancel();
      _controller.stop();
      _controller.value = 0;
    }
  }

  void _schedule(Duration delay) {
    _rest?.cancel();
    _rest = Timer(delay, () {
      if (mounted && _running) _controller.forward(from: 0);
    });
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _running) {
      _schedule(_period - _motion);
    }
  }

  @override
  void dispose() {
    _rest?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = widget.brightness ?? Theme.of(context).brightness;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _EyePainter(
          _controller,
          light: brightness == Brightness.light,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// A moment of the motion: where the pupil looks ([look] along the up-right
/// diagonal), how far the ring turns ([turn], degrees) and how shut the eye
/// is ([lid], 0 to 1), with the curve used to get there.
class _Key {
  const _Key(
    this.time, {
    this.look = 0,
    this.turn = 0,
    this.lid = 0,
    this.curve = Curves.linear,
  });

  final double time;
  final double look;
  final double turn;
  final double lid;
  final Curve curve;
}

// The brand kit's "look and blink" (logos/tools/eye-motion.mjs).
const Cubic _inOut = Cubic(0.65, 0, 0.35, 1);
const Cubic _in = Cubic(0.32, 0, 0.67, 0);
const Cubic _back = Cubic(0.34, 1.7, 0.64, 1);
const List<_Key> _keys = [
  _Key(0),
  _Key(0.6),
  _Key(0.85, look: 22, turn: 6, curve: _inOut),
  _Key(1.45, look: 22, turn: 6),
  _Key(1.8, look: -22, turn: -6, curve: _inOut),
  _Key(2.4, look: -22, turn: -6),
  _Key(2.65, curve: _inOut),
  _Key(2.75),
  _Key(2.84, lid: 1, curve: _in),
  _Key(2.88, lid: 1),
  _Key(3.03, curve: _back),
];

class _EyePainter extends CustomPainter {
  _EyePainter(this.progress, {required this.light}) : super(repaint: progress);

  final Animation<double> progress;
  final bool light;

  static const Offset _centre = Offset(256, 256);
  static const double _diagonal = math.pi / 4;

  // The ring's two arcs (radius 150 around the centre).
  static final double _heavyStart = math.atan2(320.3 - 256, 120.5 - 256);
  static final double _heavySweep = _sweep(
    _heavyStart,
    math.atan2(120.5 - 256, 320.3 - 256),
  );
  static final double _thinStart = math.atan2(175.8 - 256, 382.8 - 256);
  static final double _thinSweep = _sweep(
    _thinStart,
    math.atan2(382.8 - 256, 175.8 - 256),
  );

  static double _sweep(double from, double to) {
    var sweep = to - from;
    while (sweep < 0) {
      sweep += 2 * math.pi;
    }
    return sweep;
  }

  /// Turns [canvas] about the centre and scales it along the diagonal.
  static void _squash(Canvas canvas, double turn, double sx, double sy) {
    canvas
      ..translate(_centre.dx, _centre.dy)
      ..rotate(turn)
      ..rotate(-_diagonal)
      ..scale(sx, sy)
      ..rotate(_diagonal)
      ..translate(-_centre.dx, -_centre.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value * _keys.last.time;
    var look = 0.0, turn = 0.0, lid = 0.0;
    for (var i = 0; i < _keys.length - 1; i++) {
      final a = _keys[i], b = _keys[i + 1];
      if (t > b.time && i < _keys.length - 2) continue;
      final span = b.time - a.time;
      final f = ((t - a.time) / span).clamp(0.0, 1.0);
      final e = b.curve.transform(f);
      look = a.look + (b.look - a.look) * e;
      turn = a.turn + (b.turn - a.turn) * e;
      lid = a.lid + (b.lid - a.lid) * e;
      break;
    }

    // The isotype's box in the brand kit's 512 grid: 73 to 421.25.
    canvas
      ..save()
      ..scale(size.shortestSide / 348.25)
      ..translate(-73, -73);

    final heavy = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 66
      ..color = light ? const Color(0xFF111216) : const Color(0xFFF1EDE4);
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 30
      ..color = light ? const Color(0xFF77736A) : const Color(0xFFB9B4A8);
    final pupil = Paint()
      ..color = light ? const Color(0xFFE8402F) : const Color(0xFFFF5A4A);

    // Closed, the ring squashes 8 % across the diagonal and the pupil
    // flattens to 17 % of its height while widening 14 %.
    final ring = Rect.fromCircle(center: _centre, radius: 150);
    canvas.save();
    _squash(canvas, turn * math.pi / 180, 1 + 0.03 * lid, 1 - 0.08 * lid);
    canvas
      ..drawArc(ring, _heavyStart, _heavySweep, false, heavy)
      ..drawArc(ring, _thinStart, _thinSweep, false, thin)
      ..restore()
      ..save()
      ..translate(look, -look);
    _squash(canvas, 0, 1 + 0.14 * lid, 1 - 0.83 * lid);
    canvas
      ..drawCircle(_centre, 53, pupil)
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(_EyePainter oldDelegate) =>
      oldDelegate.light != light || oldDelegate.progress != progress;
}
