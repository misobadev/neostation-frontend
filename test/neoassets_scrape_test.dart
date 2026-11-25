import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/models/neoassets_scrape_models.dart';
import 'package:neostation/repositories/neoassets_settings_repository.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_client.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_system_map.dart';

/// A `/api/v1/scrape/games` body as the NeoAssets server returns it.
Map<String, dynamic> _gameJson() => {
  'id': '5d5166e8-6209-4acf-bde6-2448c6e468de',
  'system_id': 'snes',
  'name': 'Super Mario World',
  'developer': 'Nintendo',
  'publisher': 'Nintendo',
  'genre': 'Platformer',
  'rating': 9,
  'release_year': 1991,
  'release_month': 8,
  'description_en': 'Mario saves the princess.',
  'description_es': 'Mario salva a la princesa.',
  'description_fr': '',
  'description_ja': 'マリオ',
  'names': [
    {'region': 'USA', 'name': 'Super Mario World'},
    {'region': 'Japan', 'name': 'Super Mario World: Super Mario Bros. 4'},
  ],
  'media': [
    {'kind': 'logo', 'url': 'https://cdn.example/a.webp', 'mime': 'image/webp'},
    {
      'kind': 'cover',
      'url': 'https://cdn.example/b.webp',
      'mime': 'image/webp',
      'region': 'USA',
    },
    {
      'kind': 'cover',
      'url': 'https://cdn.example/c.webp',
      'mime': 'image/webp',
      'region': 'Japan',
    },
    {'kind': 'video', 'url': 'https://cdn.example/d.mp4', 'mime': 'video/mp4'},
  ],
};

void main() {
  group('NeoAssetsGame.fromJson', () {
    test('keeps only translated descriptions', () {
      final game = NeoAssetsGame.fromJson(_gameJson(), matchedBy: 'hash');
      expect(game.descriptions.keys, containsAll(['en', 'es', 'ja']));
      expect(game.descriptions.containsKey('fr'), isFalse);
      expect(game.matchedBy, 'hash');
    });

    test('picks the first media of a kind and its extension', () {
      final game = NeoAssetsGame.fromJson(_gameJson());
      expect(game.firstMedia('cover')!.url, 'https://cdn.example/b.webp');
      expect(game.firstMedia('cover')!.extension, 'webp');
      expect(game.firstMedia('video')!.extension, 'mp4');
      expect(game.firstMedia('fanart'), isNull);
    });
  });

  group('NeoAssetsScrapeService.metadataFor', () {
    test('maps to the metadata table columns', () {
      final game = NeoAssetsGame.fromJson(_gameJson());
      final metadata = NeoAssetsScrapeService.metadataFor('smw.sfc', game);
      expect(metadata['filename'], 'smw.sfc');
      expect(metadata['real_name'], 'Super Mario World');
      expect(metadata['description_en'], 'Mario saves the princess.');
      expect(metadata['description_es'], 'Mario salva a la princesa.');
      expect(metadata['description_ja'], 'マリオ');
      // An empty translation is not written.
      expect(metadata.containsKey('description_fr'), isFalse);
      // Stored on ScreenScraper's 0..20 scale.
      expect(metadata['rating'], 18.0);
      expect(metadata['release_date'], DateTime(1991, 8).toIso8601String());
      expect(metadata['genre'], 'Platformer');
    });

    test('leaves an unrated, undated game without those columns', () {
      final json = _gameJson()
        ..['rating'] = 0
        ..['release_year'] = null;
      final metadata = NeoAssetsScrapeService.metadataFor(
        'x.sfc',
        NeoAssetsGame.fromJson(json),
      );
      expect(metadata.containsKey('rating'), isFalse);
      expect(metadata.containsKey('release_date'), isFalse);
    });
  });

  group('language', () {
    test('titles the game after the app language release', () {
      final game = NeoAssetsGame.fromJson(_gameJson());
      expect(
        NeoAssetsScrapeService.metadataFor(
          'smw.sfc',
          game,
          language: 'ja',
        )['real_name'],
        'Super Mario World: Super Mario Bros. 4',
      );
      final en = NeoAssetsScrapeService.metadataFor('smw.sfc', game);
      expect(en['real_name'], 'Super Mario World');
      expect(en['regional_names'], contains('Japan'));
    });

    test('prefers the cover of the language region', () {
      final game = NeoAssetsGame.fromJson(_gameJson());
      expect(
        game.firstMedia('cover', regions: ['Japan', 'World', 'USA'])!.url,
        'https://cdn.example/c.webp',
      );
      expect(game.firstMedia('cover')!.url, 'https://cdn.example/b.webp');
    });
  });

  group('NeoAssetsAccount', () {
    test('reads a guest with its threads beside the null user', () {
      final account = NeoAssetsAccount.fromJson({
        'subject': 'guest',
        'user': null,
        'threads': 2,
        'quota': {'daily_limit': 2000, 'used': 5},
      });
      expect(account.isGuest, isTrue);
      expect(account.isUser, isFalse);
      expect(account.threads, 2);
      expect(NeoAssetsAccount.fromJson(account.toJson()).isGuest, isTrue);
    });

    test('reads a user, and caps a session at 20 workers', () {
      final account = NeoAssetsAccount.fromJson({
        'subject': 'user',
        'user': {'username': 'misoba', 'threads': 20},
        'threads': 20,
        'quota': {'daily_limit': 20000},
      });
      expect(account.isGuest, isFalse);
      expect(account.username, 'misoba');
      // An older server with a daily cap.
      expect(account.hasNoDailyLimit, isFalse);
      expect(account.dailyLimit, 20000);
      expect(NeoAssetsScrapeService.workersFor(account), 20);
      expect(
        NeoAssetsScrapeService.workersFor(
          NeoAssetsAccount.fromJson({
            'user': {'username': 'x', 'threads': 40},
          }),
        ),
        20,
      );
    });
  });

  group('NeoAssetsAccount without a daily limit', () {
    Map<String, dynamic> body() => {
      'subject': 'user',
      'user': {'username': 'misoba', 'threads': 10},
      'threads': 10,
      'rate_per_minute': 600,
      'quota': {
        'unlimited': true,
        'daily_limit': null,
        'used': 1234,
        'resets_at': '2026-11-26T00:00:00Z',
      },
    };

    test('reads the unlimited quota and the rate per minute', () {
      final account = NeoAssetsAccount.fromJson(body());
      expect(account.unlimited, isTrue);
      expect(account.dailyLimit, isNull);
      expect(account.hasNoDailyLimit, isTrue);
      expect(account.used, 1234);
      expect(account.threads, 10);
      expect(account.ratePerMinute, 600);
    });

    test('survives the prefs cache round trip', () {
      final cached = NeoAssetsAccount.fromJson(
        NeoAssetsAccount.fromJson(body()).toJson(),
      );
      expect(cached.unlimited, isTrue);
      expect(cached.dailyLimit, isNull);
      expect(cached.used, 1234);
      expect(cached.ratePerMinute, 600);
      expect(cached.resetsAt, DateTime.utc(2026, 11, 26));
      expect(cached.toJson()['quota'], isNot(contains('remaining')));
    });

    test('a guest has its own, slower rate', () {
      final account = NeoAssetsAccount.fromJson({
        'subject': 'guest',
        'user': null,
        'threads': 1,
        'rate_per_minute': 30,
        'quota': {'unlimited': true, 'daily_limit': null, 'used': 3},
      });
      expect(account.isGuest, isTrue);
      expect(account.ratePerMinute, 30);
      expect(account.hasNoDailyLimit, isTrue);
    });

    test('defaults to no rate and a capped quota when fields are missing', () {
      final account = NeoAssetsAccount.fromJson({
        'user': {'username': 'x', 'threads': 2},
        'quota': {'daily_limit': 2000, 'used': 1},
      });
      expect(account.unlimited, isFalse);
      expect(account.ratePerMinute, 0);
      expect(account.hasNoDailyLimit, isFalse);
    });
  });

  group('NeoAssetsSettingsRepository', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('starts on new content only with every media type', () async {
      expect(await NeoAssetsSettingsRepository.getScrapeMode(), 'new_only');
      expect(
        await NeoAssetsSettingsRepository.getMediaTypes(),
        NeoAssetsSettingsRepository.defaultMediaTypes,
      );
      expect(await NeoAssetsSettingsRepository.getSystems(), isEmpty);
    });

    test('keeps its own mode, media types and systems', () async {
      await NeoAssetsSettingsRepository.saveScrapeMode('all');
      await NeoAssetsSettingsRepository.saveMediaTypes(['box2D']);
      await NeoAssetsSettingsRepository.saveSystems({'snes': false});
      await NeoAssetsSettingsRepository.saveSystems({'nes': true});
      expect(await NeoAssetsSettingsRepository.getScrapeMode(), 'all');
      expect(await NeoAssetsSettingsRepository.getMediaTypes(), ['box2D']);
      expect(await NeoAssetsSettingsRepository.getSystems(), {
        'snes': false,
        'nes': true,
      });
    });
  });

  group('NeoAssetsScrapeClient.retryDelay', () {
    test('honours Retry-After within bounds', () {
      expect(
        NeoAssetsScrapeClient.retryDelay('2', 0),
        const Duration(seconds: 2),
      );
      expect(
        NeoAssetsScrapeClient.retryDelay('0', 0),
        const Duration(seconds: 1),
      );
      expect(
        NeoAssetsScrapeClient.retryDelay('90', 0),
        const Duration(seconds: 90),
      );
      expect(
        NeoAssetsScrapeClient.retryDelay('3600', 0),
        const Duration(seconds: 120),
      );
    });

    test('backs off without a Retry-After', () {
      expect(
        NeoAssetsScrapeClient.retryDelay(null, 0),
        const Duration(seconds: 2),
      );
      expect(
        NeoAssetsScrapeClient.retryDelay('', 2),
        const Duration(seconds: 8),
      );
      expect(
        NeoAssetsScrapeClient.retryDelay(null, 20),
        const Duration(seconds: 64),
      );
    });
  });

  group('NeoAssetsScrapeClient.failureFor', () {
    test('tells the daily quota from transient throttles', () {
      expect(
        NeoAssetsScrapeClient.failureFor(429, 'daily scrape quota exceeded'),
        NeoAssetsScrapeFailure.quotaExceeded,
      );
      expect(
        NeoAssetsScrapeClient.failureFor(
          429,
          'rate limit exceeded: this account allows 200 requests per minute',
        ),
        NeoAssetsScrapeFailure.retryLater,
      );
      expect(
        NeoAssetsScrapeClient.failureFor(503, 'server busy, retry shortly'),
        NeoAssetsScrapeFailure.retryLater,
      );
      // Global open-thread caps full.
      expect(
        NeoAssetsScrapeClient.failureFor(503, 'too many open requests'),
        NeoAssetsScrapeFailure.retryLater,
      );
      expect(
        NeoAssetsScrapeClient.failureFor(429, 'too many concurrent requests'),
        NeoAssetsScrapeFailure.retryLater,
      );
    });

    test('attributes auth refusals', () {
      expect(
        NeoAssetsScrapeClient.failureFor(401, 'invalid user API key'),
        NeoAssetsScrapeFailure.invalidKey,
      );
      expect(
        NeoAssetsScrapeClient.failureFor(401, 'invalid developer credentials'),
        NeoAssetsScrapeFailure.appRejected,
      );
      expect(
        NeoAssetsScrapeClient.failureFor(403, 'email not verified'),
        NeoAssetsScrapeFailure.emailNotVerified,
      );
    });
  });

  group('NeoAssetsSystemMap', () {
    test('maps regional twins and arcade sets', () {
      expect(
        NeoAssetsSystemMap.selectorFor('snes'),
        const NeoAssetsSystemSelector.system('snes'),
      );
      expect(
        NeoAssetsSystemMap.selectorFor('md'),
        const NeoAssetsSystemSelector.system('genesis'),
      );
      expect(
        NeoAssetsSystemMap.selectorFor('fbneo'),
        const NeoAssetsSystemSelector.group('mame-fbneo'),
      );
      expect(NeoAssetsSystemMap.selectorFor('steam'), isNull);
      expect(NeoAssetsSystemMap.selectorFor('android'), isNull);
    });

    test('every mapped NeoStation system exists in assets/systems', () {
      final ids = Directory('assets/systems')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
          .toSet();
      // gen-hacks is genesis-hacks.json's id.
      ids.add('gen-hacks');
      final supported = ids.where(NeoAssetsSystemMap.supports).toSet();
      expect(supported.length, greaterThan(80));
      for (final id in ['md', 'sfc', 'fc', 'pce', 'mame', 'arc']) {
        expect(ids, contains(id));
        expect(NeoAssetsSystemMap.supports(id), isTrue, reason: id);
      }
    });
  });
}
