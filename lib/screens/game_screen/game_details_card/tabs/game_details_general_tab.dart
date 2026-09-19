import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../providers/file_provider.dart';

/// The default view for the game details card, rendering high-fidelity artwork.
///
/// Features a layered composition that includes the game's 'Wheel' logo (or Android app icon)
/// with a simulated aesthetic drop-shadow and smooth fade transitions during selection changes.
class GameDetailsGeneralTab extends StatelessWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;

  /// Bumped when a scrape rewrites the artwork. It keys the wheel images so a
  /// re-scraped logo is resolved again instead of being redrawn from the copy
  /// this widget already holds.
  final int imageVersion;
  final Future<Uint8List?>? androidAppIconFuture;

  const GameDetailsGeneralTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    this.imageVersion = 0,
    this.androidAppIconFuture,
  });

  @override
  Widget build(BuildContext context) {
    final imageSystemFolder = system.primaryFolderName;
    final wheelPath = game.getImagePath(
      imageSystemFolder,
      'wheels',
      fileProvider,
    );
    final wheelExists = File(wheelPath).existsSync();

    return Positioned.fill(
      left: 10.r,
      right: 10.r,
      top: 44.r,
      bottom: 88.r,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The details panel becomes narrow on square devices. Keep the
          // primary artwork visible inside it instead of letting its design
          // size overflow into the list pane.
          final artworkWidth = math.min(280.r, constraints.maxWidth * 0.9);
          final artworkHeight = math.min(140.r, constraints.maxHeight * 0.55);

          return Stack(
            fit: StackFit.expand,
            children: [
              // Background Layer: Aesthetic drop-shadow simulated via offset translation and black tint.
              Positioned.fill(
                child: Center(
                  child: Transform.translate(
                    offset: Offset(6.r, 6.r),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutQuint,
                      switchOutCurve: Curves.easeInQuint,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                      child: wheelExists
                          ? Image.file(
                              File(wheelPath),
                              key: ValueKey(
                                'wheel_shadow_${game.romPath ?? game.romname}'
                                '_v$imageVersion',
                              ),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.low,
                              cacheWidth: 256,
                              isAntiAlias: false,
                              color: Theme.of(
                                context,
                              ).colorScheme.shadow.withValues(alpha: 0.5),
                              height: artworkHeight,
                              width: artworkWidth,
                            )
                          : (Platform.isAndroid &&
                                (system.folderName == 'android'))
                          ? FutureBuilder<Uint8List?>(
                              key: ValueKey(
                                'icon_shadow_${game.romPath ?? game.romname}',
                              ),
                              future: androidAppIconFuture,
                              builder: (context, snapshot) {
                                if (snapshot.hasData && snapshot.data != null) {
                                  return Image.memory(
                                    snapshot.data!,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.low,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.shadow.withValues(alpha: 0.7),
                                    cacheWidth: 32,
                                    height: math.min(60.r, artworkHeight),
                                    width: math.min(60.r, artworkWidth),
                                    alignment: Alignment.center,
                                  );
                                }
                                return const SizedBox();
                              },
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('empty_wheel_shadow'),
                            ),
                    ),
                  ),
                ),
              ),

              // Foreground Layer: Primary artwork rendering.
              Positioned.fill(
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutQuint,
                    switchOutCurve: Curves.easeInQuint,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: wheelExists
                        ? Image.file(
                            File(wheelPath),
                            key: ValueKey(
                              'wheel_${game.romPath ?? game.romname}'
                              '_v$imageVersion',
                            ),
                            fit: BoxFit.contain,
                            cacheWidth: 640,
                            height: artworkHeight,
                            width: artworkWidth,
                          )
                        : (Platform.isAndroid &&
                              (system.folderName == 'android'))
                        ? FutureBuilder<Uint8List?>(
                            key: ValueKey(
                              'icon_${game.romPath ?? game.romname}',
                            ),
                            future: androidAppIconFuture,
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.contain,
                                  cacheWidth: 32,
                                  height: math.min(60.r, artworkHeight),
                                  width: math.min(60.r, artworkWidth),
                                  alignment: Alignment.center,
                                );
                              }
                              return const SizedBox();
                            },
                          )
                        : const SizedBox.shrink(key: ValueKey('empty_wheel')),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
