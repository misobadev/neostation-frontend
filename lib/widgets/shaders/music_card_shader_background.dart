import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class MusicCardShaderBackground extends StatefulWidget {
  const MusicCardShaderBackground({
    super.key,
    required this.coverBytes,
    required this.tintColor,
    this.borderRadius = 12.0,
    this.opacity = 1.0,
  });

  final Uint8List coverBytes;
  final Color tintColor;
  final double borderRadius;
  final double opacity;

  @override
  State<MusicCardShaderBackground> createState() =>
      _MusicCardShaderBackgroundState();
}

class _MusicCardShaderBackgroundState extends State<MusicCardShaderBackground>
    with SingleTickerProviderStateMixin {
  static ui.FragmentProgram? _programCache;
  static ui.Image? _diskImageCache;

  ui.FragmentProgram? _program;
  ui.Image? _coverImage;
  ui.Image? _diskImage;
  Object? _shaderLoadError;
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  double _time = 0.0;
  final ValueNotifier<double> _timeNotifier = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _loadResources();
  }

  @override
  void didUpdateWidget(covariant MusicCardShaderBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coverBytes, widget.coverBytes)) {
      _loadCoverImage();
    }
  }

  Future<void> _loadResources() async {
    await Future.wait([_loadShader(), _loadDiskImage(), _loadCoverImage()]);
  }

  Future<void> _loadShader() async {
    if (_programCache != null) {
      _program = _programCache;
      if (mounted) setState(() {});
      return;
    }

    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/music_card_background.frag',
      );

      _programCache = program;
      _program = program;
      _shaderLoadError = null;
      if (mounted) setState(() {});
    } catch (e) {
      _shaderLoadError = e;
      debugPrint('Error loading music card shader: $e');
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadDiskImage() async {
    if (_diskImageCache != null) {
      _diskImage = _diskImageCache;
      if (mounted) setState(() {});
      return;
    }

    final data = await rootBundle.load('assets/images/music/disk.webp');
    final image = await _decodeImage(data.buffer.asUint8List());
    _diskImageCache = image;
    _diskImage = image;
    if (mounted) setState(() {});
  }

  Future<void> _loadCoverImage() async {
    try {
      final image = await _decodeImage(widget.coverBytes);
      _coverImage?.dispose();
      _coverImage = image;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error decoding cover image for music card shader: $e');
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final delta = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    _time += delta;
    _timeNotifier.value = _time;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _timeNotifier.dispose();
    _coverImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shaderLoadError != null ||
        _program == null ||
        _coverImage == null ||
        _diskImage == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Image.memory(
          widget.coverBytes,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Opacity(
        opacity: widget.opacity,
        child: CustomPaint(
          painter: _MusicCardShaderPainter(
            shader: _program!.fragmentShader(),
            coverImage: _coverImage!,
            diskImage: _diskImage!,
            tintColor: widget.tintColor,
            timeNotifier: _timeNotifier,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _MusicCardShaderPainter extends CustomPainter {
  _MusicCardShaderPainter({
    required this.shader,
    required this.coverImage,
    required this.diskImage,
    required this.tintColor,
    required this.timeNotifier,
  }) : super(repaint: timeNotifier);

  final ui.FragmentShader shader;
  final ui.Image coverImage;
  final ui.Image diskImage;
  final Color tintColor;
  final ValueNotifier<double> timeNotifier;

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, timeNotifier.value);
    shader.setFloat(3, tintColor.r);
    shader.setFloat(4, tintColor.g);
    shader.setFloat(5, tintColor.b);
    shader.setFloat(6, 1.0);
    shader.setFloat(7, coverImage.width.toDouble());
    shader.setFloat(8, coverImage.height.toDouble());
    shader.setFloat(9, diskImage.width.toDouble());
    shader.setFloat(10, diskImage.height.toDouble());
    shader.setImageSampler(0, coverImage, filterQuality: FilterQuality.medium);
    shader.setImageSampler(1, diskImage, filterQuality: FilterQuality.medium);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _MusicCardShaderPainter oldDelegate) {
    return oldDelegate.coverImage != coverImage ||
        oldDelegate.diskImage != diskImage ||
        oldDelegate.tintColor != tintColor ||
        oldDelegate.shader != shader;
  }
}
