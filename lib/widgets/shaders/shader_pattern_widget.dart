import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ShaderPatternWidget extends StatefulWidget {
  final String id; // Unique ID for persistence
  final Color color1;
  final Color color2;
  final double tiles;
  final double speed;
  final double direction;
  final double warpScale;
  final double warpTiling;
  final double? borderRadius;

  const ShaderPatternWidget({
    super.key,
    required this.id,
    required this.color1,
    required this.color2,
    this.tiles = 10.0,
    this.speed = 0.5,
    this.direction = 0.125, // 45 degrees approx (0.125 * 2 * PI)
    this.warpScale = 0.05,
    this.warpTiling = 1.0,
    this.borderRadius,
  });

  @override
  State<ShaderPatternWidget> createState() => _ShaderPatternWidgetState();

  // Static map to persist time across rebuilds and instances
  static final Map<String, double> _persistentTimes = {};
}

class _ShaderPatternWidgetState extends State<ShaderPatternWidget>
    with SingleTickerProviderStateMixin {
  FragmentProgram? _program;
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker((elapsed) {
      if (widget.speed <= 0) {
        _lastElapsed = elapsed;
        return;
      }

      final delta = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
      final currentTime =
          ShaderPatternWidget._persistentTimes[widget.id] ?? 0.0;

      ShaderPatternWidget._persistentTimes[widget.id] =
          currentTime + (delta * widget.speed);

      setState(() {});
      _lastElapsed = elapsed;
    });
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant ShaderPatternWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  Future<void> _loadShader() async {
    try {
      final program = await FragmentProgram.fromAsset(
        'assets/shaders/stripes.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Error loading shader: $e');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_program == null) {
      return Container(
        decoration: BoxDecoration(
          color: widget.color1,
          borderRadius: widget.borderRadius != null
              ? BorderRadius.circular(widget.borderRadius!)
              : null,
        ),
      );
    }

    return CustomPaint(
      painter: _ShaderPainter(
        shader: _program!.fragmentShader(),
        time: ShaderPatternWidget._persistentTimes[widget.id] ?? 0.0,
        color1: widget.color1,
        color2: widget.color2,
        tiles: widget.tiles,
        direction: widget.direction,
        warpScale: widget.warpScale,
        warpTiling: widget.warpTiling,
      ),
    );
  }
}

class _ShaderPainter extends CustomPainter {
  final FragmentShader shader;
  final double time;
  final Color color1;
  final Color color2;
  final double tiles;
  final double direction;
  final double warpScale;
  final double warpTiling;

  _ShaderPainter({
    required this.shader,
    required this.time,
    required this.color1,
    required this.color2,
    required this.tiles,
    required this.direction,
    required this.warpScale,
    required this.warpTiling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Index mapping from shader (uSpeed removed):
    // 0-1: uResolution
    // 2: uTime (now acts as the offset)
    // 3: uTiles
    // 4: uDirection
    // 5: uWarpScale
    // 6: uWarpTiling
    // 7-9: uColor1
    // 10-12: uColor2

    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    shader.setFloat(3, tiles);
    shader.setFloat(4, direction);
    shader.setFloat(5, warpScale);
    shader.setFloat(6, warpTiling);

    // Color1
    shader.setFloat(7, color1.r);
    shader.setFloat(8, color1.g);
    shader.setFloat(9, color1.b);

    // Color2
    shader.setFloat(10, color2.r);
    shader.setFloat(11, color2.g);
    shader.setFloat(12, color2.b);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _ShaderPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.color1 != color1 ||
        oldDelegate.color2 != color2 ||
        oldDelegate.tiles != tiles ||
        oldDelegate.direction != direction ||
        oldDelegate.warpScale != warpScale ||
        oldDelegate.warpTiling != warpTiling;
  }
}
