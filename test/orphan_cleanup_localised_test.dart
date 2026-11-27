import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';
import 'package:neostation/services/multi_disc_organizer_runner.dart';
import 'package:neostation/services/orphan_cleanup_runner.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';
import 'package:neostation/utils/count_label.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings > Tools > Clean Orphaned Metadata built its confirmation in
/// English, whatever the app language ("Found 3 orphaned metadata entr(y|ies).
/// 3 will be deleted…"), and showed "File provider not initialized" as the
/// error detail. When the only orphans were ES-DE imports, which the tool never
/// deletes, it still asked to delete "0" of them, then reported "No orphaned
/// metadata found" as an error, on every run. And both this tool and the
/// multi-disc organiser showed an informational outcome (nothing to do) as an
/// error in the notification bell.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final source = File(
    'lib/screens/settings_screen/new_settings_options/'
    'tools_settings_content.dart',
  ).readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  late final clean = method('Future<void> _cleanOrphanedMetadata()');

  group('the confirmation', () {
    test('builds no English in code', () {
      expect(clean, isNot(contains("'Found ")));
      expect(clean, isNot(contains('entr\${')));
      expect(clean, isNot(contains('will be deleted')));
      expect(clean, isNot(contains('will be left untouched')));
      expect(clean, isNot(contains("'File provider not initialized'")));
    });

    test('counts through the singular/plural helpers', () {
      expect(
        clean,
        contains('orphanedMetadataDeleteLabel(context, neoStationCount)'),
      );
      // On its own line in the confirmation, so without its separator, and
      // only when there are ES-DE entries.
      expect(
        clean,
        matches(
          RegExp(
            r'if \(esdeCount > 0\) \{\s*body\.writeln\(\s*'
            r'esdeEntriesKeptSuffix\(context, esdeCount\)\.trim\(\),?\s*\);',
          ),
        ),
      );
      // The completion note is built by the runner, which has no context, so
      // the screen resolves both forms up front; orphanCleanupOutcome gives
      // it the count of entries actually skipped (tools_outcome_test), and
      // OrphanCleanupStrings picks the form the way the helpers do
      // (tools_runners_test).
      final strings = method('OrphanCleanupStrings _orphanCleanupStrings()');
      for (final (field, key) in [
        ('esdeKeptOne', 'cleanOrphanedMetadataEsdeSkippedSuffixOne'),
        ('esdeKeptMany', 'cleanOrphanedMetadataEsdeSkippedSuffix'),
        ('notRemovedOne', 'cleanOrphanedMetadataNotRemovedOne'),
        ('notRemovedMany', 'cleanOrphanedMetadataNotRemoved'),
      ]) {
        expect(
          strings,
          matches(RegExp('$field:\\s*AppLocale\\.$key\\s*\\.getString')),
          reason: field,
        );
      }
      expect(
        clean,
        isNot(contains('AppLocale.cleanOrphanedMetadataEsdeSkippedSuffix')),
      );
    });

    test('says the media folder is unavailable in the app language', () {
      final guard = RegExp(
        r'if \(!fileProvider\.isInitialized\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(clean);
      expect(guard, isNotNull);
      expect(
        guard!.group(1),
        contains('AppLocale.cleanOrphanedMetadataMediaUnavailable'),
      );
    });

    test('is not offered when only ES-DE entries are orphaned', () {
      final onlyEsde = RegExp(
        r'if \(neoStationCount == 0\) \{(.*?)\n    \}',
        dotAll: true,
      ).firstMatch(clean);
      expect(onlyEsde, isNotNull, reason: 'no check for nothing to delete');
      final block = onlyEsde!.group(1)!;
      expect(block, contains('InfoDialog.show('));
      expect(block, contains('cleanOrphanedMetadataNothingToDelete'));
      expect(
        block,
        contains('esdeEntriesKeptSuffix(context, esdeCount).trim()'),
      );
      expect(block, contains('return;'));
      expect(block, isNot(contains('ConfirmActionDialog')));
      // The check comes before the Delete confirmation.
      expect(
        clean.indexOf('if (neoStationCount == 0)'),
        lessThan(clean.indexOf('ConfirmActionDialog.show(')),
      );
    });
  });

  group('the outcome notification', () {
    final notifications = GlobalNotificationService();

    setUp(() {
      LibraryFileToolLock.debugReset();
      notifications.notifier.value = [];
    });
    tearDown(() {
      MultiDiscOrganizerRunner.debugReset();
      OrphanCleanupRunner.debugReset();
      LibraryFileToolLock.debugReset();
      notifications.notifier.value = [];
    });

    const cleanupStrings = OrphanCleanupStrings(
      scanning: 'Scanning',
      cleaningItemTemplate: 'Cleaning {filename}',
      failedTemplate: 'Failed: {error}',
      done: 'Cleaned {entries} entries and {files} files.',
      nothingFound: 'Nothing found.',
      nothingToDelete: 'Nothing to delete.',
      esdeKeptOne: ' {count} kept.',
      esdeKeptMany: ' {count} kept.',
      notRemovedOne: ' {count} not removed.',
      notRemovedMany: ' {count} not removed.',
    );

    Future<GlobalNotificationData> cleanRow(
      MetadataCleanupResult result,
    ) async {
      OrphanCleanupRunner.clean = ({mediaDirectoryPath, onProgress}) async =>
          result;
      await OrphanCleanupRunner.run(
        mediaDirectoryPath: '/media',
        strings: cleanupStrings,
      );
      return notifications.notifier.value.singleWhere(
        (n) => n.id == OrphanCleanupRunner.notificationId,
      );
    }

    test('says the cleanup failed when nothing could be deleted', () async {
      // A failed delete lands in result.errors, not result.deletedItems, so
      // a run where every delete failed has no deletions.
      const item = OrphanedMetadataItem(
        appSystemId: 'psx',
        filename: 'a.chd',
        systemFolderName: 'psx',
        isFullyScraped: true,
        esdeImported: false,
      );
      final row = await cleanRow(
        const MetadataCleanupResult(orphanedItems: [item], errors: ['x']),
      );
      expect(row.message, '1 not removed.');
      expect(row.type, GlobalNotificationType.error);
    });

    test('orphan cleanup keeps its type: info stays info', () async {
      final row = await cleanRow(const MetadataCleanupResult());
      expect(row.message, 'Nothing found.');
      expect(row.type, GlobalNotificationType.info);
    });

    test('multi-disc organiser keeps its type: info stays info', () async {
      MultiDiscOrganizerRunner.loadSystems = () async => const <SystemModel>[];
      MultiDiscOrganizerRunner.organize =
          (
            roots, {
            required supportedRomExtensions,
            supportedSystemFolders,
            onProgress,
          }) async => const RomFolderOrganizerResult(
            groupsOrganized: 0,
            foldersCreated: 0,
            filesMoved: 0,
            playlistsCreated: 0,
            rootsSkipped: 0,
            groupsFailed: 0,
          );
      await MultiDiscOrganizerRunner.run(
        romFolders: const ['/roms'],
        strings: const MultiDiscOrganizerStrings(
          scanning: 'Scanning',
          done: 'Done',
          noSetsFound: 'No sets found{skipped}.',
          partialFailure: '{failed} failed. {result}',
          skippedSuffix: ' ({count} skipped)',
          failedTemplate: 'Failed: {error}',
        ),
        rescanSystem: (_) async {},
      );
      final row = notifications.notifier.value.singleWhere(
        (n) => n.id == MultiDiscOrganizerRunner.notificationId,
      );
      expect(row.message, 'No sets found.');
      expect(row.type, GlobalNotificationType.info);
    });
  });

  group('the count strings', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await FlutterLocalization.instance.ensureInitialized();
      FlutterLocalization.instance.init(
        mapLocales: [
          const MapLocale('en', AppLocale.en),
          const MapLocale('de', AppLocale.de),
          const MapLocale('ru', AppLocale.ru),
        ],
        initLanguageCode: 'en',
      );
    });

    Future<String> label(
      WidgetTester tester,
      String languageCode,
      String Function(BuildContext) build,
    ) async {
      FlutterLocalization.instance.translate(languageCode);
      late String result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          locale: Locale(languageCode),
          home: Builder(
            builder: (context) {
              result = build(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      return result;
    }

    testWidgets('the delete line changes form at exactly one', (tester) async {
      expect(
        await label(tester, 'en', (c) => orphanedMetadataDeleteLabel(c, 1)),
        '1 orphaned metadata entry will be deleted from the database and '
        'disk.',
      );
      expect(
        await label(tester, 'en', (c) => orphanedMetadataDeleteLabel(c, 3)),
        '3 orphaned metadata entries will be deleted from the database and '
        'disk.',
      );
      // ru puts the count of the many form last.
      expect(
        await label(tester, 'ru', (c) => orphanedMetadataDeleteLabel(c, 7)),
        endsWith(': 7.'),
      );
    });

    test('the not-removed note changes form at exactly one', () {
      // Only the runner reports it, from the two forms Tools resolves up
      // front, so it is checked on the runner's strings with the real text.
      final strings = OrphanCleanupStrings(
        scanning: '',
        cleaningItemTemplate: '',
        failedTemplate: '',
        done: '',
        nothingFound: '',
        nothingToDelete: '',
        esdeKeptOne: '',
        esdeKeptMany: '',
        notRemovedOne:
            AppLocale.en[AppLocale.cleanOrphanedMetadataNotRemovedOne]
                as String,
        notRemovedMany:
            AppLocale.en[AppLocale.cleanOrphanedMetadataNotRemoved] as String,
      );
      expect(
        strings.notRemoved(1),
        " 1 entry couldn't be removed. Run the tool again to retry.",
      );
      expect(
        strings.notRemoved(3),
        " 3 entries couldn't be removed. Run the tool again to retry.",
      );
    });

    testWidgets('the ES-DE note changes form at exactly one and carries its '
        'own separator', (tester) async {
      expect(
        await label(tester, 'en', (c) => esdeEntriesKeptSuffix(c, 1)),
        ' 1 ES-DE imported entry is left untouched.',
      );
      expect(
        await label(tester, 'en', (c) => esdeEntriesKeptSuffix(c, 2)),
        ' 2 ES-DE imported entries are left untouched.',
      );
      // de had no leading space, so the note ran into the sentence before.
      expect(
        await label(tester, 'de', (c) => esdeEntriesKeptSuffix(c, 2)),
        startsWith(' 2 '),
      );
    });
  });

  group('every language', () {
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
    const counted = [
      AppLocale.cleanOrphanedMetadataDelete,
      AppLocale.cleanOrphanedMetadataDeleteOne,
      AppLocale.cleanOrphanedMetadataEsdeSkippedSuffix,
      AppLocale.cleanOrphanedMetadataEsdeSkippedSuffixOne,
    ];
    const plain = [
      AppLocale.cleanOrphanedMetadataNothingToDelete,
      AppLocale.cleanOrphanedMetadataMediaUnavailable,
    ];
    // Languages that put a space between sentences; the ES-DE note is
    // appended straight onto another sentence, so it has to start with one.
    const spaced = {'de', 'en', 'es', 'fr', 'id', 'it', 'ko', 'pt', 'ru'};

    for (final MapEntry(key: code, value: map) in locales.entries) {
      test('$code translates the new strings', () {
        for (final key in [...counted, ...plain]) {
          final value = map[key];
          expect(value, isA<String>(), reason: '$code $key missing');
          expect((value as String).trim(), isNotEmpty, reason: '$code $key');
          if (code != 'en') {
            expect(value, isNot(AppLocale.en[key]), reason: '$code $key');
          }
        }
        for (final key in counted) {
          expect(
            '{count}'.allMatches(map[key] as String).length,
            1,
            reason: '$code $key',
          );
        }
        for (final key in plain) {
          expect(map[key], isNot(contains('{')), reason: '$code $key');
        }
        for (final key in [
          AppLocale.cleanOrphanedMetadataEsdeSkippedSuffix,
          AppLocale.cleanOrphanedMetadataEsdeSkippedSuffixOne,
        ]) {
          final value = map[key] as String;
          if (spaced.contains(code)) {
            expect(value, startsWith(' '), reason: '$code $key');
            expect(value, isNot(startsWith('  ')), reason: '$code $key');
          } else {
            expect(value, isNot(startsWith(' ')), reason: '$code $key');
          }
        }
      });
    }
  });
}
