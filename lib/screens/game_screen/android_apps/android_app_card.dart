import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../models/game_model.dart';
import '../../../services/android_service.dart';
import '../../../services/sfx_service.dart';
import '../../../themes/corner_radii.dart';
import '../../../widgets/neo_glass.dart';
import '../../../utils/performance_mode.dart';

/// One Android app card, built from the same chrome as [SystemCard].
///
/// The app icon sits centred in the artwork area and the app's short name goes
/// in the footer strip where a system card puts its console logo.
class AndroidAppCard extends StatefulWidget {
  const AndroidAppCard({
    super.key,
    required this.app,
    required this.isSelected,
    required this.onTap,
  });

  final GameModel app;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<AndroidAppCard> createState() => _AndroidAppCardState();
}

class _AndroidAppCardState extends State<AndroidAppCard> {
  /// Icons already read this session, keyed by package.
  ///
  /// The selection spring remounts the card subtree on every cursor move, so
  /// without this cache the icon was fetched again and the card flashed the
  /// spinner while the previous card settled. Keeping the bytes makes a
  /// remount paint instantly.
  static final Map<String, Uint8List?> _iconCache = {};
  static final Map<String, Future<Uint8List?>> _iconRequests = {};

  Uint8List? _iconBytes;
  bool _isLoadingIcon = true;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    final packageName = widget.app.romPath;
    if (packageName == null || packageName.isEmpty) {
      if (mounted) setState(() => _isLoadingIcon = false);
      return;
    }

    if (_iconCache.containsKey(packageName)) {
      _iconBytes = _iconCache[packageName];
      _isLoadingIcon = false;
      return;
    }

    final request = _iconRequests.putIfAbsent(
      packageName,
      () => AndroidService.getAppIcon(packageName),
    );
    Uint8List? bytes;
    try {
      bytes = await request;
      _iconCache[packageName] = bytes;
    } finally {
      // A failure is not cached, so a later mount can retry instead of
      // inheriting a rejected future forever.
      _iconRequests.remove(packageName);
    }
    if (mounted) {
      setState(() {
        _iconBytes = bytes;
        _isLoadingIcon = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>();
    final outerRadius = radii?.radiusExternal ?? BorderRadius.circular(14.r);
    final outerRadiusPx = radii?.radiusExternalRadius ?? 14.r;
    final innerRadius = radii?.radiusInternal ?? BorderRadius.circular(9.r);
    const artworkInset = 4.0;
    final appName = widget.app.name.isEmpty
        ? (widget.app.realname.isEmpty
              ? widget.app.romname
              : widget.app.realname)
        : widget.app.name;

    return Padding(
      padding: EdgeInsets.all(2.r),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: NeoGlassRim(
          cornerRadius: outerRadiusPx,
          child: Container(
            decoration: BoxDecoration(
              color: widget.isSelected ? scheme.secondary : scheme.surface,
              borderRadius: outerRadius,
              boxShadow: context.performanceMode
                  ? null
                  : [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: 0.1),
                        blurRadius: 4.r,
                        offset: Offset(2.0.r, 2.0.r),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: innerRadius,
              child: InkWell(
                onTap: () {
                  // The grid's tap handler turns this into a launch when the
                  // card is already selected.
                  if (widget.isSelected) {
                    SfxService().playEnterSound();
                  } else {
                    SfxService().playNavSound();
                  }
                  widget.onTap();
                },
                canRequestFocus: false,
                focusColor: Colors.transparent,
                hoverColor: Colors.transparent,
                highlightColor: Colors.transparent,
                splashColor: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: artworkInset.r,
                    left: artworkInset.r,
                    right: artworkInset.r,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Same footer proportion as SystemCard.
                      final footerHeight = math.max(
                        28.r,
                        constraints.maxWidth * 0.24,
                      );
                      return Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: innerRadius,
                              child: LayoutBuilder(
                                builder: (context, art) {
                                  final iconSize =
                                      (math.min(art.maxWidth, art.maxHeight) *
                                              0.46)
                                          .clamp(28.r, 120.r)
                                          .toDouble();
                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: scheme.surfaceContainerHighest
                                            .withValues(alpha: 0.35),
                                      ),
                                      Center(
                                        child: _buildIcon(
                                          theme,
                                          iconSize: iconSize,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                          SizedBox(
                            height: footerHeight,
                            width: double.infinity,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8.r,
                                vertical: 4.r,
                              ),
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Text(
                                  appName,
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: widget.isSelected
                                        ? scheme.onSecondary
                                        : scheme.onSurface,
                                    fontSize: 14.r,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4.r,
                                  ),
                                ),
                              ),
                            ),
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
      ),
    );
  }

  Widget _buildIcon(ThemeData theme, {required double iconSize}) {
    if (_isLoadingIcon) {
      return SizedBox(
        width: 16.r,
        height: 16.r,
        child: CircularProgressIndicator(
          strokeWidth: 2.r,
          valueColor: AlwaysStoppedAnimation<Color>(
            theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
      );
    }

    if (_iconBytes != null) {
      return Image.memory(
        _iconBytes!,
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }

    return Opacity(
      opacity: 0.5,
      child: Icon(
        Symbols.android_rounded,
        size: iconSize,
        color: theme.colorScheme.onSurface,
      ),
    );
  }
}
