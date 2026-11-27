import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

import '../models/game_model.dart';
import '../providers/file_provider.dart';
import '../utils/performance_mode.dart';

/// Renders game fanart as a full-screen background for the list and carousel.
class GameFanartBackground extends StatefulWidget {
  /// Null for folder placeholders, which have no fanart.
  final GameModel? game;
  final String systemFolder;
  final FileProvider fileProvider;
  final int artworkVersion;
  final bool performanceMode;
  final Duration duration;
  final Curve switchInCurve;
  final Curve switchOutCurve;
  final bool zoom;

  /// Paint opacity for the image itself when only one image needs blending.
  final Animation<double>? imageOpacity;

  /// Wait for the replacement to decode before bringing it into view.
  final bool waitForImage;

  const GameFanartBackground({
    super.key,
    required this.game,
    required this.systemFolder,
    required this.fileProvider,
    required this.artworkVersion,
    required this.performanceMode,
    this.duration = const Duration(milliseconds: 400),
    this.switchInCurve = Curves.linear,
    this.switchOutCurve = Curves.linear,
    this.zoom = false,
    this.imageOpacity,
    this.waitForImage = false,
  });

  @override
  State<GameFanartBackground> createState() => _GameFanartBackgroundState();
}

class _GameFanartBackgroundState extends State<GameFanartBackground> {
  static const _slowLoadDelay = Duration(milliseconds: 400);

  // Cache misses too: getImagePath probes the filesystem synchronously, so an
  // unrelated rebuild must not repeat the lookup for the same selection.
  (String?, int, _DecodedFanart?)? _backdrop;
  (String?, int, _DecodedFanart?)? _decodedBackdrop;
  bool _firstBackdropReady = false;
  ({
    ResizeImage source,
    int artworkVersion,
    ImageStream stream,
    ImageStreamListener listener,
  })?
  _pendingImage;
  Timer? _slowLoadTimer;

  @override
  void initState() {
    super.initState();
    widget.fileProvider.addListener(_onMediaSourceChanged);
    _resolvePath();
  }

  @override
  void didUpdateWidget(GameFanartBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final providerChanged = widget.fileProvider != oldWidget.fileProvider;
    if (providerChanged) {
      oldWidget.fileProvider.removeListener(_onMediaSourceChanged);
      widget.fileProvider.addListener(_onMediaSourceChanged);
    }
    final selectionChanged =
        widget.game?.romname != oldWidget.game?.romname ||
        widget.systemFolder != oldWidget.systemFolder;
    if (selectionChanged) {
      // A replacement should fade in even if the first selection never drew.
      _backdrop ??= (null, widget.artworkVersion, null);
    }
    if (providerChanged ||
        selectionChanged ||
        widget.artworkVersion != oldWidget.artworkVersion ||
        (widget.waitForImage &&
            widget.performanceMode != oldWidget.performanceMode) ||
        widget.waitForImage != oldWidget.waitForImage) {
      _resolvePath();
    }
  }

  void _resolvePath() {
    final game = widget.game;
    if (game == null) {
      _cancelPendingImage();
      _showBackdrop((null, widget.artworkVersion, null));
      return;
    }
    final path = game.getImagePath(
      widget.systemFolder,
      'fanarts',
      widget.fileProvider,
    );
    if (!File(path).existsSync()) {
      _cancelPendingImage();
      _showBackdrop((null, widget.artworkVersion, null));
      return;
    }

    if (!widget.waitForImage) {
      _cancelPendingImage();
      _showBackdrop((path, widget.artworkVersion, null));
      return;
    }
    final image = _imageProvider(path);
    final version = widget.artworkVersion;
    if (_pendingImage?.source == image &&
        _pendingImage?.artworkVersion == version) {
      return;
    }
    _cancelPendingImage();
    if (_backdrop?.$1 == path &&
        _backdrop?.$2 == version &&
        _backdrop?.$3?.source == image) {
      _cancelSlowLoadTimer();
      return;
    }

    // The deadline belongs to the displayed backdrop, even if the pending
    // image changes while that backdrop is stale.
    if (_backdrop?.$1 != null) {
      _slowLoadTimer ??= Timer(_slowLoadDelay, () {
        setState(() => _showBackdrop((null, widget.artworkVersion, null)));
      });
    }
    final stream = image.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        _stageDecodedBackdrop(stream, (
          path,
          version,
          _DecodedFanart(image, stream.completer!),
        ));
      },
      onError: (_, _) {
        _stageDecodedBackdrop(stream, (null, version, null));
      },
      reportErrors: false,
    );
    _pendingImage = (
      source: image,
      artworkVersion: version,
      stream: stream,
      listener: listener,
    );
    stream.addListener(listener);
  }

  void _showBackdrop((String?, int, _DecodedFanart?) backdrop) {
    _cancelSlowLoadTimer();
    _backdrop = backdrop;
  }

  void _cancelSlowLoadTimer() {
    _slowLoadTimer?.cancel();
    _slowLoadTimer = null;
  }

  ResizeImage _imageProvider(String path) => ResizeImage(
    FileImage(File(path)),
    width: performanceCacheWidth(1920, performanceMode: widget.performanceMode),
  );

  void _stageDecodedBackdrop(
    ImageStream stream,
    (String?, int, _DecodedFanart?) backdrop,
  ) {
    if (!mounted || _pendingImage?.stream != stream) return;
    setState(() => _decodedBackdrop = backdrop);
    // Keep the decoded stream alive through the frame that mounts Image.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingImage?.stream == stream) _cancelPendingImage();
    });
  }

  void _cancelPendingImage() {
    _decodedBackdrop = null;
    final pending = _pendingImage;
    _pendingImage = null;
    pending?.stream.removeListener(pending.listener);
  }

  void _onMediaSourceChanged() => setState(_resolvePath);

  static Widget _zoomTransition(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(
          begin: 1,
          end: 1.1,
        ).chain(CurveTween(curve: Curves.easeOut)).animate(animation),
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    widget.fileProvider.removeListener(_onMediaSourceChanged);
    _cancelPendingImage();
    _cancelSlowLoadTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A selection update in this frame can discard a superseded decode before
    // it becomes the incoming child of the switcher.
    if (_decodedBackdrop case final decoded?) {
      // On cold entry, mount the first backdrop at full opacity as before.
      if (_backdrop == null) _firstBackdropReady = true;
      _showBackdrop(decoded);
    }
    _decodedBackdrop = null;
    final backdrop = _backdrop ?? (null, widget.artworkVersion, null);
    final (path, version, image) = backdrop;
    final child = SizedBox.expand(
      key: ValueKey((path, version)),
      child: path == null
          ? null
          : Image(
              image: image ?? _imageProvider(path),
              fit: BoxFit.cover,
              opacity: widget.imageOpacity,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    );

    if (widget.performanceMode) return child;

    return AnimatedSwitcher(
      key: ValueKey(_firstBackdropReady),
      duration: widget.duration,
      switchInCurve: widget.switchInCurve,
      switchOutCurve: widget.switchOutCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: widget.zoom
          ? _zoomTransition
          : AnimatedSwitcher.defaultTransitionBuilder,
      child: child,
    );
  }
}

/// Gives Image the ready stream even if an artwork refresh clears the cache
/// between the decoder callback and the frame that mounts the incoming image.
class _DecodedFanart extends ImageProvider<_DecodedFanart> {
  final ResizeImage source;
  final ImageStreamCompleter completer;

  const _DecodedFanart(this.source, this.completer);

  @override
  Future<_DecodedFanart> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _DecodedFanart key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(completer);
  }
}
