import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';
import 'package:neostation/services/multi_disc_organizer_runner.dart';
import 'package:neostation/services/orphan_cleanup_runner.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';

/// The multi-disc organiser and the orphan cleanup ran inside the Tools
/// widget. Leaving Tools mid-run disposed it, and the run then skipped its
/// rescan, lost its outcome and deleted its own notification; coming back
/// allowed a second run, whose progress and outcome the first run's late
/// dismiss then wiped. They now run through runners that outlive the screen,
/// and the two never overlap: a cleanup during an unrescanned organise reads
/// the moved sets' metadata as orphaned and deletes it.
void main() {
  const organizerStrings = MultiDiscOrganizerStrings(
    scanning: 'Scanning…',
    done:
        'Organized {groups} sets, {files} files, {playlists} '
        'playlists{skipped}.',
    noSetsFound: 'No sets found{skipped}.',
    partialFailure: '{failed} sets failed. {result}',
    skippedSuffix: ' ({count} skipped)',
    failedTemplate: 'Organising failed: {error}',
  );

  const cleanupStrings = OrphanCleanupStrings(
    scanning: 'Scanning…',
    cleaningItemTemplate: 'Cleaning {filename}',
    failedTemplate: 'Cleanup failed: {error}',
    done: 'Cleaned {entries} entries and {files} files.',
    nothingFound: 'Nothing found.',
    nothingToDelete: 'Nothing to delete.',
    esdeKeptOne: ' {count} kept (one).',
    esdeKeptMany: ' {count} kept.',
    notRemovedOne: ' {count} not removed (one).',
    notRemovedMany: ' {count} not removed.',
  );

  const psx = SystemModel(
    folderName: 'psx',
    realName: 'PlayStation',
    iconImage: '',
    color: '',
    multiDisc: true,
    extensions: ['chd', 'cue'],
    folders: ['playstation'],
  );
  const nes = SystemModel(
    folderName: 'nes',
    realName: 'NES',
    iconImage: '',
    color: '',
    extensions: ['nes'],
  );

  RomFolderOrganizerResult org({
    int groupsOrganized = 0,
    int filesMoved = 0,
    int playlistsCreated = 0,
    int groupsFailed = 0,
  }) => RomFolderOrganizerResult(
    groupsOrganized: groupsOrganized,
    foldersCreated: groupsOrganized,
    filesMoved: filesMoved,
    playlistsCreated: playlistsCreated,
    rootsSkipped: 0,
    groupsFailed: groupsFailed,
  );

  const item = OrphanedMetadataItem(
    appSystemId: 'psx',
    filename: 'a.chd',
    systemFolderName: 'psx',
    isFullyScraped: true,
    esdeImported: false,
  );

  final notifications = GlobalNotificationService();

  GlobalNotificationData? row(String id) {
    for (final n in notifications.notifier.value) {
      if (n.id == id) return n;
    }
    return null;
  }

  // Held organise and clean calls, completed by the test.
  late Completer<RomFolderOrganizerResult> organizing;
  late Completer<MetadataCleanupResult> cleaning;
  late List<String> rescanned;
  late List<String> organizeRoots;
  late Set<String> organizeExtensions;
  late Set<String>? organizeFolders;
  String? cleanMediaPath;
  var organizeCalls = 0;
  var cleanCalls = 0;
  void Function(int completed, int total)? organizeProgress;
  void Function(double progress, OrphanedMetadataItem item)? cleanProgress;

  setUp(() {
    LibraryFileToolLock.debugReset();
    notifications.notifier.value = [];
    organizing = Completer();
    cleaning = Completer();
    rescanned = [];
    organizeCalls = 0;
    cleanCalls = 0;
    MultiDiscOrganizerRunner.loadSystems = () async => [psx, nes];
    MultiDiscOrganizerRunner.organize =
        (
          roots, {
          required supportedRomExtensions,
          supportedSystemFolders,
          onProgress,
        }) {
          organizeCalls++;
          organizeRoots = roots;
          organizeExtensions = supportedRomExtensions;
          organizeFolders = supportedSystemFolders;
          organizeProgress = onProgress;
          return organizing.future;
        };
    OrphanCleanupRunner.clean = ({mediaDirectoryPath, onProgress}) {
      cleanCalls++;
      cleanMediaPath = mediaDirectoryPath;
      cleanProgress = onProgress;
      return cleaning.future;
    };
  });

  tearDown(() {
    // Release anything a failed test left held, so it can't refuse the next.
    if (!organizing.isCompleted) organizing.complete(org());
    if (!cleaning.isCompleted) {
      cleaning.complete(const MetadataCleanupResult());
    }
    MultiDiscOrganizerRunner.debugReset();
    OrphanCleanupRunner.debugReset();
    LibraryFileToolLock.debugReset();
    notifications.notifier.value = [];
  });

  Future<RomFolderOrganizerResult?> organize({
    void Function()? onProgressStateChanged,
  }) => MultiDiscOrganizerRunner.run(
    romFolders: const ['/roms'],
    strings: organizerStrings,
    rescanSystem: (system) async => rescanned.add(system.folderName),
    onProgressStateChanged: onProgressStateChanged,
  );

  Future<MetadataCleanupResult?> clean({
    void Function()? onProgressStateChanged,
  }) => OrphanCleanupRunner.run(
    mediaDirectoryPath: '/media',
    strings: cleanupStrings,
    onProgressStateChanged: onProgressStateChanged,
  );

  group('the multi-disc organiser runner', () {
    test('is running from the synchronous start of run()', () async {
      expect(MultiDiscOrganizerRunner.isRunning, isFalse);
      final run = organize();
      // No await between the call and the check: a press that lands in the
      // gap must already see the run.
      expect(MultiDiscOrganizerRunner.isRunning, isTrue);
      expect(LibraryFileToolLock.isHeld, isTrue);

      organizing.complete(org());
      await run;
      expect(MultiDiscOrganizerRunner.isRunning, isFalse);
      expect(LibraryFileToolLock.isHeld, isFalse);
    });

    test(
      'loads the systems itself and organises only multi-disc ones',
      () async {
        final run = organize();
        await pumpEventQueue();

        expect(organizeRoots, ['/roms']);
        expect(organizeExtensions, {'chd', 'cue'});
        expect(organizeFolders, {'psx', 'playstation'});

        organizing.complete(org());
        await run;
      },
    );

    test('shows ongoing progress while it works', () async {
      final run = organize();
      await pumpEventQueue();

      var progress = row(MultiDiscOrganizerRunner.notificationId)!;
      expect(progress.message, organizerStrings.scanning);
      expect(progress.progress, 0);
      expect(progress.ongoing, isTrue);

      organizeProgress!(1, 4);
      progress = row(MultiDiscOrganizerRunner.notificationId)!;
      expect(progress.progress, 0.25);
      expect(progress.ongoing, isTrue);

      organizing.complete(org());
      await run;
    });

    test('a second run while one is held is refused and leaves the row '
        'alone', () async {
      final first = organize();
      await pumpEventQueue();
      final before = notifications.notifier.value;

      final second = await organize();

      expect(second, isNull);
      expect(identical(notifications.notifier.value, before), isTrue);
      expect(MultiDiscOrganizerRunner.isRunning, isTrue);

      organizing.complete(org());
      await first;
    });

    test(
      'writes its outcome after the caller is gone, as a finished row',
      () async {
        // No widget is involved: whoever started the run has nothing left to
        // do with it.
        final run = organize();
        await pumpEventQueue();
        organizing.complete(
          org(groupsOrganized: 1, filesMoved: 2, playlistsCreated: 1),
        );
        await run;

        final done = row(MultiDiscOrganizerRunner.notificationId)!;
        expect(done.message, 'Organized 1 sets, 2 files, 1 playlists.');
        expect(done.type, GlobalNotificationType.success);
        expect(done.progress, isNull);
        expect(done.ongoing, isFalse);
      },
    );

    test('writes its outcome even if the row was dismissed mid-run', () async {
      final run = organize();
      await pumpEventQueue();
      notifications.dismiss(MultiDiscOrganizerRunner.notificationId);

      organizing.complete(org());
      await run;

      final done = row(MultiDiscOrganizerRunner.notificationId);
      expect(done, isNotNull, reason: 'update() is a no-op on a missing id');
      expect(done!.message, 'No sets found.');
      expect(done.type, GlobalNotificationType.info);
    });

    test('rescans the multi-disc systems when files moved', () async {
      final run = organize();
      await pumpEventQueue();
      organizing.complete(org(groupsOrganized: 1, filesMoved: 2));
      await run;

      expect(rescanned, ['psx']);
    });

    test('does not rescan when nothing changed', () async {
      final run = organize();
      await pumpEventQueue();
      organizing.complete(org());
      await run;

      expect(rescanned, isEmpty);
    });

    test('rescans after a failure mid-run and reports the failure', () async {
      // A throw can come after some sets were already moved.
      final run = organize();
      await pumpEventQueue();
      organizing.completeError(StateError('disk gone'));
      final result = await run;

      expect(result, isNull);
      expect(rescanned, ['psx']);
      final failed = row(MultiDiscOrganizerRunner.notificationId)!;
      expect(failed.message, 'Organising failed: Bad state: disk gone');
      expect(failed.type, GlobalNotificationType.error);
      expect(failed.progress, isNull);
      expect(failed.ongoing, isFalse);
      expect(MultiDiscOrganizerRunner.isRunning, isFalse);
    });

    test('a rescan that fails after a failed organise keeps the original '
        'error', () async {
      final run = MultiDiscOrganizerRunner.run(
        romFolders: const ['/roms'],
        strings: organizerStrings,
        rescanSystem: (_) async => throw StateError('rescan broke'),
      );
      await pumpEventQueue();
      organizing.completeError(StateError('disk gone'));
      await run;

      expect(
        row(MultiDiscOrganizerRunner.notificationId)!.message,
        'Organising failed: Bad state: disk gone',
      );
    });

    test('reports a failure to load the systems without rescanning', () async {
      MultiDiscOrganizerRunner.loadSystems = () async =>
          throw StateError('no db');

      final result = await organize();

      expect(result, isNull);
      expect(rescanned, isEmpty);
      expect(
        row(MultiDiscOrganizerRunner.notificationId)!.message,
        'Organising failed: Bad state: no db',
      );
      expect(MultiDiscOrganizerRunner.isRunning, isFalse);
    });

    test('reports its start and finish to the caller', () async {
      var changes = 0;
      final run = organize(onProgressStateChanged: () => changes++);
      expect(changes, 1);
      organizing.complete(org());
      await run;
      expect(changes, 2);
    });

    test('its outcome is the outcome function\'s, word for word', () async {
      final result = org(groupsOrganized: 1, filesMoved: 2, groupsFailed: 1);
      final run = organize();
      await pumpEventQueue();
      organizing.complete(result);
      await run;

      final (message, type) = multiDiscOutcome(result, organizerStrings);
      final done = row(MultiDiscOrganizerRunner.notificationId)!;
      expect(done.message, message);
      expect(done.type, type);
      expect(done.type, GlobalNotificationType.error);
    });
  });

  group('the orphan cleanup runner', () {
    test('is running from the synchronous start of run()', () async {
      expect(OrphanCleanupRunner.isRunning, isFalse);
      final run = clean();
      expect(OrphanCleanupRunner.isRunning, isTrue);
      expect(LibraryFileToolLock.isHeld, isTrue);

      cleaning.complete(const MetadataCleanupResult());
      await run;
      expect(OrphanCleanupRunner.isRunning, isFalse);
      expect(LibraryFileToolLock.isHeld, isFalse);
    });

    test(
      'cleans with the media folder it was given, showing progress',
      () async {
        final run = clean();
        await pumpEventQueue();

        expect(cleanMediaPath, '/media');
        var progress = row(OrphanCleanupRunner.notificationId)!;
        expect(progress.message, cleanupStrings.scanning);
        expect(progress.progress, 0);
        expect(progress.ongoing, isTrue);

        cleanProgress!(0.5, item);
        progress = row(OrphanCleanupRunner.notificationId)!;
        expect(progress.message, 'Cleaning a.chd');
        expect(progress.progress, 0.5);
        expect(progress.ongoing, isTrue);

        cleaning.complete(const MetadataCleanupResult());
        await run;
      },
    );

    test('a second run while one is held is refused and leaves the row '
        'alone', () async {
      final first = clean();
      await pumpEventQueue();
      final before = notifications.notifier.value;

      expect(await clean(), isNull);
      expect(identical(notifications.notifier.value, before), isTrue);

      cleaning.complete(const MetadataCleanupResult());
      await first;
    });

    test(
      'writes its outcome after the caller is gone, as a finished row',
      () async {
        final run = clean();
        await pumpEventQueue();
        cleaning.complete(
          const MetadataCleanupResult(
            orphanedItems: [item, item],
            deletedItems: [item, item],
            deletedMediaFiles: 3,
          ),
        );
        await run;

        final done = row(OrphanCleanupRunner.notificationId)!;
        expect(done.message, 'Cleaned 2 entries and 3 files.');
        expect(done.type, GlobalNotificationType.success);
        expect(done.progress, isNull);
        expect(done.ongoing, isFalse);
      },
    );

    test('writes its outcome even if the row was dismissed mid-run', () async {
      final run = clean();
      await pumpEventQueue();
      notifications.dismiss(OrphanCleanupRunner.notificationId);

      cleaning.complete(const MetadataCleanupResult());
      await run;

      final done = row(OrphanCleanupRunner.notificationId);
      expect(done, isNotNull);
      expect(done!.message, 'Nothing found.');
      expect(done.type, GlobalNotificationType.info);
    });

    test('reports a failure, localised, and lets the next run start', () async {
      final run = clean();
      await pumpEventQueue();
      cleaning.completeError(StateError('locked'));

      expect(await run, isNull);
      final failed = row(OrphanCleanupRunner.notificationId)!;
      expect(failed.message, 'Cleanup failed: Bad state: locked');
      expect(failed.type, GlobalNotificationType.error);
      expect(failed.progress, isNull);
      expect(failed.ongoing, isFalse);
      expect(OrphanCleanupRunner.isRunning, isFalse);
    });

    test('reports its start and finish to the caller', () async {
      var changes = 0;
      final run = clean(onProgressStateChanged: () => changes++);
      expect(changes, 1);
      cleaning.complete(const MetadataCleanupResult());
      await run;
      expect(changes, 2);
    });

    test('its outcome is the outcome function\'s, word for word', () async {
      const result = MetadataCleanupResult(
        orphanedItems: [item, item],
        errors: ['Failed to clean metadata for psx/a.chd: locked', 'x'],
      );
      final run = clean();
      await pumpEventQueue();
      cleaning.complete(result);
      await run;

      final (message, type) = orphanCleanupOutcome(result, cleanupStrings);
      final done = row(OrphanCleanupRunner.notificationId)!;
      expect(done.message, message);
      expect(done.message, '2 not removed.');
      expect(done.type, type);
      expect(done.type, GlobalNotificationType.error);
    });
  });

  group('the two never overlap', () {
    test('the organiser running refuses the cleanup', () async {
      final organising = organize();
      await pumpEventQueue();

      // The guard Tools checks before it even analyses.
      expect(LibraryFileToolLock.isHeld, isTrue);
      expect(await clean(), isNull);
      expect(OrphanCleanupRunner.isRunning, isFalse);
      expect(cleanCalls, 0);
      expect(row(OrphanCleanupRunner.notificationId), isNull);

      organizing.complete(org());
      await organising;
      expect(LibraryFileToolLock.isHeld, isFalse);
    });

    test('the organiser holds the lock through its rescan', () async {
      // The rescan is what tells the library where the discs went; until it
      // finishes, the moved sets' metadata still looks orphaned.
      final rescanning = Completer<void>();
      final organising = MultiDiscOrganizerRunner.run(
        romFolders: const ['/roms'],
        strings: organizerStrings,
        rescanSystem: (system) {
          rescanned.add(system.folderName);
          return rescanning.future;
        },
      );
      await pumpEventQueue();
      organizing.complete(org(groupsOrganized: 1, filesMoved: 2));
      await pumpEventQueue();

      // The organise is done and the rescan is waiting.
      expect(rescanned, ['psx']);
      expect(MultiDiscOrganizerRunner.isRunning, isTrue);
      expect(await clean(), isNull);
      expect(cleanCalls, 0);
      expect(row(OrphanCleanupRunner.notificationId), isNull);

      rescanning.complete();
      await organising;
      expect(LibraryFileToolLock.isHeld, isFalse);

      final cleanup = clean();
      await pumpEventQueue();
      expect(cleanCalls, 1);
      cleaning.complete(const MetadataCleanupResult());
      expect(await cleanup, isNotNull);
    });

    test('the cleanup running refuses the organiser', () async {
      final cleanup = clean();
      await pumpEventQueue();

      expect(LibraryFileToolLock.isHeld, isTrue);
      expect(await organize(), isNull);
      expect(MultiDiscOrganizerRunner.isRunning, isFalse);
      expect(row(MultiDiscOrganizerRunner.notificationId), isNull);
      expect(organizeCalls, 0);
      expect(rescanned, isEmpty);

      cleaning.complete(const MetadataCleanupResult());
      await cleanup;
      expect(LibraryFileToolLock.isHeld, isFalse);
    });
  });

  group('the cleanup strings', () {
    test('choose the singular form at exactly one', () {
      expect(cleanupStrings.esdeKept(1), ' 1 kept (one).');
      expect(cleanupStrings.esdeKept(2), ' 2 kept.');
      expect(cleanupStrings.notRemoved(1), ' 1 not removed (one).');
      expect(cleanupStrings.notRemoved(0), ' 0 not removed.');
    });
  });

  test('the still-running message is in every language', () {
    final locales = {
      'de': AppLocale.de,
      'en': AppLocale.en,
      'es': AppLocale.es,
      'fr': AppLocale.fr,
      'id': AppLocale.id,
      'it': AppLocale.it,
      'ja': AppLocale.ja,
      'ko': AppLocale.ko,
      'pt': AppLocale.pt,
      'ru': AppLocale.ru,
      'zh': AppLocale.zh,
      'zh_Hant': AppLocale.zhHant,
    };
    expect(
      AppLocale.en[AppLocale.toolsStillRunning],
      'A tool is still running. Wait until it finishes.',
    );
    for (final MapEntry(key: code, value: map) in locales.entries) {
      final value = map[AppLocale.toolsStillRunning];
      expect(value, isA<String>(), reason: code);
      expect((value as String).trim(), isNotEmpty, reason: code);
      expect(value, isNot(contains('{')), reason: code);
      if (code != 'en') {
        expect(
          value,
          isNot(AppLocale.en[AppLocale.toolsStillRunning]),
          reason: code,
        );
      }
    }
  });
}
