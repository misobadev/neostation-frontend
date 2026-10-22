import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ra_catalogue_game.dart';
import '../repositories/retro_achievements_repository.dart';
import 'logger_service.dart';

/// Downloads complete console catalogues before committing any replacement.
/// API failures deliberately retain the last successful local catalogue.
class RaCatalogueService {
  static const staleAfter = Duration(days: 1);
  static const pageSize = 500;
  final http.Client _client;
  final Future<void> Function() _pace;

  RaCatalogueService({http.Client? client, Future<void> Function()? pace})
    : _client = client ?? http.Client(),
      _pace =
          pace ??
          (() => Future<void>.delayed(const Duration(milliseconds: 300)));

  void close() => _client.close();

  Future<List<RaCatalogueGame>> fetchConsole(
    int consoleId,
    String apiKey, {
    bool Function()? isCancelled,
  }) async {
    final games = <RaCatalogueGame>[];
    final seen = <int>{};
    for (var offset = 0; ; offset += pageSize) {
      await _pace();
      if (isCancelled?.call() ?? false) throw StateError('Catalogue cancelled');
      final uri =
          Uri.https('retroachievements.org', '/API/API_GetGameList.php', {
            'y': apiKey,
            'i': '$consoleId',
            'f': '1',
            'h': '1',
            'o': '$offset',
            'c': '$pageSize',
          });
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'NeoStation/1.0',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        // Do not include the URI or body: the URI contains the user's key.
        throw StateError('Catalogue HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body);
      if (data is! List || data.length > pageSize) {
        throw const FormatException('Invalid catalogue page');
      }
      for (final item in data) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid catalogue entry');
        }
        final game = RaCatalogueGame.fromJson(item, consoleId);
        if (!seen.add(game.metadata['game_id'] as int)) {
          throw const FormatException('Repeated catalogue game');
        }
        games.add(game);
      }
      if (data.length < pageSize) return games;
      if (offset >= 100000) throw const FormatException('Catalogue too large');
    }
  }

  /// Returns whether pending catalogue changes require a local rematch.
  Future<bool> refresh({
    required String apiKey,
    bool force = false,
    DateTime? now,
    bool Function()? isCancelled,
    void Function()? onFailure,
  }) async {
    if (apiKey.trim().isEmpty) return false;
    final checkedAt = (now ?? DateTime.now()).toUtc();
    final consoles = await RetroAchievementsRepository.getLibraryRaConsoles();
    for (final console in consoles) {
      if (isCancelled?.call() ?? false) break;
      if (!force &&
          console.refreshedAt != null &&
          !console.refreshedAt!.isAfter(checkedAt) &&
          checkedAt.difference(console.refreshedAt!) < staleAfter) {
        continue;
      }
      try {
        final games = await fetchConsole(
          console.id,
          apiKey,
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() ?? false) break;
        await RetroAchievementsRepository.replaceRaCatalogue(
          console.id,
          games,
          checkedAt,
        );
      } catch (_) {
        if (isCancelled?.call() ?? false) break;
        onFailure?.call();
        LoggerService.instance.w(
          'RA catalogue refresh failed for console ${console.id}; retaining local data',
        );
        // Avoid hammering the API after rate limiting, auth or network failure.
        break;
      }
    }
    return RetroAchievementsRepository.hasPendingRaCatalogueMatch();
  }
}
