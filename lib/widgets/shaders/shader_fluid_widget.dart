import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'dart:math' as math;

class ShaderFluidWidget extends StatefulWidget {
  const ShaderFluidWidget({super.key});

  @override
  State<ShaderFluidWidget> createState() => _ShaderFluidWidgetState();
}

class _ShaderFluidWidgetState extends State<ShaderFluidWidget>
    with SingleTickerProviderStateMixin {
  FragmentProgram? _program;
  late final Ticker _ticker;
  double _time = 0.0;
  final ValueNotifier<double> _timeNotifier = ValueNotifier(0.0);
  Duration _lastElapsed = Duration.zero;
  Duration _lastFrameTime = Duration.zero;
  static const double _maxTime =
      400.0 * math.pi; // Multiple of 40*pi for seamless loop
  static const Duration _frameInterval = Duration(milliseconds: 33); // ~30 FPS

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker((elapsed) {
      if (_lastElapsed != Duration.zero) {
        final double delta =
            (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
        _time += delta;

        // Wrap time
        if (_time > _maxTime) {
          _time -= _maxTime;
        }

        // Throttle to ~30 FPS
        if (elapsed - _lastFrameTime >= _frameInterval) {
          _timeNotifier.value = _time;
          _lastFrameTime = elapsed;
        }
      }
      _lastElapsed = elapsed;
    });
    _ticker.start();
  }

  Future<void> _loadShader() async {
    try {
      final program = await FragmentProgram.fromAsset(
        'assets/shaders/fluid.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Error loading fluid shader: $e');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_program == null) {
      return Container(color: Colors.black);
    }

    return CustomPaint(
      painter: _FluidShaderPainter(
        shader: _program!.fragmentShader(),
        timeNotifier: _timeNotifier,
        col4: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _FluidShaderPainter extends CustomPainter {
  _FluidShaderPainter({
    required this.shader,
    required this.timeNotifier,
    required this.col4,
  }) : super(repaint: timeNotifier);

  final FragmentShader shader;
  final ValueNotifier<double> timeNotifier;
  final Color col4;

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, timeNotifier.value);
    shader.setFloat(3, col4.r);
    shader.setFloat(4, col4.g);
    shader.setFloat(5, col4.b);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _FluidShaderPainter oldDelegate) {
    return oldDelegate.col4 != col4 || oldDelegate.shader != shader;
  }
}
