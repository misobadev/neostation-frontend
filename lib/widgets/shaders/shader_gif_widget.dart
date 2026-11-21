import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An animated GIF (from a file, or an asset when no such file exists) drawn
/// through the GIF shader.
///
/// Every widget showing the same GIF at the same size shares one player: the
/// GIF is decoded once, a frame at a time, and a card rebuilt by the grid (a
/// selection change, a scroll) picks the same player up again instead of
/// decoding from scratch, so the art neither blanks out nor restarts. Only the
/// GIF's own layer repaints when its frame changes.
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

class _ShaderGifWidgetState extends State<ShaderGifWidget> {
  _GifPlayer? _player;

  @override
  void initState() {
    super.initState();
    _GifShader.load();
  }

  @override
  void didUpdateWidget(covariant ShaderGifWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) _release();
  }

  void _release() {
    _player?.release();
    _player = null;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final logical = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 250.0;
        // Decode at the size it is shown, rounded up so cards of nearly the
        // same size share a player.
        final bucket = (math.max(logical * dpr, 64) / 128).ceil() * 128;
        final player = _player;
        if (player == null || player.width != bucket) {
          player?.release();
          _player = _GifPlayer.acquire(widget.imagePath, bucket);
        }
        return RepaintBoundary(
          child: CustomPaint(
            painter: _GifPainter(_player!.frame, widget.fit),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

/// Plays one GIF at one decode width for every widget showing it.
class _GifPlayer {
  _GifPlayer._(this.path, this.width);

  static final Map<String, _GifPlayer> _players = {};

  /// How long a player nobody shows is kept, so a card that is rebuilt (or
  /// scrolled back into view) shortly after resumes where it was.
  static const Duration _keepAlive = Duration(seconds: 3);

  static _GifPlayer acquire(String path, int width) {
    final player = _players.putIfAbsent('$path@$width', () {
      final created = _GifPlayer._(path, width);
      created._load();
      return created;
    });
    player._users++;
    player._releaseTimer?.cancel();
    return player;
  }

  final String path;
  final int width;
  final ValueNotifier<ui.Image?> frame = ValueNotifier(null);

  int _users = 0;
  Timer? _releaseTimer;
  Timer? _nextFrame;
  ui.Codec? _codec;
  bool _disposed = false;

  /// When the current frame was due, so decoding time doesn't add up into a
  /// slower loop: each frame is timed from when it should have appeared.
  final Stopwatch _clock = Stopwatch();
  Duration _due = Duration.zero;

  void release() {
    _users--;
    if (_users > 0) return;
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_keepAlive, () {
      if (_users <= 0) _dispose();
    });
  }

  Future<void> _load() async {
    try {
      final bytes = await _readBytes();
      if (bytes == null || _disposed) return;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      // Never above the GIF's own size; the height follows its aspect.
      final w = math.min(width, descriptor.width);
      final h = math.max(1, (descriptor.height * w / descriptor.width).round());
      // Giving both sides makes the codec hand back whole composed frames at
      // this size rather than the GIF's partial updates.
      final codec = await descriptor.instantiateCodec(
        targetWidth: w,
        targetHeight: h,
      );
      descriptor.dispose();
      buffer.dispose();
      if (_disposed) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _clock.start();
      await _advance();
    } catch (e) {
      debugPrint('Error loading GIF $path: $e');
    }
  }

  Future<Uint8List?> _readBytes() async {
    final file = File(path);
    if (await file.exists()) return file.readAsBytes();
    try {
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _advance() async {
    final codec = _codec;
    if (codec == null || _disposed) return;
    final info = await codec.getNextFrame();
    if (_disposed) {
      info.image.dispose();
      return;
    }
    final previous = frame.value;
    frame.value = info.image;
    previous?.dispose();
    if (codec.frameCount <= 1) return;
    _due += _delay(info.duration);
    final now = _clock.elapsed;
    // Fell far behind (the app was paused): carry on from now.
    if (_due < now - const Duration(seconds: 1)) _due = now;
    _nextFrame = Timer(_due - now, _advance);
  }

  /// A frame's delay as browsers play it: delays of 10 ms or less (often 0,
  /// meaning "unset") play at 100 ms.
  static Duration _delay(Duration duration) => duration.inMilliseconds <= 10
      ? const Duration(milliseconds: 100)
      : duration;

  void _dispose() {
    _disposed = true;
    _players.remove('$path@$width');
    _nextFrame?.cancel();
    _codec?.dispose();
    _codec = null;
    final last = frame.value;
    frame.value = null;
    last?.dispose();
    frame.dispose();
  }
}

/// The GIF shader, loaded once for every GIF.
class _GifShader {
  static ui.FragmentProgram? program;
  static Future<void>? _loading;

  static void load() {
    _loading ??= ui.FragmentProgram.fromAsset('assets/shaders/gif_player.frag')
        .then<void>((p) => program = p)
        .catchError((Object e) => debugPrint('Error loading GIF shader: $e'));
  }
}

class _GifPainter extends CustomPainter {
  _GifPainter(this.frame, this.fit) : super(repaint: frame);

  final ValueListenable<ui.Image?> frame;
  final BoxFit fit;
  ui.FragmentShader? _shader;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final image = frame.value;
    if (image == null || size.isEmpty) return;
    final program = _GifShader.program;
    if (program == null) {
      // Until the shader is ready, draw the frame directly.
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: image,
        fit: fit,
        filterQuality: FilterQuality.medium,
      );
      return;
    }
    final shader = _shader ??= program.fragmentShader();
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, image.width.toDouble())
      ..setFloat(3, image.height.toDouble())
      ..setFloat(4, switch (fit) {
        BoxFit.contain => 1.0,
        BoxFit.cover => 2.0,
        _ => 0.0,
      })
      // Smoothed sampling: the default (none) picks the nearest texel, which
      // pixelates a frame drawn at any size but its own.
      ..setImageSampler(0, image, filterQuality: FilterQuality.medium);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_GifPainter oldDelegate) =>
      oldDelegate.frame != frame || oldDelegate.fit != fit;
}
