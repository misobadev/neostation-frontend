import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/sfx_service.dart';
import '../../../../themes/corner_radii.dart';

class GameDetailsScreenshotVideoTab extends StatefulWidget {
  final String screenshotPath;
  final bool isVideoDelayActive;
  final VideoPlayerController? videoController;
  final int imageVersion;
  final VoidCallback onToggleVideoMute;

  /// Where the footer starts, so the media stops there and no lower.
  ///
  /// The other three panels have taken this from the card since the footer's
  /// height stopped being a constant; this one kept a hardcoded 110 and went
  /// on reserving room for a row that had shrunk to 90. Since a screenshot in
  /// this panel is almost always height-bound — 4:3 art in a panel close to
  /// 2:1 — every unit reserved here came straight off the image's width.
  final double bottomOffset;

  const GameDetailsScreenshotVideoTab({
    super.key,
    required this.screenshotPath,
    required this.isVideoDelayActive,
    this.videoController,
    required this.imageVersion,
    required this.onToggleVideoMute,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsScreenshotVideoTab> createState() =>
      _GameDetailsScreenshotVideoTabState();
}

class _GameDetailsScreenshotVideoTabState
    extends State<GameDetailsScreenshotVideoTab> {
  final Map<String, double> _imageAspectRatios = {};

  ImageStream? _currentImageStream;
  ImageStreamListener? _currentImageListener;

  void _loadImageAspectRatio(String path) {
    if (_imageAspectRatios.containsKey(path) || path.isEmpty) return;

    final File file = File(path);
    if (!file.existsSync()) return;

    _removeImageListener();

    final Image image = Image.file(file);
    final ImageStream stream = image.image.resolve(const ImageConfiguration());

    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      if (!mounted) return;
      final double aspectRatio = info.image.width / info.image.height;
      if (aspectRatio <= 0 || (_imageAspectRatios[path] == aspectRatio)) {
        return;
      }

      void update() {
        setState(() {
          _imageAspectRatios[path] = aspectRatio;
        });
      }

      if (synchronousCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) update();
        });
      } else {
        update();
      }
    });

    stream.addListener(listener);
    _currentImageStream = stream;
    _currentImageListener = listener;
  }

  void _removeImageListener() {
    if (_currentImageStream != null && _currentImageListener != null) {
      _currentImageStream!.removeListener(_currentImageListener!);
      _currentImageStream = null;
      _currentImageListener = null;
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenshotPath = widget.screenshotPath;

    final bool hasVideo =
        widget.videoController != null &&
        widget.videoController!.value.isInitialized;

    if (screenshotPath.isNotEmpty) {
      _loadImageAspectRatio(screenshotPath);
    }

    double mediaAspectRatio = 16 / 9;

    if (!widget.isVideoDelayActive && hasVideo) {
      mediaAspectRatio = widget.videoController!.value.aspectRatio;
    } else if (_imageAspectRatios.containsKey(screenshotPath)) {
      mediaAspectRatio = _imageAspectRatios[screenshotPath]!;
    }

    if (mediaAspectRatio <= 0 || mediaAspectRatio.isNaN) {
      mediaAspectRatio = 16 / 9;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        48.r,
        72.r,
        48.r,
        widget.bottomOffset.r + 20.r,
      ),
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                BorderRadius.circular(14.r),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.3),
                blurRadius: 3.r,
                offset: Offset(3.0.r, 3.0.r),
              ),
            ],
            color: Colors.transparent,
          ),
          child: ClipRRect(
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                BorderRadius.circular(14.r),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: mediaAspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!widget.isVideoDelayActive &&
                      hasVideo &&
                      widget.videoController!.value.isInitialized &&
                      widget.videoController!.value.size.width > 0 &&
                      widget.videoController!.value.size.height > 0) ...[
                    Consumer<SqliteConfigProvider>(
                      builder: (context, config, child) {
                        return VideoPlayer(widget.videoController!);
                      },
                    ),
                  ] else if (File(screenshotPath).existsSync()) ...[
                    Image.file(
                      File(screenshotPath),
                      height: double.infinity,
                      cacheHeight: 640,
                      key: ValueKey(
                        '${screenshotPath}_fg_${widget.imageVersion}',
                      ),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ] else
                    Center(
                      child: Icon(
                        Symbols.videogame_asset_rounded,
                        size: 48.r,
                        color: Colors.white24,
                      ),
                    ),

                  if (!widget.isVideoDelayActive && hasVideo)
                    Positioned(
                      bottom: 8.r,
                      right: 8.r,
                      child: ExcludeFocus(
                        child: Material(
                          color: Colors.black54,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusExternal ??
                              BorderRadius.circular(14.r),
                          child: InkWell(
                            onTap: () {
                              SfxService().playNavSound();
                              widget.onToggleVideoMute();
                            },
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            borderRadius:
                                Theme.of(
                                  context,
                                ).extension<CornerRadii>()?.radiusInternal ??
                                BorderRadius.circular(14.r),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8.r,
                                vertical: 4.r,
                              ),
                              child: Consumer<SqliteConfigProvider>(
                                builder: (context, configProvider, child) {
                                  final isMuted =
                                      !configProvider.config.videoSound;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Image.asset(
                                        'assets/images/gamepad/Xbox_View_button.png',
                                        width: 14.r,
                                        height: 14.r,
                                        color: Colors.white,
                                      ),
                                      SizedBox(width: 4.r),
                                      Icon(
                                        isMuted
                                            ? Symbols.volume_off_rounded
                                            : Symbols.volume_up_rounded,
                                        size: 12.r,
                                        color: Colors.white,
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
