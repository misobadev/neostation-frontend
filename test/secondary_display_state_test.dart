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
      videoPreviewDelay: 4,
      videoPreviewDeadlineMillis: 1700000002500,
      videoPreviewFileChecked: true,
      videoPreviewFileExists: true,
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
          type: 'missable',
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
      // Non-default so a field dropped from toJson/fromJson fails the round-trip.
      hideSystemLogo: true,
      dockSlotCount: 4,
      // Both non-default so a field dropped from toJson/fromJson actually fails
      // the round-trip — at their `false` defaults a missing key restores to the
      // same value and the comparison passes regardless.
      appReady: true,
      setupWizardActive: true,
      // Both non-default: the secondary engine has its own SfxService, so these
      // are the only way the UI-sound setting crosses the engine boundary.
      sfxEnabled: false,
      sfxVolume: 0.25,
      // Non-null and non-default: the secondary engine's corner clock reads
      // this, and null would round-trip as "not pushed yet" either way.
      use12HourClock: true,
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
      expect(restored.achievements![0].type, 'missable');
      expect(restored.achievements![0].isMissable, isTrue);
      expect(restored.achievements![1].earned, isFalse);
    });

    test('applies documented defaults for a minimal payload', () {
      // Only the one required field is present; everything else defaults.
      final restored = SecondaryDisplayStateData.fromJson(const {
        'systemName': 'nes',
      });

      expect(restored.systemName, 'nes');
      expect(restored.gameImageBytes, isNull);
      expect(restored.achievements, isNull);
      expect(restored.newlyEarnedIds, isNull);
      // Non-obvious defaults worth pinning:
      expect(restored.isScraperLoggedIn, isTrue);
      expect(restored.deviceScreenOn, isTrue);
      expect(restored.nowPlayingDimDelay, 5);
      expect(restored.nowPlayingDimLevel, 100);
      // Mirrors the config default (fanart_dim_level DEFAULT 25) so the 25% dim
      // applies from the first-launch WELCOME seed, not just after a relaunch.
      expect(restored.fanartDimLevel, 25);
      expect(restored.dockEnabled, isTrue);
      // A payload predating the setting must keep showing the logo.
      expect(restored.hideSystemLogo, isFalse);
      expect(restored.dockSlotCount, 3);
      expect(restored.dockApps, const ['', '', '', '', '']);
      // Both latches start off: the main engine hasn't painted, and the dock is
      // only withheld once the wizard says so. A payload predating either field
      // must not read as "wizard running" — that would park the dock forever.
      expect(restored.appReady, isFalse);
      expect(restored.setupWizardActive, isFalse);
      // Mirror the config defaults (sfx_enabled DEFAULT 1, sfx_volume DEFAULT
      // 0.75) so a snapshot predating these fields sounds like the persisted
      // setting rather than silently muting the bottom screen.
      expect(restored.sfxEnabled, isTrue);
      expect(restored.sfxVolume, 0.75);
      // Null, not false: the secondary engine seeds the clock format from the
      // config row itself, and a `false` here would look like a real push and
      // overwrite that seed with 24-hour on every snapshot.
      expect(restored.use12HourClock, isNull);
    });

    test('coerces numeric fields delivered as doubles', () {
      final restored = SecondaryDisplayStateData.fromJson(const {
        'systemName': 'gba',
        'playTimeSeconds': 120.0,
        'lastPlayedMillis': 1700000000000.0,
        'nowPlayingDimLevel': 75.0,
        'dockSlotCount': 5.0,
        'sfxVolume': 0,
      });

      expect(restored.playTimeSeconds, 120);
      expect(restored.lastPlayedMillis, 1700000000000);
      expect(restored.nowPlayingDimLevel, 75);
      expect(restored.dockSlotCount, 5);
      // An int-valued volume must not blow up the double cast.
      expect(restored.sfxVolume, 0.0);
    });
  });

  // The "no Now Playing on launch" bug was a partial state update silently
  // dropping nowPlayingActive. Every secondary-display write goes through
  // copyWith, so these pin the merge contract the fix depends on: a field not
  // named in a copyWith call must survive unchanged.
  group('SecondaryDisplayStateData.copyWith merge contract', () {
    final active = SecondaryDisplayStateData(
      systemName: 'ps1',
      gameTitle: 'Silent Hill',
      nowPlayingActive: true,
      isGameLaunching: true,
    );

    test('a partial update that omits nowPlayingActive preserves it', () {
      // This is exactly the clobber that broke Now Playing: a browse-style
      // update (media/system fields) that never mentions nowPlayingActive must
      // NOT turn it off.
      final next = active.copyWith(
        systemName: 'ps1',
        gameFanart: '/data/fanart.png',
        gameScreenshot: '/data/shot.png',
      );

      expect(next.nowPlayingActive, isTrue);
      expect(next.gameTitle, 'Silent Hill');
      expect(next.gameFanart, '/data/fanart.png');
    });

    test('an explicit nowPlayingActive: false clears it (game exit)', () {
      // The legitimate way Now Playing turns off — on game return.
      final next = active.copyWith(nowPlayingActive: false);

      expect(next.nowPlayingActive, isFalse);
      // Other fields still untouched.
      expect(next.gameTitle, 'Silent Hill');
      expect(next.isGameLaunching, isTrue);
    });

    test('the atomic launch write sets isGameLaunching + nowPlayingActive '
        'together without dropping either', () {
      // Models pushForLaunch's single authoritative write: both flags on in one
      // copyWith, and neither is lost.
      final idle = SecondaryDisplayStateData(systemName: 'ps1');
      final launched = idle.copyWith(
        isGameLaunching: true,
        nowPlayingActive: true,
        gameTitle: 'Silent Hill',
      );

      expect(launched.isGameLaunching, isTrue);
      expect(launched.nowPlayingActive, isTrue);
      expect(launched.gameTitle, 'Silent Hill');
    });

    test('a partial update that omits setupWizardActive preserves it', () {
      // The wizard parks the secondary display's dock and launcher by holding
      // this flag true. Both engines write the shared state, so any push that
      // doesn't mention the flag — a mute toggle, an isSecondaryActive update —
      // must not clear it, or the dock slides up mid-setup.
      final inWizard = SecondaryDisplayStateData(
        systemName: 'WELCOME',
        setupWizardActive: true,
        appReady: true,
      );

      final next = inWizard.copyWith(isSecondaryActive: true, isOled: true);

      expect(next.setupWizardActive, isTrue);
      expect(next.appReady, isTrue);
    });

    test('an explicit setupWizardActive: false clears it (setup complete)', () {
      // How the dock is released: the wrapper pushes the clear once setup
      // completes, and the reveal tween brings the dock in.
      final inWizard = SecondaryDisplayStateData(
        systemName: 'WELCOME',
        setupWizardActive: true,
      );

      expect(
        inWizard.copyWith(setupWizardActive: false).setupWizardActive,
        isFalse,
      );
    });

    test('a partial update that omits the SFX settings preserves them', () {
      // UI sounds off is pushed once, from General settings. Every later push
      // from either engine — a mute toggle, a screen-power edge, an art change
      // — must carry it through, or the bottom screen starts clicking again.
      final muted = SecondaryDisplayStateData(
        systemName: 'snes',
        sfxEnabled: false,
        sfxVolume: 0.25,
      );

      final next = muted.copyWith(isVideoMuted: true, deviceScreenOn: false);

      expect(next.sfxEnabled, isFalse);
      expect(next.sfxVolume, 0.25);
    });

    test('an explicit sfxEnabled: false clears it (sounds turned off)', () {
      // How the setting reaches the secondary engine: the mutator pushes the
      // toggle, and the secondary applies it to its own SfxService.
      final loud = SecondaryDisplayStateData(systemName: 'snes');

      expect(loud.sfxEnabled, isTrue);
      expect(loud.copyWith(sfxEnabled: false).sfxEnabled, isFalse);
    });

    test('a partial update that omits the clock format preserves it', () {
      // Pushed once, from General settings; every later push from either
      // engine has to carry it or the corner clock flips format mid-game.
      final twelveHour = SecondaryDisplayStateData(
        systemName: 'snes',
        use12HourClock: true,
      );

      final next = twelveHour.copyWith(nowPlayingActive: true);

      expect(next.use12HourClock, isTrue);
    });

    test('an unpushed clock format stays null through a partial update', () {
      // Null is the secondary engine's cue to keep its own seeded value, so a
      // merge must not settle it to a default.
      final unpushed = SecondaryDisplayStateData(systemName: 'snes');

      expect(unpushed.use12HourClock, isNull);
      expect(unpushed.copyWith(nowPlayingActive: true).use12HourClock, isNull);
    });
  });
}
