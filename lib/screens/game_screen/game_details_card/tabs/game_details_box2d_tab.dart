import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../providers/file_provider.dart';
import '../../../../themes/corner_radii.dart';

class GameDetailsBox2dTab extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;

  /// Bumped when a scrape rewrites the artwork. It keys the image so a
  /// re-scraped box art is resolved again instead of being redrawn from the
  /// copy this widget already holds.
  final int imageVersion;

  /// How far above the card's bottom edge the art stops, in the same unscaled
  /// units as the other offsets. The card works it out from what the footer
  /// under it will draw, so the box art grows into the room a missing
  /// achievements pill leaves behind instead of being scaled down to clear
  /// one that is not there.
  final double bottomOffset;

  const GameDetailsBox2dTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    this.imageVersion = 0,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsBox2dTab> createState() => _GameDetailsBox2dTabState();
}

class _GameDetailsBox2dTabState extends State<GameDetailsBox2dTab> {
  /// Shape held for the first frame of a box art never measured before.
  ///
  /// Real box art is rarely this ratio, which is the whole reason the values
  /// below are cached: drawn cold, the art visibly snaps to its true shape a
  /// frame later.
  static const double _placeholderAspectRatio = 3 / 4;

  /// Ratios already measured, keyed by file and artwork version, kept alive
  /// across mounts.
  ///
  /// This panel is only in the tree while its tab is on screen, so its state
  /// is thrown away every time the user walks off the tab. Without somewhere
  /// outside the widget to remember them, every single visit would start at
  /// the placeholder and jump — a pop made obvious now that the panel slides
  /// in rather than cutting.
  static final Map<String, double> _aspectRatioCache = <String, double>{};

  double _imageAspectRatio = _placeholderAspectRatio;

  /// The cache key this state has already resolved, so a rebuild that changes
  /// nothing about the artwork does no work.
  String? _syncedKey;

  ImageStream? _currentImageStream;
  ImageStreamListener? _currentImageListener;

  String get _box2dPath => widget.game.getImagePath(
    widget.system.primaryFolderName,
    'box2d',
    widget.fileProvider,
  );

  /// Artwork identity: the file, plus the version the card bumps when a scrape
  /// rewrites it, so new art is measured again rather than drawn at the old
  /// shape.
  String _cacheKey(String path) => '$path|${widget.imageVersion}';

  @override
  void initState() {
    super.initState();
    _syncAspectRatio();
  }

  @override
  void didUpdateWidget(covariant GameDetailsBox2dTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAspectRatio();
  }

  /// Adopts the known ratio for the current artwork, or measures it.
  ///
  /// Runs from [initState] and [didUpdateWidget], both of which are followed
  /// by a build, so the field is assigned directly rather than through
  /// `setState` — the point is for the very first paint to already be right.
  void _syncAspectRatio() {
    final String path = _box2dPath;
    final String key = _cacheKey(path);
    if (key == _syncedKey) return;

    final double? known = _aspectRatioCache[key];
    if (known != null) {
      // Measured before: nothing to decode, and nothing to correct later.
      _removeImageListener();
      _imageAspectRatio = known;
      _syncedKey = key;
      return;
    }

    // Unknown art keeps whatever shape is on screen rather than snapping back
    // to the placeholder, which matters most when the user walks the games
    // list and the panel is handed one game after another.
    //
    // The key is only latched once there is a file to measure: art that lands
    // later without a version bump has to stay measurable.
    if (_loadImageAspectRatio(path)) _syncedKey = key;
  }

  /// Starts measuring [path], returning whether there was anything to measure.
  bool _loadImageAspectRatio(String path) {
    if (path.isEmpty) return false;

    final File file = File(path);
    if (!file.existsSync()) return false;

    _removeImageListener();

    final String key = _cacheKey(path);
    final Image image = Image.file(file);
    final ImageStream stream = image.image.resolve(const ImageConfiguration());

    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      final double aspectRatio = info.image.width / info.image.height;
      if (aspectRatio <= 0) return;

      // Recorded even if this panel has already gone: the next visit is
      // exactly the one that benefits.
      _aspectRatioCache[key] = aspectRatio;

      if (!mounted || _imageAspectRatio == aspectRatio) return;

      void update() {
        if (mounted) setState(() => _imageAspectRatio = aspectRatio);
      }

      if (synchronousCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) => update());
      } else {
        update();
      }
    });

    stream.addListener(listener);
    _currentImageStream = stream;
    _currentImageListener = listener;
    return true;
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
    final box2dPath = _box2dPath;
    final box2dExists = File(box2dPath).existsSync();

    return Positioned(
      left: 48.r,
      right: 48.r,
      top: 72.r,
      bottom: widget.bottomOffset.r + 20.r,
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
              aspectRatio: _imageAspectRatio,
              child: box2dExists
                  ? Image.file(
                      File(box2dPath),
                      key: ValueKey(
                        'box2d_${widget.game.romPath ?? widget.game.romname}'
                        '_v${widget.imageVersion}',
                      ),
                      fit: BoxFit.contain,
                      cacheWidth: 640,
                    )
                  : Center(
                      child: Icon(
                        Icons.inventory_2_outlined,
                        size: 48.r,
                        color: Colors.white24,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
