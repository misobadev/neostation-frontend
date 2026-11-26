import 'dart:io';

import 'package:video_player/video_player.dart';

import '../repositories/neoassets_settings_repository.dart';
import 'neoassets_scraper/neoassets_scrape_service.dart';

/// Where a game's preview video plays from.
///
/// The file on disk always wins. With no file, a game scraped from NeoAssets
/// with "Streaming video" on plays from its link instead; with the setting
/// off, or no link, there is no video and the image stays.
class PreviewVideoSource {
  PreviewVideoSource._();

  /// How long a streamed video may take to start before the image is kept:
  /// offline, or on a slow network, the preview gives up rather than wait.
  static const Duration streamStartTimeout = Duration(seconds: 10);

  /// The preview's source: [localPath] when [localExists], else [videoUrl]
  /// when streaming is on and it is a web address, else null.
  static Future<String?> resolve({
    required String localPath,
    required bool localExists,
    String? videoUrl,
  }) async {
    if (localExists) return localPath;
    if (!NeoAssetsScrapeService.isStreamableUrl(videoUrl)) return null;
    if (!await NeoAssetsSettingsRepository.getStreamVideo()) return null;
    return videoUrl;
  }

  /// Whether [source] is a link rather than a file.
  static bool isStream(String source) =>
      NeoAssetsScrapeService.isStreamableUrl(source);

  /// A controller for [source], a path or a link from [resolve].
  static VideoPlayerController controllerFor(
    String source, {
    VideoPlayerOptions? videoPlayerOptions,
  }) {
    if (isStream(source)) {
      return VideoPlayerController.networkUrl(
        Uri.parse(source),
        videoPlayerOptions: videoPlayerOptions,
      );
    }
    return VideoPlayerController.file(
      File(source),
      videoPlayerOptions: videoPlayerOptions,
    );
  }

  /// Initializes [controller], giving a stream [streamStartTimeout] to start.
  static Future<void> initialize(
    VideoPlayerController controller,
    String source,
  ) {
    final init = controller.initialize();
    return isStream(source) ? init.timeout(streamStartTimeout) : init;
  }
}
