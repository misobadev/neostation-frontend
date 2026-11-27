import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/utils/auto_folder_upload_notice.dart';

/// Entering a system uploads its standalone save folders in the background.
/// When that failed, the only sign was every game's NeoSync mark turning red;
/// now the bell says which folder and why, once per folder, and a later
/// upload that goes through takes the entry away.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bell = GlobalNotificationService();

  setUp(bell.dismiss);
  tearDown(bell.dismiss);

  List<GlobalNotificationData> entries() => bell.notifier.value;

  test('a full account says so, under the system\'s name', () {
    reportAutoFolderUpload(
      system: 'gc',
      emulatorSlug: 'dolphin',
      systemName: 'GameCube',
      outcome: CustomFolderUploadOutcome.quotaExceeded,
    );

    expect(entries(), hasLength(1));
    expect(
      entries().single.message,
      AppLocale.neoSyncQuotaExceeded.getStringForCurrentLocale(),
    );
    expect(entries().single.title, 'GameCube');
    expect(entries().single.type, GlobalNotificationType.error);
  });

  test('any other failure says the folder didn\'t sync', () {
    reportAutoFolderUpload(
      system: 'gc',
      emulatorSlug: 'dolphin',
      systemName: 'GameCube',
      outcome: CustomFolderUploadOutcome.failed,
    );

    expect(
      entries().single.message,
      AppLocale.customFolderUploadFailed.getStringForCurrentLocale(),
    );
  });

  test('a folder that fails again keeps one entry', () {
    for (final outcome in [
      CustomFolderUploadOutcome.failed,
      CustomFolderUploadOutcome.quotaExceeded,
    ]) {
      reportAutoFolderUpload(
        system: 'gc',
        emulatorSlug: 'dolphin',
        systemName: 'GameCube',
        outcome: outcome,
      );
    }

    expect(entries(), hasLength(1));
    expect(
      entries().single.message,
      AppLocale.neoSyncQuotaExceeded.getStringForCurrentLocale(),
    );
  });

  test('each failing folder has its own entry', () {
    reportAutoFolderUpload(
      system: 'gc',
      emulatorSlug: 'dolphin',
      systemName: 'GameCube',
      outcome: CustomFolderUploadOutcome.failed,
    );
    reportAutoFolderUpload(
      system: 'ps2',
      emulatorSlug: 'aethersx2',
      systemName: 'PlayStation 2',
      outcome: CustomFolderUploadOutcome.failed,
    );

    expect(entries(), hasLength(2));
  });

  for (final outcome in [
    CustomFolderUploadOutcome.uploaded,
    CustomFolderUploadOutcome.empty,
  ]) {
    test('an upload that goes through (${outcome.name}) takes the entry '
        'away', () {
      reportAutoFolderUpload(
        system: 'gc',
        emulatorSlug: 'dolphin',
        systemName: 'GameCube',
        outcome: CustomFolderUploadOutcome.failed,
      );
      reportAutoFolderUpload(
        system: 'ps2',
        emulatorSlug: 'aethersx2',
        systemName: 'PlayStation 2',
        outcome: CustomFolderUploadOutcome.failed,
      );

      reportAutoFolderUpload(
        system: 'gc',
        emulatorSlug: 'dolphin',
        systemName: 'GameCube',
        outcome: outcome,
      );

      expect(entries().map((e) => e.title), ['PlayStation 2']);
    });
  }

  for (final outcome in [
    CustomFolderUploadOutcome.busy,
    CustomFolderUploadOutcome.notSignedIn,
    CustomFolderUploadOutcome.noFolder,
  ]) {
    test('an upload that didn\'t run (${outcome.name}) changes nothing', () {
      reportAutoFolderUpload(
        system: 'gc',
        emulatorSlug: 'dolphin',
        systemName: 'GameCube',
        outcome: CustomFolderUploadOutcome.failed,
      );

      reportAutoFolderUpload(
        system: 'gc',
        emulatorSlug: 'dolphin',
        systemName: 'GameCube',
        outcome: outcome,
      );

      expect(entries(), hasLength(1));
    });
  }

  test('entering a system reports each folder\'s automatic upload', () {
    final list = File('lib/screens/game_screen/my_games_list.dart')
        .readAsStringSync();
    final start = list.indexOf('Future<void> _maybeSyncStandaloneFolders(');
    expect(start, isNot(-1));
    final body = list.substring(start, list.indexOf('\n  }\n', start));

    expect(
      body,
      matches(
        RegExp(
          r'final outcome = await provider\.syncCustomSaveFolder\(\s*'
          r'folderName,\s*entry\.key,?\s*\);(?:\s*//[^\n]*)*\s*'
          r'reportAutoFolderUpload\(',
        ),
      ),
    );
  });

  test('clearing one folder leaves the others', () {
    for (final system in ['gc', 'ps2']) {
      reportAutoFolderUpload(
        system: system,
        emulatorSlug: 'emu',
        systemName: system,
        outcome: CustomFolderUploadOutcome.failed,
      );
    }

    clearAutoFolderUploadNotice('gc', 'emu');

    expect(entries().map((e) => e.title), ['ps2']);
  });

  test('clearing them all leaves other entries', () {
    reportAutoFolderUpload(
      system: 'gc',
      emulatorSlug: 'dolphin',
      systemName: 'GameCube',
      outcome: CustomFolderUploadOutcome.failed,
    );
    bell.show(id: 'unrelated', message: 'Scan done');

    clearAllAutoFolderUploadNotices();

    expect(entries().map((e) => e.id), ['unrelated']);
  });

  test('an upload from the folders view that goes through clears the '
      'folder\'s entry', () {
    final view = File(
      'lib/screens/neo_sync_screen/login_screen/custom_save_folders_view.dart',
    ).readAsStringSync();
    for (final outcome in ['uploaded', 'empty']) {
      final start = view.indexOf('case CustomFolderUploadOutcome.$outcome:');
      expect(start, isNot(-1));
      final next = view.indexOf('case ', start + 1);
      final branch = view.substring(start, next == -1 ? view.length : next);
      expect(
        branch,
        contains('clearAutoFolderUploadNotice(system, emulatorSlug)'),
        reason: outcome,
      );
    }
  });

  test('two folders on one system are told apart', () {
    final list = File('lib/screens/game_screen/my_games_list.dart')
        .readAsStringSync();
    expect(
      list,
      matches(
        RegExp(
          r'systemName: folders\.length > 1\s*\?\s*'
          r"'\$\{widget\.system\.realName\} · \$\{path\.basename\(entry\.value\)\}'",
        ),
      ),
    );
  });
}
