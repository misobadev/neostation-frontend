import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/retro_achievements_user_awards.dart';
import 'package:neostation/services/retro_achievements_cache.dart';
import 'package:neostation/services/retro_achievements_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('RetroAchievementsService', () {
    test('uses the supplied API key when provided', () {
      expect(RetroAchievementsService.resolveApiKey('demo-key'), 'demo-key');
    });

    test('falls back to the environment key when no API key is supplied', () {
      expect(RetroAchievementsService.resolveApiKey(''), '');
    });

    test(
      'requests newest achievement comments with documented parameters',
      () async {
        late Uri requestedUri;
        final client = MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            '{"Count":1,"Total":1,"Results":[{"User":"Tester","ULID":"01ABC","Submitted":"2024-07-31T11:22:23Z","CommentText":"Helpful"}]}',
            200,
          );
        });

        final result = await RetroAchievementsService.getAchievementComments(
          1234,
          count: 25,
          offset: 50,
          apiKey: 'secret-key',
          client: client,
        );

        expect(requestedUri.path, '/API/API_GetComments.php');
        expect(requestedUri.queryParameters['t'], '2');
        expect(requestedUri.queryParameters['i'], '1234');
        expect(requestedUri.queryParameters['c'], '25');
        expect(requestedUri.queryParameters['o'], '50');
        expect(requestedUri.queryParameters['sort'], '-submitted');
        expect(requestedUri.queryParameters['y'], 'secret-key');
        expect(result.results.single.commentText, 'Helpful');
      },
    );

    test('rejects comments requests without an API key', () async {
      expect(
        () => RetroAchievementsService.getAchievementComments(1234, apiKey: ''),
        throwsStateError,
      );
    });

    test('requests AOTW with the API key and parses an active event', () async {
      late Uri requestedUri;
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '{"Achievement":{"ID":178634,"Title":"Saved Summer","Description":"Win","Points":10,"TrueRatio":11},"Console":{"ID":3,"Title":"SNES"},"Game":{"ID":2865,"Title":"A Game"},"StartAt":"2026-09-01T00:00:00Z","TotalPlayers":427,"Unlocks":[],"UnlocksCount":280,"UnlocksHardcoreCount":268}',
          200,
        );
      });

      final result = await RetroAchievementsService.getAchievementOfTheWeek(
        apiKey: 'secret-key',
        client: client,
      );

      expect(requestedUri.path, '/API/API_GetAchievementOfTheWeek.php');
      expect(requestedUri.queryParameters['y'], 'secret-key');
      expect(result?.achievement.id, 178634);
    });

    test('treats the documented empty AOTW payload as no event', () async {
      final client = MockClient(
        (_) async => http.Response(
          '{"Achievement":{"ID":null},"Console":null,"Game":null,"StartAt":null,"TotalPlayers":0,"Unlocks":[],"UnlocksCount":0,"UnlocksHardcoreCount":0}',
          200,
        ),
      );

      final result = await RetroAchievementsService.getAchievementOfTheWeek(
        apiKey: 'secret-key',
        client: client,
      );

      expect(result, isNull);
    });

    test('requests recent unlocks with documented lookback parameter', () async {
      late Uri requestedUri;
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '[{"Date":"2023-12-27 16:04:50","HardcoreMode":1,"AchievementID":98012,"Title":"Beginner I","Description":"Clear stages 01 - 05 in Quest.","BadgeName":"108302","Points":5,"TrueRatio":25,"Type":null,"Author":"jos","AuthorULID":"ULID","GameTitle":"Pokemon Pinball mini","GameIcon":"/Images/028399.png","GameID":14715,"ConsoleName":"Pokemon Mini","BadgeURL":"/Badge/108302.png","GameURL":"/game/14715"}]',
          200,
        );
      });

      final result = await RetroAchievementsService.getUserRecentAchievements(
        'Scott',
        minutes: 43200,
        apiKey: 'secret-key',
        client: client,
      );

      expect(requestedUri.path, '/API/API_GetUserRecentAchievements.php');
      expect(requestedUri.queryParameters['u'], 'Scott');
      expect(requestedUri.queryParameters['m'], '43200');
      expect(requestedUri.queryParameters['y'], 'secret-key');
      // The dashboard's preview call stays byte-identical to its pre-see-all
      // form: the pagination parameters only exist when asked for.
      expect(requestedUri.queryParameters.containsKey('c'), isFalse);
      expect(requestedUri.queryParameters.containsKey('o'), isFalse);
      expect(result.single.gameId, 14715);
    });

    test('paginates the see-all list with count and offset', () async {
      late Uri requestedUri;
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '[{"Date":"2023-12-27 16:04:50","HardcoreMode":1,"AchievementID":98012,"Title":"Beginner I","Description":"Clear stages 01 - 05 in Quest.","BadgeName":"108302","Points":5,"TrueRatio":25,"Type":null,"Author":"jos","AuthorULID":"ULID","GameTitle":"Pokemon Pinball mini","GameIcon":"/Images/028399.png","GameID":14715,"ConsoleName":"Pokemon Mini","BadgeURL":"/Badge/108302.png","GameURL":"/game/14715"}]',
          200,
        );
      });

      final result = await RetroAchievementsService.getUserRecentAchievements(
        'Scott',
        count: 50,
        offset: 50,
        apiKey: 'secret-key',
        client: client,
      );

      expect(requestedUri.queryParameters['c'], '50');
      expect(requestedUri.queryParameters['o'], '50');
      expect(result.single.gameId, 14715);
    });

    test('requests recently played games with documented pagination', () async {
      late Uri requestedUri;
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '[{"GameID":11332,"ConsoleID":12,"ConsoleName":"PlayStation","Title":"Final Fantasy Origins","ImageIcon":"/Images/060249.png","ImageTitle":"/Images/026707.png","ImageIngame":"/Images/026708.png","ImageBoxArt":"/Images/046257.png","LastPlayed":"2023-10-27 00:30:04","AchievementsTotal":119,"NumPossibleAchievements":119,"PossibleScore":945,"NumAchieved":38,"ScoreAchieved":382,"NumAchievedHardcore":38,"ScoreAchievedHardcore":382}]',
          200,
        );
      });

      final result = await RetroAchievementsService.getUserRecentlyPlayedGames(
        'MaxMilyin',
        count: 12,
        offset: 3,
        apiKey: 'secret-key',
        client: client,
      );

      expect(requestedUri.path, '/API/API_GetUserRecentlyPlayedGames.php');
      expect(requestedUri.queryParameters['u'], 'MaxMilyin');
      expect(requestedUri.queryParameters['c'], '12');
      expect(requestedUri.queryParameters['o'], '3');
      expect(result.single.consoleName, 'PlayStation');
    });

    test('requests completion progress with documented pagination', () async {
      late Uri requestedUri;
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '{"Count":100,"Total":1287,"Results":[{"GameID":20246,"Title":"Knuckles","ImageIcon":"/Images/074560.png","ConsoleID":1,"ConsoleName":"Mega Drive / Genesis","MaxPossible":0,"NumAwarded":0,"NumAwardedHardcore":0,"MostRecentAwardedDate":"2023-10-27T02:52:34+00:00","HighestAwardKind":"beaten-hardcore","HighestAwardDate":"2023-10-27T02:52:34+00:00"}]}',
          200,
        );
      });

      final result = await RetroAchievementsService.getUserCompletionProgress(
        'MaxMilyin',
        count: 100,
        offset: 25,
        apiKey: 'secret-key',
        client: client,
      );

      expect(requestedUri.path, '/API/API_GetUserCompletionProgress.php');
      expect(requestedUri.queryParameters['u'], 'MaxMilyin');
      expect(requestedUri.queryParameters['c'], '100');
      expect(requestedUri.queryParameters['o'], '25');
      expect(result.total, 1287);
      expect(result.results.single.highestAwardKind, 'beaten-hardcore');
    });

    test(
      'requests game leaderboards with pagination and parses top entry',
      () async {
        late Uri requestedUri;
        final client = MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            '{"Count":1,"Total":3,"Results":[{"ID":104370,"RankAsc":false,"Title":"South Island Conqueror","Description":"Highest score","Format":"VALUE","Author":"Scott","AuthorULID":"author-ulid","TopEntry":{"User":"vani11a","ULID":"user-ulid","Score":"390490","FormattedScore":"390,490"}}]}',
            200,
          );
        });

        final page = await RetroAchievementsService.getGameLeaderboards(
          14402,
          count: 1,
          offset: 2,
          apiKey: 'secret-key',
          client: client,
        );

        expect(requestedUri.path, '/API/API_GetGameLeaderboards.php');
        expect(requestedUri.queryParameters['i'], '14402');
        expect(requestedUri.queryParameters['c'], '1');
        expect(requestedUri.queryParameters['o'], '2');
        expect(requestedUri.queryParameters['y'], 'secret-key');
        expect(page.total, 3);
        expect(page.results.single.topEntry?.formattedScore, '390,490');
        expect(page.results.single.rankAsc, isFalse);
      },
    );

    test(
      'requests leaderboard entries with pagination and parses RA dates',
      () async {
        late Uri requestedUri;
        final client = MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            '{"count":1,"total":101,"results":[{"rank":7,"user":"vani11a","ulid":"entry-ulid","score":390490,"formattedScore":"390,490","dateSubmitted":"2024-07-25T15:51:00+00:00"}]}',
            200,
          );
        });

        final page = await RetroAchievementsService.getLeaderboardEntries(
          104370,
          count: 100,
          offset: 100,
          apiKey: 'secret-key',
          client: client,
        );

        expect(requestedUri.path, '/API/API_GetLeaderboardEntries.php');
        expect(requestedUri.queryParameters['i'], '104370');
        expect(requestedUri.queryParameters['c'], '100');
        expect(requestedUri.queryParameters['o'], '100');
        expect(page.total, 101);
        expect(page.results.single.rank, 7);
        expect(page.results.single.dateSubmitted, isNotNull);
      },
    );

    test(
      'requests the signed-in user leaderboard entries with user identity',
      () async {
        late Uri requestedUri;
        final client = MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            '{"Count":1,"Total":1,"Results":[{"ID":104370,"RankAsc":false,"Title":"South Island Conqueror","Description":"Highest score","Format":"VALUE","UserEntry":{"User":"me","ULID":"my-ulid","Score":120,"FormattedScore":"120","Rank":9,"DateUpdated":"2024-12-12T16:40:59+00:00"}}]}',
            200,
          );
        });

        final page = await RetroAchievementsService.getUserGameLeaderboards(
          14402,
          'my-ulid',
          apiKey: 'secret-key',
          client: client,
        );

        expect(requestedUri.path, '/API/API_GetUserGameLeaderboards.php');
        expect(requestedUri.queryParameters['i'], '14402');
        expect(requestedUri.queryParameters['u'], 'my-ulid');
        expect(requestedUri.queryParameters['c'], '200');
        expect(requestedUri.queryParameters['o'], '0');
        expect(page.results.single.userEntry?.rank, 9);
        expect(page.results.single.userEntry?.formattedScore, '120');
      },
    );

    test(
      'user awards expose mastery and completion rows via AwardDataExtra mode',
      () {
        final awards = RetroAchievementsUserAwards.fromJson({
          'TotalAwardsCount': 2,
          'HiddenAwardsCount': 0,
          'MasteryAwardsCount': 1,
          'CompletionAwardsCount': 1,
          'BeatenHardcoreAwardsCount': 0,
          'BeatenSoftcoreAwardsCount': 0,
          'EventAwardsCount': 0,
          'SiteAwardsCount': 0,
          'VisibleUserAwards': [
            {
              'AwardedAt': '2024-01-02T00:00:00+00:00',
              'AwardType': 'Mastery/Completion',
              'AwardData': 100,
              'AwardDataExtra': 1,
              'DisplayOrder': 0,
              'Title': 'Hardcore Game',
              'ConsoleID': 1,
              'ConsoleName': 'Mega Drive / Genesis',
              'Flags': 0,
              'ImageIcon': '/Images/1.png',
            },
            {
              'AwardedAt': '2024-01-03T00:00:00+00:00',
              'AwardType': 'Mastery/Completion',
              'AwardData': 101,
              'AwardDataExtra': 0,
              'DisplayOrder': 0,
              'Title': 'Softcore Game',
              'ConsoleID': 1,
              'ConsoleName': 'Mega Drive / Genesis',
              'Flags': 0,
              'ImageIcon': '/Images/2.png',
            },
          ],
        });

        final masteries = awards.visibleUserAwards
            .where(
              (award) =>
                  award.awardType == 'Mastery/Completion' &&
                  award.awardDataExtra == 1,
            )
            .toList();
        final completions = awards.visibleUserAwards
            .where(
              (award) =>
                  award.awardType == 'Mastery/Completion' &&
                  award.awardDataExtra == 0,
            )
            .toList();

        expect(masteries.single.title, 'Hardcore Game');
        expect(completions.single.title, 'Softcore Game');
      },
    );

    group('offline cache policy', () {
      // One real API payload, reused so each test differs only in what the
      // network does the second time round.
      const recentlyPlayedBody =
          '[{"GameID":11332,"ConsoleID":12,"ConsoleName":"PlayStation",'
          '"Title":"Final Fantasy Origins","ImageIcon":"/Images/060249.png",'
          '"ImageTitle":"/Images/026707.png",'
          '"ImageIngame":"/Images/026708.png",'
          '"ImageBoxArt":"/Images/046257.png",'
          '"LastPlayed":"2023-10-27 00:30:04","AchievementsTotal":119,'
          '"NumPossibleAchievements":119,"PossibleScore":945,'
          '"NumAchieved":38,"ScoreAchieved":382,'
          '"NumAchievedHardcore":38,"ScoreAchievedHardcore":382}]';

      late Directory cacheDir;

      setUp(() {
        cacheDir = Directory.systemTemp.createTempSync('ra_cache_test');
        RetroAchievementsCache.setDirectoryForTesting(cacheDir.path);
      });

      tearDown(() {
        RetroAchievementsCache.setDirectoryForTesting(null);
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });

      Future<void> primeCache(String username) async {
        await RetroAchievementsService.getUserRecentlyPlayedGames(
          username,
          apiKey: 'secret-key',
          client: MockClient(
            (request) async => http.Response(recentlyPlayedBody, 200),
          ),
        );
      }

      test('replays the last good response when the network drops', () async {
        await primeCache('Cached');
        expect(
          RetroAchievementsCache.servedFromCache('recently_played_Cached_10_0'),
          isFalse,
        );

        final offline =
            await RetroAchievementsService.getUserRecentlyPlayedGames(
              'Cached',
              apiKey: 'secret-key',
              client: MockClient(
                (request) async =>
                    throw const SocketException('Network is unreachable'),
              ),
            );

        expect(offline.single.title, 'Final Fantasy Origins');
        expect(
          RetroAchievementsCache.servedFromCache('recently_played_Cached_10_0'),
          isTrue,
        );
      });

      test('falls back to the cached copy on a 5xx', () async {
        await primeCache('Flaky');

        final served =
            await RetroAchievementsService.getUserRecentlyPlayedGames(
              'Flaky',
              apiKey: 'secret-key',
              client: MockClient(
                (request) async => http.Response('Bad Gateway', 502),
              ),
            );

        expect(served.single.gameId, 11332);
        expect(
          RetroAchievementsCache.servedFromCache('recently_played_Flaky_10_0'),
          isTrue,
        );
      });

      test(
        'a rate-limited (429) reaches the caller even with a cached copy',
        () async {
          // The regression this guards: `onMiss` throws, so throwing it from
          // inside the fallback's own try block sent 429s into the cache path
          // and answered them with stale data that looked live. The provider
          // recognises rate limiting by the "(429)" in the message, so the
          // status code has to survive the cache layer.
          await primeCache('Limited');

          await expectLater(
            RetroAchievementsService.getUserRecentlyPlayedGames(
              'Limited',
              apiKey: 'secret-key',
              client: MockClient(
                (request) async => http.Response('Too Many Requests', 429),
              ),
            ),
            throwsA(
              isA<HttpException>().having(
                (e) => e.message,
                'message',
                contains('(429)'),
              ),
            ),
          );
          expect(
            RetroAchievementsCache.servedFromCache(
              'recently_played_Limited_10_0',
            ),
            isFalse,
          );
        },
      );

      test(
        'a transport failure with no cached copy reports itself as offline',
        () async {
          final client = MockClient(
            (request) async =>
                throw const SocketException('Network is unreachable'),
          );

          await expectLater(
            RetroAchievementsService.getUserRecentlyPlayedGames(
              'Scott',
              apiKey: 'secret-key',
              client: client,
            ),
            throwsA(
              isA<HttpException>().having(
                (e) => e.message,
                'message',
                contains('(offline)'),
              ),
            ),
          );
        },
      );

      test('caches see-all pages under per-page keys', () async {
        // One row per page, differing by game id, so a replay from the wrong
        // key is obvious.
        const pageOne =
            '[{"Date":"2023-12-27 16:04:50","HardcoreMode":1,'
            '"AchievementID":98012,"Title":"Beginner I","Description":"Clear",'
            '"BadgeName":"108302","Points":5,"TrueRatio":25,"Type":null,'
            '"Author":"jos","AuthorULID":"ULID","GameTitle":"Pinball mini",'
            '"GameIcon":"/Images/028399.png","GameID":14715,'
            '"ConsoleName":"Pokemon Mini","BadgeURL":"/Badge/108302.png",'
            '"GameURL":"/game/14715"}]';
        const pageTwo =
            '[{"Date":"2023-12-28 16:04:50","HardcoreMode":1,'
            '"AchievementID":98013,"Title":"Beginner II","Description":"Clear",'
            '"BadgeName":"108303","Points":5,"TrueRatio":25,"Type":null,'
            '"Author":"jos","AuthorULID":"ULID","GameTitle":"Pinball mini",'
            '"GameIcon":"/Images/028399.png","GameID":99999,'
            '"ConsoleName":"Pokemon Mini","BadgeURL":"/Badge/108303.png",'
            '"GameURL":"/game/99999"}]';

        // Prime both pages live.
        for (final (body, offset) in [(pageOne, 0), (pageTwo, 50)]) {
          final page = await RetroAchievementsService.getUserRecentAchievements(
            'Paged',
            count: 50,
            offset: offset,
            apiKey: 'secret-key',
            client: MockClient((request) async => http.Response(body, 200)),
          );
          expect(page.single.gameId, offset == 0 ? 14715 : 99999);
        }

        // Offline, each page replays its own rows: two pages of one list
        // must never collide on one key.
        final offline = MockClient(
          (request) async =>
              throw const SocketException('Network is unreachable'),
        );
        final replayOne =
            await RetroAchievementsService.getUserRecentAchievements(
              'Paged',
              count: 50,
              offset: 0,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayOne.single.gameId, 14715);
        expect(
          RetroAchievementsCache.servedFromCache('recent_unlocks_Paged_50_0'),
          isTrue,
        );

        final replayTwo =
            await RetroAchievementsService.getUserRecentAchievements(
              'Paged',
              count: 50,
              offset: 50,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayTwo.single.gameId, 99999);
        expect(
          RetroAchievementsCache.servedFromCache('recent_unlocks_Paged_50_50'),
          isTrue,
        );
      });

      test('caches games-list pages under per-page keys', () async {
        // One row per page per source, differing by game id, so a replay
        // from the wrong key is obvious. Both endpoints the Games sub-tab
        // walks are paginated, so both need page-named keys.
        const playedOne =
            '[{"GameID":4001,"ConsoleID":12,"ConsoleName":"PlayStation",'
            '"Title":"Game One","ImageIcon":"/Images/060249.png",'
            '"ImageTitle":"/Images/026707.png",'
            '"ImageIngame":"/Images/026708.png",'
            '"ImageBoxArt":"/Images/046257.png",'
            '"LastPlayed":"2024-01-01 00:30:04","AchievementsTotal":119,'
            '"NumPossibleAchievements":119,"PossibleScore":945,'
            '"NumAchieved":38,"ScoreAchieved":382,'
            '"NumAchievedHardcore":38,"ScoreAchievedHardcore":382}]';
        const playedTwo =
            '[{"GameID":4002,"ConsoleID":12,"ConsoleName":"PlayStation",'
            '"Title":"Game Two","ImageIcon":"/Images/060249.png",'
            '"ImageTitle":"/Images/026707.png",'
            '"ImageIngame":"/Images/026708.png",'
            '"ImageBoxArt":"/Images/046257.png",'
            '"LastPlayed":"2024-01-02 00:30:04","AchievementsTotal":119,'
            '"NumPossibleAchievements":119,"PossibleScore":945,'
            '"NumAchieved":38,"ScoreAchieved":382,'
            '"NumAchievedHardcore":38,"ScoreAchievedHardcore":382}]';
        const progressOne =
            '{"Count":1,"Total":2,"Results":[{"GameID":5001,'
            '"Title":"Tracked One","ImageIcon":"/Images/074560.png",'
            '"ConsoleID":1,"ConsoleName":"Mega Drive / Genesis",'
            '"MaxPossible":56,"NumAwarded":56,"NumAwardedHardcore":56,'
            '"MostRecentAwardedDate":"2024-01-01T02:52:34+00:00",'
            '"HighestAwardKind":"mastered",'
            '"HighestAwardDate":"2024-01-01T02:52:34+00:00"}]}';
        const progressTwo =
            '{"Count":1,"Total":2,"Results":[{"GameID":5002,'
            '"Title":"Tracked Two","ImageIcon":"/Images/074560.png",'
            '"ConsoleID":1,"ConsoleName":"Mega Drive / Genesis",'
            '"MaxPossible":40,"NumAwarded":40,"NumAwardedHardcore":0,'
            '"MostRecentAwardedDate":"2024-01-02T02:52:34+00:00",'
            '"HighestAwardKind":"completed",'
            '"HighestAwardDate":"2024-01-02T02:52:34+00:00"}]}';

        // Prime both pages of both endpoints live.
        for (final (body, offset) in [(playedOne, 0), (playedTwo, 50)]) {
          final page =
              await RetroAchievementsService.getUserRecentlyPlayedGames(
                'PagedGames',
                count: 50,
                offset: offset,
                apiKey: 'secret-key',
                client: MockClient((request) async => http.Response(body, 200)),
              );
          expect(page.single.gameId, offset == 0 ? 4001 : 4002);
        }
        for (final (body, offset) in [(progressOne, 0), (progressTwo, 100)]) {
          final summary =
              await RetroAchievementsService.getUserCompletionProgress(
                'PagedGames',
                count: 100,
                offset: offset,
                apiKey: 'secret-key',
                client: MockClient((request) async => http.Response(body, 200)),
              );
          expect(summary.results.single.gameId, offset == 0 ? 5001 : 5002);
        }

        // Offline, each page of each endpoint replays its own rows: pages of
        // one list must never collide on one key, whichever endpoint they
        // came from.
        final offline = MockClient(
          (request) async =>
              throw const SocketException('Network is unreachable'),
        );
        final replayPlayedOne =
            await RetroAchievementsService.getUserRecentlyPlayedGames(
              'PagedGames',
              count: 50,
              offset: 0,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayPlayedOne.single.gameId, 4001);
        expect(
          RetroAchievementsCache.servedFromCache(
            'recently_played_PagedGames_50_0',
          ),
          isTrue,
        );

        final replayPlayedTwo =
            await RetroAchievementsService.getUserRecentlyPlayedGames(
              'PagedGames',
              count: 50,
              offset: 50,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayPlayedTwo.single.gameId, 4002);
        expect(
          RetroAchievementsCache.servedFromCache(
            'recently_played_PagedGames_50_50',
          ),
          isTrue,
        );

        final replayProgressOne =
            await RetroAchievementsService.getUserCompletionProgress(
              'PagedGames',
              count: 100,
              offset: 0,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayProgressOne.results.single.gameId, 5001);
        expect(
          RetroAchievementsCache.servedFromCache('completion_PagedGames_100_0'),
          isTrue,
        );

        final replayProgressTwo =
            await RetroAchievementsService.getUserCompletionProgress(
              'PagedGames',
              count: 100,
              offset: 100,
              apiKey: 'secret-key',
              client: offline,
            );
        expect(replayProgressTwo.results.single.gameId, 5002);
        expect(
          RetroAchievementsCache.servedFromCache(
            'completion_PagedGames_100_100',
          ),
          isTrue,
        );
      });
    });
  });
}
