import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/saves_screen/kept_copies_view.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/kept_save_copies.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

/// The list of kept copies: what each row says, and that restoring and
/// deleting ask first, refuse while a game or sync could write the save, and
/// show the list again afterwards.

final _game = GameModel(
  romname: 'Zelda.sfc',
  realname: 'Zelda',
  name: 'Zelda',
  year: '1992',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/snes/Zelda.sfc',
  systemFolderName: 'snes',
);

/// Answers with [groups] and records what it was asked to do.
class _FakeCopies extends KeptSaveCopies {
  _FakeCopies(this.groups) : super(NeoSyncProvider(NeoSyncService()));

  List<KeptSaveGroup> groups;
  KeptCopyRefusal? refusal;
  Object? restoreError;
  final restored = <String>[];
  final deleted = <String>[];
  int loads = 0;

  @override
  Future<List<KeptSaveGroup>> forGame(
    GameModel game, {
    bool compareWithSave = true,
  }) async {
    loads++;
    return groups;
  }

  @override
  Future<List<KeptSaveGroup>> all() async {
    loads++;
    return groups;
  }

  @override
  KeptCopyRefusal? whyNotNow([GameModel? game, String? copyPath]) => refusal;

  @override
  Future<KeptCopyRestore> restore(String copyPath, {GameModel? game}) async {
    final error = restoreError;
    if (error != null) throw error;
    restored.add(copyPath);
    return KeptCopyRestore(savePath: '/saves/Zelda.srm');
  }

  @override
  Future<void> delete(String copyPath) async => deleted.add(copyPath);
}

KeptSaveCopy _copy(
  String path,
  KeptCopySource source, {
  bool same = false,
  int size = 2048,
  DateTime? modified,
}) => KeptSaveCopy(
  path: path,
  source: source,
  size: size,
  modified: modified ?? DateTime(2026, 11, 1, 9, 30),
  stampedAt: null,
  sameAsSave: same,
);

KeptSaveGroup _group(String savePath, List<KeptSaveCopy> copies) =>
    KeptSaveGroup(
      savePath: savePath,
      saveExists: true,
      saveSize: 8192,
      saveModified: DateTime(2026, 11, 9, 20, 5),
      copies: copies,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bell = GlobalNotificationService();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(bell.dismiss);
  tearDown(bell.dismiss);

  String en(String key) => AppLocale.en[key] as String;

  Future<void> pumpView(
    WidgetTester tester,
    _FakeCopies copies, {
    GameModel? game,
    VoidCallback? onBack,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: KeptCopiesView(
                game: game,
                copies: copies,
                onBack: onBack ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists each save with its copies, where they came from, '
      'their date and size', (tester) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy(
          '/saves/Zelda.srm.cloud-20261101-093000.neosync.bak',
          KeptCopySource.otherDevice,
        ),
        _copy(
          '/saves/Zelda.srm.neosync.bak',
          KeptCopySource.beforeDownload,
          same: true,
          modified: DateTime(2026, 11, 1, 8, 15),
        ),
      ]),
    ]);
    await pumpView(tester, copies, game: _game);

    expect(find.text('Zelda.srm'), findsOneWidget);
    expect(
      find.text(
        en(AppLocale.keptCopyCurrentSave)
            .replaceFirst('{size}', '8.0 KB')
            .replaceFirst('{date}', '2026-11-09 20:05'),
      ),
      findsOneWidget,
    );
    // When each was made leads; where it came from goes beneath it.
    expect(find.text('2026-11-01 09:30'), findsOneWidget);
    expect(find.text('2026-11-01 08:15'), findsOneWidget);
    expect(
      find.text('${en(AppLocale.keptCopyFromOtherDevice)} · 2.0 KB'),
      findsOneWidget,
    );
    expect(
      find.text(
        '${en(AppLocale.keptCopyBeforeDownload)} · 2.0 KB · '
        '${en(AppLocale.keptCopySameAsSave)}',
      ),
      findsOneWidget,
    );
  });

  // Copies of a save kept in the same minute would otherwise read the same.
  testWidgets('copies of a save kept in the same minute show seconds', (
    tester,
  ) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy(
          '/saves/Zelda.srm.romm-conflict-2026-11-01_09-30-50',
          KeptCopySource.serverConflict,
          modified: DateTime(2026, 11, 1, 9, 30, 50),
        ),
        _copy(
          '/saves/Zelda.srm.romm-conflict-2026-11-01_09-30-10',
          KeptCopySource.serverConflict,
          modified: DateTime(2026, 11, 1, 9, 30, 10),
        ),
        _copy(
          '/saves/Zelda.srm.romm-conflict-2026-11-01_08-00-00',
          KeptCopySource.serverConflict,
          modified: DateTime(2026, 11, 1, 8, 0, 5),
        ),
      ]),
      // Another save's copy in the same minute changes nothing here.
      _group('/saves/Metroid.srm', [
        _copy(
          '/saves/Metroid.srm.neosync.bak',
          KeptCopySource.beforeDownload,
          modified: DateTime(2026, 11, 1, 9, 30, 30),
        ),
      ]),
    ]);
    await pumpView(tester, copies, game: _game);

    expect(find.text('2026-11-01 09:30:50'), findsOneWidget);
    expect(find.text('2026-11-01 09:30:10'), findsOneWidget);
    expect(find.text('2026-11-01 08:00'), findsOneWidget);
    expect(find.text('2026-11-01 09:30'), findsOneWidget);
  });

  testWidgets('says when there are none', (tester) async {
    await pumpView(tester, _FakeCopies([]));
    expect(find.text(en(AppLocale.keptCopiesNone)), findsOneWidget);
  });

  testWidgets('every RomM and restore label is shown', (tester) async {
    await pumpView(
      tester,
      _FakeCopies([
        _group('/saves/Zelda.srm', [
          _copy(
            '/saves/Zelda.srm.romm-conflict-2026-11-06_18-32-44',
            KeptCopySource.serverConflict,
          ),
          _copy(
            '/saves/Zelda.srm.replaced-20261101-093000.neosync.bak',
            KeptCopySource.replaced,
          ),
        ]),
      ]),
    );
    expect(
      find.text('${en(AppLocale.keptCopyFromServer)} · 2.0 KB'),
      findsOneWidget,
    );
    expect(
      find.text('${en(AppLocale.keptCopyReplaced)} · 2.0 KB'),
      findsOneWidget,
    );
  });

  testWidgets('restoring asks first, then restores and lists again', (
    tester,
  ) async {
    const path = '/saves/Zelda.srm.neosync.bak';
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [_copy(path, KeptCopySource.beforeDownload)]),
    ]);
    await pumpView(tester, copies, game: _game);
    expect(copies.loads, 1);

    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsOneWidget);
    expect(
      find.text(
        en(AppLocale.keptCopyRestoreBody).replaceFirst('{file}', 'Zelda.srm'),
      ),
      findsOneWidget,
    );
    expect(copies.restored, isEmpty);

    await tester.tap(find.text(en(AppLocale.keptCopyRestore)).last);
    await tester.pumpAndSettle();

    expect(copies.restored, [path]);
    expect(copies.loads, 2);
    expect(
      bell.notifier.value.map((n) => n.message),
      contains(en(AppLocale.keptCopyRestored)),
    );
  });

  testWidgets('cancelling the question restores nothing', (tester) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy('/saves/Zelda.srm.neosync.bak', KeptCopySource.beforeDownload),
      ]),
    ]);
    await pumpView(tester, copies, game: _game);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en(AppLocale.cancel)));
    await tester.pumpAndSettle();
    expect(copies.restored, isEmpty);
  });

  testWidgets('a shared memory card warns that every game is affected', (
    tester,
  ) async {
    final copies = _FakeCopies([
      _group('/saves/Mcd001.ps2', [
        _copy('/saves/Mcd001.ps2.neosync.bak', KeptCopySource.beforeDownload),
      ]),
    ]);
    await pumpView(tester, copies);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '${en(AppLocale.keptCopyRestoreBody).replaceFirst('{file}', 'Mcd001.ps2')}'
        '\n\n${en(AppLocale.keptCopySharedCard)}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('while a game runs, says to close it and asks nothing', (
    tester,
  ) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy('/saves/Zelda.srm.neosync.bak', KeptCopySource.beforeDownload),
      ]),
    ])..refusal = KeptCopyRefusal.gameRunning;
    await pumpView(tester, copies, game: _game);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();

    expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsNothing);
    expect(copies.restored, isEmpty);
    expect(
      bell.notifier.value.map((n) => n.message),
      contains(en(AppLocale.keptCopyCloseGame)),
    );
  });

  testWidgets('while a sync runs, says to wait', (tester) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy('/saves/Zelda.srm.neosync.bak', KeptCopySource.beforeDownload),
      ]),
    ])..refusal = KeptCopyRefusal.syncing;
    await pumpView(tester, copies, game: _game);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    expect(copies.restored, isEmpty);
    expect(
      bell.notifier.value.map((n) => n.message),
      contains(en(AppLocale.keptCopyWaitForSync)),
    );
  });

  testWidgets('a failed restore says so', (tester) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy('/saves/Zelda.srm.neosync.bak', KeptCopySource.beforeDownload),
      ]),
    ])..restoreError = Exception('disk full');
    await pumpView(tester, copies, game: _game);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)).last);
    await tester.pumpAndSettle();
    expect(
      bell.notifier.value.map((n) => n.message),
      contains(en(AppLocale.keptCopyRestoreFailed)),
    );
  });

  testWidgets('a copy that matches the save has nothing to restore', (
    tester,
  ) async {
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy(
          '/saves/Zelda.srm.neosync.bak',
          KeptCopySource.beforeDownload,
          same: true,
        ),
      ]),
    ]);
    await pumpView(tester, copies, game: _game);
    await tester.tap(find.text(en(AppLocale.keptCopyRestore)));
    await tester.pumpAndSettle();
    expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsNothing);
    expect(copies.restored, isEmpty);
  });

  testWidgets('deleting asks first, then deletes the chosen copy', (
    tester,
  ) async {
    const first = '/saves/Zelda.srm.cloud-20261101-093000.neosync.bak';
    const second = '/saves/Zelda.srm.neosync.bak';
    final copies = _FakeCopies([
      _group('/saves/Zelda.srm', [
        _copy(first, KeptCopySource.otherDevice),
        _copy(second, KeptCopySource.beforeDownload),
      ]),
    ]);
    await pumpView(tester, copies, game: _game);

    await tester.tap(
      find.text('${en(AppLocale.keptCopyBeforeDownload)} · 2.0 KB'),
    );
    await tester.pump();
    await tester.tap(find.text(en(AppLocale.delete)));
    await tester.pumpAndSettle();
    expect(find.text(en(AppLocale.keptCopyDeleteTitle)), findsOneWidget);
    expect(
      find.text(
        en(AppLocale.keptCopyDeleteBody)
            .replaceFirst('{file}', 'Zelda.srm.neosync.bak'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(en(AppLocale.delete)).last);
    await tester.pumpAndSettle();

    expect(copies.deleted, [second]);
    expect(copies.loads, 2);
  });

  testWidgets('back leaves the view', (tester) async {
    var left = false;
    await pumpView(tester, _FakeCopies([]), onBack: () => left = true);
    await tester.tap(find.text(en(AppLocale.back)));
    await tester.pumpAndSettle();
    expect(left, isTrue);
  });

  group('with the D-pad', () {
    setUp(resetGamepadClock);
    tearDown(restoreGamepadClock);

    /// A navigator ignores input for a moment after it activates, so the key
    /// is sent once that has passed.
    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      advanceGamepadClock(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('down moves to the next copy, and A restores that one', (
      tester,
    ) async {
      const first = '/saves/Zelda.srm.cloud-20261101-093000.neosync.bak';
      const second = '/saves/Zelda.srm.neosync.bak';
      final copies = _FakeCopies([
        _group('/saves/Zelda.srm', [
          _copy(first, KeptCopySource.otherDevice),
          _copy(second, KeptCopySource.beforeDownload),
        ]),
      ]);
      await pumpView(tester, copies, game: _game);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsOneWidget);
      await tester.tap(find.text(en(AppLocale.keptCopyRestore)).last);
      await tester.pumpAndSettle();

      expect(copies.restored, [second]);
    });

    testWidgets('A on a copy that matches the save asks nothing', (
      tester,
    ) async {
      final copies = _FakeCopies([
        _group('/saves/Zelda.srm', [
          _copy(
            '/saves/Zelda.srm.neosync.bak',
            KeptCopySource.beforeDownload,
            same: true,
          ),
        ]),
      ]);
      await pumpView(tester, copies, game: _game);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsNothing);
      expect(copies.restored, isEmpty);
    });

    testWidgets('a second A while the question is open asks nothing more', (
      tester,
    ) async {
      final copies = _FakeCopies([
        _group('/saves/Zelda.srm', [
          _copy('/saves/Zelda.srm.neosync.bak', KeptCopySource.beforeDownload),
        ]),
      ]);
      await pumpView(tester, copies, game: _game);
      advanceGamepadClock(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // Past the navigator's repeat pacing, but before the question's own
      // layer takes the D-pad (it does so after the next frame).
      advanceGamepadClock(const Duration(milliseconds: 600));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(en(AppLocale.keptCopyRestoreTitle)), findsOneWidget);
    });

    testWidgets('B leaves the view', (tester) async {
      var left = false;
      await pumpView(tester, _FakeCopies([]), onBack: () => left = true);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(left, isTrue);
    });
  });

  test('dates as the list shows them', () {
    expect(
      formatKeptCopyDate(DateTime(2026, 1, 2, 3, 4, 5)),
      '2026-01-02 03:04',
    );
    expect(
      formatKeptCopyDate(DateTime(2026, 1, 2, 3, 4, 5), seconds: true),
      '2026-01-02 03:04:05',
    );
  });
}
