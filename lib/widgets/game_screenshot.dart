import 'package:flutter/material.dart';
import 'package:neostation/services/logger_service.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:neostation/services/sfx_service.dart';

/// Widget to display game screenshots from local files
class GameScreenshot extends StatelessWidget {
  const GameScreenshot({
    super.key,
    required this.screenshotPath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 8.0,
    this.showPlaceholder = true,
  });

  static final _log = LoggerService.instance;

  final String screenshotPath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: _buildImage(context),
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    // Try the PNG file first
    final pngFile = File(screenshotPath);

    if (pngFile.existsSync()) {
      return _buildImageFromFile(pngFile);
    }

    // If PNG does not exist, try JPG by changing the extension
    final jpgPath = screenshotPath
        .replaceAll('.png', '.jpg')
        .replaceAll('.PNG', '.jpg');
    final jpgFile = File(jpgPath);

    if (jpgFile.existsSync()) {
      return _buildImageFromFile(jpgFile);
    }

    // If neither exists, show placeholder
    return _buildPlaceholder(context);
  }

  Widget _buildImageFromFile(File file) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Background image with blur
        Image.file(
          file,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildPlaceholder(context, isError: true);
          },
        ),
        // Blur filter
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(color: Colors.black.withValues(alpha: 0.2)),
        ),
        // Main image centered while preserving aspect ratio
        Center(
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              _log.e('Error loading screenshot: $error');
              return _buildPlaceholder(context, isError: true);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder(BuildContext context, {bool isError = false}) {
    if (!showPlaceholder) {
      return const SizedBox.shrink();
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Image.asset(
              isError
                  ? 'assets/images/icons/warning-bulk.png'
                  : 'assets/images/icons/image-bulk.png',
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isError ? 'Error loading image' : 'No screenshot',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Widget to display a game screenshot with additional information
class GameScreenshotCard extends StatelessWidget {
  const GameScreenshotCard({
    super.key,
    required this.screenshotPath,
    this.title,
    this.subtitle,
    this.width,
    this.height,
    this.onTap,
    this.focusNode,
  });

  final String screenshotPath;
  final String? title;
  final String? subtitle;
  final double? width;
  final double? height;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 4,
      child: InkWell(
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        focusNode: focusNode,
        onTap: () {
          SfxService().playNavSound();
          onTap?.call();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Screenshot
            Expanded(
              child: GameScreenshot(
                screenshotPath: screenshotPath,
                width: width,
                height: height,
                borderRadius: 0, // The Card already has border radius
              ),
            ),

            // Game information
            if (title != null || subtitle != null)
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(
                        title!,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (title != null && subtitle != null)
                      const SizedBox(height: 4),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
