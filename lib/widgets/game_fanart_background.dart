import 'dart:io';

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
  });

  @override
  State<GameFanartBackground> createState() => _GameFanartBackgroundState();
}

class _GameFanartBackgroundState extends State<GameFanartBackground> {
  // Cache misses too: getImagePath probes the filesystem synchronously, so an
  // unrelated rebuild must not repeat the lookup for the same selection.
  String? _imagePath;

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
    if (providerChanged ||
        widget.game?.romname != oldWidget.game?.romname ||
        widget.systemFolder != oldWidget.systemFolder ||
        widget.artworkVersion != oldWidget.artworkVersion) {
      _resolvePath();
    }
  }

  void _resolvePath() {
    final game = widget.game;
    if (game == null) {
      _imagePath = null;
      return;
    }
    final path = game.getImagePath(
      widget.systemFolder,
      'fanarts',
      widget.fileProvider,
    );
    _imagePath = File(path).existsSync() ? path : null;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _imagePath;
    final child = SizedBox.expand(
      key: ValueKey((path, widget.artworkVersion)),
      child: path == null
          ? null
          : Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: performanceCacheWidth(
                1920,
                performanceMode: widget.performanceMode,
              ),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    );

    if (widget.performanceMode) return child;

    return AnimatedSwitcher(
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
