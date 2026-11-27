import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/music_player_service.dart';

import 'package:flutter_screenutil/flutter_screenutil.dart';

class MusicVisualizer extends StatefulWidget {
  final bool isPlaying;
  final double volume;

  const MusicVisualizer({
    super.key,
    required this.isPlaying,
    required this.volume,
  });

  @override
  State<MusicVisualizer> createState() => _MusicVisualizerState();
}

class _MusicVisualizerState extends State<MusicVisualizer>
    with SingleTickerProviderStateMixin {
  FragmentProgram? _program;
  late Ticker _ticker;
  double _time = 0.0;
  Duration _lastElapsed = Duration.zero;
  final List<double> _frequencies = List.generate(31, (_) => 0.0);
  final List<double> _peaks = List.generate(31, (_) => 0.0);
  final List<double> _peakFallSpeeds = List.generate(31, (_) => 0.0);
  double _dynamicMax = 0.5; // Baseline for normalization

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker((elapsed) {
      if (!mounted) return;

      final delta = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
      _lastElapsed = elapsed;

      // Speed for time uniform - constant for visual stability
      double speedFactor = widget.isPlaying ? 1.0 : 0.05;

      if (widget.isPlaying) {
        // Fetch real AudioData from SoLoud (FFT + Wave)
        final audioData = MusicPlayerService().getAudioData();
        if (audioData.isNotEmpty && audioData.length >= 256) {
          // 1. Find the maximum amplitude in this frame for dynamic normalization
          double frameMax = 0.0;
          for (int bin = 0; bin < 256; bin++) {
            if (audioData[bin] > frameMax) frameMax = audioData[bin];
          }

          // 2. Update the dynamic maximum with fast attack and slow decay
          if (frameMax > _dynamicMax) {
            _dynamicMax =
                lerpDouble(_dynamicMax, frameMax, 0.3) ?? 0.1; // Fast attack
          } else {
            _dynamicMax =
                lerpDouble(_dynamicMax, frameMax, 0.005) ??
                0.1; // Very slow decay
          }

          // Noise floor to prevent over-amplifying silence
          if (_dynamicMax < 0.1) _dynamicMax = 0.1;

          // 3. Logarithmic mapping: more detail for low frequencies (31 bands)
          for (int i = 0; i < 31; i++) {
            // Distribute 256 bins across 31 bands
            int startBin = (pow(i / 31.0, 2.0) * 256).toInt();
            int endBin = (pow((i + 1) / 31.0, 2.0) * 256).toInt();

            if (endBin <= startBin) endBin = startBin + 1;
            if (endBin > 256) endBin = 256;

            double sum = 0;
            int count = 0;
            for (int j = startBin; j < endBin; j++) {
              sum += audioData[j];
              count++;
            }
            double avg = count > 0 ? (sum / count) : 0.0;

            // Normalized value based on current dynamic headroom
            double normalized = avg / (_dynamicMax + 0.001);

            // Per-band refined weighting (High frequencies usually need a bit more visual weight)
            double weight = 0.8 + (i / 30.0) * 0.6;
            double adjusted = normalized * weight;

            // Soft Compression + Final headroom clamp (0.8 max height)
            double target = pow(adjusted, 0.75).toDouble().clamp(0.0, 0.8);

            if (target > 0.01) {
              _frequencies[i] =
                  lerpDouble(_frequencies[i], target, 0.35) ?? 0.0;
            } else {
              _frequencies[i] = lerpDouble(_frequencies[i], 0.0, 0.08) ?? 0.0;
            }

            // Peak logic (Falling peaks)
            if (_frequencies[i] > _peaks[i]) {
              _peaks[i] = _frequencies[i];
              _peakFallSpeeds[i] = 0.0;
            } else {
              _peakFallSpeeds[i] += delta * 1.5;
              _peaks[i] = (_peaks[i] - _peakFallSpeeds[i] * delta).clamp(
                0.0,
                1.0,
              );
            }
          }
        }
      } else {
        // Flatten frequencies and peaks when not playing
        for (int i = 0; i < 31; i++) {
          _frequencies[i] = lerpDouble(_frequencies[i], 0.0, 0.1) ?? 0.0;
          _peaks[i] = lerpDouble(_peaks[i], 0.0, 0.05) ?? 0.0;
        }
      }

      setState(() {
        _time += delta * speedFactor;
      });
    });
    _ticker.start();
  }

  Future<void> _loadShader() async {
    try {
      final program = await FragmentProgram.fromAsset(
        'assets/shaders/music_visualizer.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Error loading visualizer shader: $e');
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
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8.r),
        ),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.r)),
      );
    }

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final secondaryColor = theme.colorScheme.secondary;
    final tertiaryColor = theme.colorScheme.tertiary;
    final backgroundColor = Colors.transparent;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8.r),
      child: CustomPaint(
        painter: _VisualizerPainter(
          shader: _program!.fragmentShader(),
          time: _time,
          volume: widget.volume,
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          tertiaryColor: tertiaryColor,
          backgroundColor: backgroundColor,
          isPlaying: widget.isPlaying,
          frequencies: _frequencies,
          peaks: _peaks,
        ),
        child: Container(),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  final FragmentShader shader;
  final double time;
  final double volume;
  final Color primaryColor;
  final Color secondaryColor;
  final Color tertiaryColor;
  final Color backgroundColor;
  final bool isPlaying;
  final List<double> frequencies;
  final List<double> peaks;

  _VisualizerPainter({
    required this.shader,
    required this.time,
    required this.volume,
    required this.primaryColor,
    required this.secondaryColor,
    required this.tertiaryColor,
    required this.backgroundColor,
    required this.isPlaying,
    required this.frequencies,
    required this.peaks,
  });

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    shader.setFloat(3, volume);

    // Primary Color (4-7)
    shader.setFloat(4, primaryColor.r);
    shader.setFloat(5, primaryColor.g);
    shader.setFloat(6, primaryColor.b);
    shader.setFloat(7, primaryColor.a);

    // Secondary Color (8-11)
    shader.setFloat(8, secondaryColor.r);
    shader.setFloat(9, secondaryColor.g);
    shader.setFloat(10, secondaryColor.b);
    shader.setFloat(11, secondaryColor.a);

    // Background Color (12-15)
    shader.setFloat(12, backgroundColor.r);
    shader.setFloat(13, backgroundColor.g);
    shader.setFloat(14, backgroundColor.b);
    shader.setFloat(15, backgroundColor.a);

    // Tertiary Color (16-19)
    shader.setFloat(16, tertiaryColor.r);
    shader.setFloat(17, tertiaryColor.g);
    shader.setFloat(18, tertiaryColor.b);
    shader.setFloat(19, tertiaryColor.a);

    shader.setFloat(20, isPlaying ? 1.0 : 0.0);

    // Pass 31 frequency bands (starting at index 21)
    for (int i = 0; i < 31; i++) {
      shader.setFloat(21 + i, frequencies[i]);
    }

    // Pass 31 peaks (starting at index 52)
    for (int i = 0; i < 31; i++) {
      shader.setFloat(52 + i, peaks[i]);
    }

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) {
    return oldDelegate.time != time;
  }
}
