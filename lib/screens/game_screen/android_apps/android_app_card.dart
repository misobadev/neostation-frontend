import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../models/game_model.dart';
import '../../../services/android_service.dart';

/// A specialized widget for rendering a single Android application icon in a grid.
///
/// Handles asynchronous icon retrieval from the Android platform and implements
/// a 'cardless' UI design where the focus is strictly on the application's branding.
class AndroidAppCard extends StatefulWidget {
  final GameModel app;
  final bool isSelected;
  final VoidCallback onTap;

  const AndroidAppCard({
    super.key,
    required this.app,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<AndroidAppCard> createState() => _AndroidAppCardState();
}

class _AndroidAppCardState extends State<AndroidAppCard> {
  Uint8List? _iconBytes;
  bool _isLoadingIcon = true;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(skipTraversal: true);
    _loadIcon();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Retrieves the application's native icon via the AndroidService.
  Future<void> _loadIcon() async {
    if (!mounted) return;
    final packageName = widget.app.romPath;
    if (packageName == null || packageName.isEmpty) {
      if (mounted) setState(() => _isLoadingIcon = false);
      return;
    }

    final bytes = await AndroidService.getAppIcon(packageName);
    if (mounted) {
      setState(() {
        _iconBytes = bytes;
        _isLoadingIcon = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        focusNode: _focusNode,
        onTap: widget.onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Center(child: _buildIconStack()),
      ),
    );
  }

  /// Renders the icon with an optional ambient glow when selected.
  Widget _buildIconStack() {
    if (_isLoadingIcon) {
      return SizedBox(
        width: 16.r,
        height: 16.r,
        child: CircularProgressIndicator(
          strokeWidth: 2.r,
          valueColor: AlwaysStoppedAnimation<Color>(
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
      );
    }

    // Standardized icon dimension for a cohesive grid appearance.
    final iconSize = 40.r;

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Selection feedback: Subtle outer ambient glow.
        if (widget.isSelected && _iconBytes != null)
          Container(
            width: iconSize + 10.r,
            height: iconSize + 10.r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.secondary.withValues(alpha: 0.3),
                  blurRadius: 15.r,
                  spreadRadius: 2.r,
                ),
              ],
            ),
          ),

        // Primary branding element.
        if (_iconBytes != null)
          Image.memory(
            _iconBytes!,
            height: iconSize,
            width: iconSize,
            filterQuality: FilterQuality.medium,
            isAntiAlias: true,
            fit: BoxFit.contain,
          )
        else
          Opacity(
            opacity: 0.5,
            child: Icon(Symbols.android_rounded, size: iconSize, color: Colors.white),
          ),
      ],
    );
  }
}
