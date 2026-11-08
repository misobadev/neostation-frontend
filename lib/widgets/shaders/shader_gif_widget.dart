import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ShaderGifWidget extends StatefulWidget {
  final String imagePath;
  final BoxFit fit;

  const ShaderGifWidget({
    super.key,
    required this.imagePath,
    this.fit = BoxFit.cover,
  });

  @override
  State<ShaderGifWidget> createState() => _ShaderGifWidgetState();
}

class _ShaderGifWidgetState extends State<ShaderGifWidget>
    with SingleTickerProviderStateMixin {
  ui.FragmentProgram? _program;
  List<ui.Image> _frames = [];
  List<Duration> _frameDurations = [];

  double _currentFrameIndex = 0;
  Ticker? _ticker;
  Duration _elapsedSinceStart = Duration.zero;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _loadGif();
  }

  @override
  void didUpdateWidget(covariant ShaderGifWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _loadGif();
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/gif_player.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Error loading GIF shader: $e');
    }
  }

  Future<void> _loadGif() async {
    _ticker?.stop();
    for (var f in _frames) {
      f.dispose();
    }
    _frames = [];

    final file = File(widget.imagePath);
    if (!await file.exists()) return;

    try {
      final bytes = await file.readAsBytes();

      // First pass: Just to get the logical size
      final initialCodec = await ui.instantiateImageCodec(bytes);
      final firstFrame = await initialCodec.getNextFrame();
      final int logicalWidth = firstFrame.image.width;
      final int logicalHeight = firstFrame.image.height;
      initialCodec.dispose();

      if (logicalWidth == 0) return;

      // Calculate target dimensions for efficiency (W=250 approx)
      const double targetWidthBase = 250.0;
      final double scale = targetWidthBase / logicalWidth;
      final int cellWidth = targetWidthBase.toInt();
      final int cellHeight = (logicalHeight * scale).toInt();

      // Second pass: Use BOTH targetWidth and targetHeight.
      // THIS IS KEY: Providing both forces Skia to return full-size composed frames
      // at exactly this size, solving all delta/offset issues.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: cellWidth,
        targetHeight: cellHeight,
      );

      final int frameCount = codec.frameCount;
      final List<ui.Image> decodedFrames = [];
      final List<Duration> durations = [];

      for (int i = 0; i < frameCount; i++) {
        final frameInfo = await codec.getNextFrame();
        decodedFrames.add(frameInfo.image);
        durations.add(frameInfo.duration);
      }
      codec.dispose();

      if (mounted) {
        setState(() {
          _frames = decodedFrames;
          _frameDurations = durations;
          _currentFrameIndex = 0;
        });
        _startAnimation();
      }
    } catch (e) {
      debugPrint('Error loading GIF: $e');
    }
  }

  void _startAnimation() {
    _ticker?.dispose();
    _ticker = createTicker(_onTick);
    _elapsedSinceStart = Duration.zero;
    _lastTick = Duration.zero;
    _ticker!.start();
  }

  void _onTick(Duration elapsed) {
    if (_frameDurations.isEmpty) return;

    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    _elapsedSinceStart += delta;

    Duration totalCycleDuration = _frameDurations.fold(
      Duration.zero,
      (prev, curr) => prev + curr,
    );

    final minCycle = Duration(milliseconds: 33 * _frames.length);
    if (totalCycleDuration < minCycle) {
      totalCycleDuration = minCycle;
    }

    final Duration currentCycleTime = Duration(
      microseconds:
          _elapsedSinceStart.inMicroseconds % totalCycleDuration.inMicroseconds,
    );

    Duration accumulated = Duration.zero;
    for (int i = 0; i < _frames.length; i++) {
      Duration frameDur = _frameDurations[i];
      if (frameDur < const Duration(milliseconds: 33)) {
        frameDur = const Duration(milliseconds: 33);
      }

      accumulated += frameDur;
      if (currentCycleTime < accumulated) {
        if (mounted && _currentFrameIndex != i.toDouble()) {
          setState(() {
            _currentFrameIndex = i.toDouble();
          });
        }
        break;
      }
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    for (var f in _frames) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_program == null || _frames.isEmpty) {
      return const SizedBox.shrink();
    }

    final int index = _currentFrameIndex.toInt().clamp(0, _frames.length - 1);
    final ui.Image currentFrame = _frames[index];

    return CustomPaint(
      painter: _ShaderGifPainter(
        shader: _program!.fragmentShader(),
        currentFrame: currentFrame,
        fit: widget.fit,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ShaderGifPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ui.Image currentFrame;
  final BoxFit fit;

  _ShaderGifPainter({
    required this.shader,
    required this.currentFrame,
    required this.fit,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, currentFrame.width.toDouble());
    shader.setFloat(3, currentFrame.height.toDouble());

    double fitValue = 0.0; // fill
    if (fit == BoxFit.contain) {
      fitValue = 1.0;
    } else if (fit == BoxFit.cover) {
      fitValue = 2.0;
    }

    shader.setFloat(4, fitValue);
    shader.setImageSampler(0, currentFrame);

    final paint = Paint()..shader = shader;
    canvas.drawRect(ui.Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _ShaderGifPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame;
  }
}
