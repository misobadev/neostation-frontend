import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/secondary_achievement_item.dart';
import 'package:neostation/models/secondary_display_state.dart';

void main() {
  group('SecondaryDisplayStateData JSON bridge', () {
    // A fully-populated instance so the round-trip exercises every field,
    // including the nested achievements list, base64 image bytes, and the
    // int-list newlyEarnedIds — the contract the secondary engine relies on.
    final populated = SecondaryDisplayStateData(
      systemName: 'snes',
      gameFanart: '/data/fanart.png',
      gameScreenshot: '/data/screenshot.png',
      gameWheel: '/data/wheel.png',
      gameVideo: '/data/video.mp4',
      gameImageBytes: Uint8List.fromList([0, 1, 2, 253, 254, 255]),
      isGameSelected: true,
      isVideoMuted: true,
      hideBottomScreen: true,
      muteToggleTrigger: 4,
      screenshotTrigger: 9,
      screenshotAccessEnabled: true,
      backgroundColor: 0xFF102030,
      themeName: 'midnight',
      isSecondaryActive: true,
      isGameLaunching: true,
      gameId: 'game-123',
      isScraping: true,
      scrapeProgress: 0.42,
      scrapeStatus: 'Downloading images...',
      isScraperLoggedIn: false,
      scrapeTrigger: 2,
      systemLogo: '/data/logo.png',
      isLogoAsset: true,
      systemBackground: '/data/bg.png',
      isBackgroundAsset: true,
      useShader: true,
      shaderColor1: 0xFFAABBCC,
      shaderColor2: 0xFF001122,
      useFluidShader: true,
      isOled: true,
      mediaRevision: 7,
      showAchievementPanel: true,
      achievements: const [
        SecondaryAchievementItem(
          id: 1,
          title: 'A',
          description: 'first',
          points: 5,
          badgeName: '111',
          displayOrder: 0,
          earned: true,
          earnedHardcore: false,
        ),
        SecondaryAchievementItem(
          id: 2,
          title: 'B',
          description: 'second',
          points: 10,
          badgeName: '222',
          displayOrder: 1,
          earned: false,
          earnedHardcore: false,
        ),
      ],
      raEarned: 1,
      raTotal: 2,
      raPoints: 5,
      raPointsTotal: 15,
      raCompletionPct: '50.00%',
      raGameTitle: 'Super Game',
      newlyEarnedIds: const [1, 2, 3],
      nowPlayingActive: true,
      deviceScreenOn: false,
      gameTitle: 'Super Game (USA)',
      gameBoxart: '/data/boxart.png',
      playTimeSeconds: 3600,
      lastPlayedMillis: 1700000000000,
      nowPlayingDimDelay: 30,
      nowPlayingDimLevel: 80,
      fanartDimLevel: 40,
      dockApps: const ['com.a', 'com.b', '', '', ''],
      dockEditTrigger: 3,
      dockEnabled: false,
      dockSlotCount: 4,
    );

    test('round-trips every field through toJson/fromJson', () {
      final restored = SecondaryDisplayStateData.fromJson(populated.toJson());

      // Comparing the re-serialized maps proves the full serialize →
      // deserialize → serialize cycle is stable across all fields.
      expect(restored.toJson(), populated.toJson());
    });

    test('preserves image bytes across the base64 bridge', () {
      final restored = SecondaryDisplayStateData.fromJson(populated.toJson());

      expect(restored.gameImageBytes, isNotNull);
      expect(restored.gameImageBytes, equals(populated.gameImageBytes));
    });

    test('preserves the nested achievements list', () {
      final restored = SecondaryDisplayStateData.fromJson(populated.toJson());

      expect(restored.achievements, hasLength(2));
      expect(restored.achievements![0].id, 1);
      expect(restored.achievements![0].earned, isTrue);
      expect(restored.achievements![1].earned, isFalse);
    });

    test('applies documented defaults for a minimal payload', () {
      // Only the one required field is present; everything else defaults.
      final restored =
          SecondaryDisplayStateData.fromJson(const {'systemName': 'nes'});

      expect(restored.systemName, 'nes');
      expect(restored.gameImageBytes, isNull);
      expect(restored.achievements, isNull);
      expect(restored.newlyEarnedIds, isNull);
      // Non-obvious defaults worth pinning:
      expect(restored.isScraperLoggedIn, isTrue);
      expect(restored.deviceScreenOn, isTrue);
      expect(restored.nowPlayingDimDelay, 5);
      expect(restored.nowPlayingDimLevel, 100);
      expect(restored.fanartDimLevel, 0);
      expect(restored.dockEnabled, isTrue);
      expect(restored.dockSlotCount, 3);
      expect(restored.dockApps, const ['', '', '', '', '']);
    });

    test('coerces numeric fields delivered as doubles', () {
      final restored = SecondaryDisplayStateData.fromJson(const {
        'systemName': 'gba',
        'playTimeSeconds': 120.0,
        'lastPlayedMillis': 1700000000000.0,
        'nowPlayingDimLevel': 75.0,
        'dockSlotCount': 5.0,
      });

      expect(restored.playTimeSeconds, 120);
      expect(restored.lastPlayedMillis, 1700000000000);
      expect(restored.nowPlayingDimLevel, 75);
      expect(restored.dockSlotCount, 5);
    });
  });
}
