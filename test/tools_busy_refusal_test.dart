import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/tools_settings_content.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The multi-disc organiser and the orphan cleanup must not overlap (see
/// [LibraryFileToolLock]). Tools used to ignore a press on a running tool, and
/// nothing stopped a press on the other one; it now refuses either while one
/// runs, and says why — in one bell row, however often the user presses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  final notifications = GlobalNotificationService();

  // Tools' row indices, as its selectItem() takes them.
  const cleanupIndex = 1;
  const organiserIndex = 2;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // The confirmation dialogue initialises gamepad navigation; with no
    // plugin behind the channel it would throw, so it finds no devices.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [const MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() async {
    final db = await dbHelper.setUp();
    // A ROM folder, so the organiser gets as far as its confirmation.
    await db.insert('user_rom_folders', {'path': '/roms'});
    LibraryFileToolLock.debugReset();
    notifications.notifier.value = [];
  });

  tearDown(() async {
    LibraryFileToolLock.debugReset();
    notifications.notifier.value = [];
    await dbHelper.tearDown();
  });

  Future<ToolsSettingsContentState> pumpTools(WidgetTester tester) async {
    final key = GlobalKey<ToolsSettingsContentState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => ChangeNotifierProvider<FileProvider>(
            // Never initialised: the cleanup stops at the media folder check,
            // which is past the refusal and before any analysis.
            create: (_) => FileProvider(),
            child: MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Scaffold(
                body: ToolsSettingsContent(
                  key: key,
                  isContentFocused: true,
                  selectedContentIndex: 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The ROM folders load from the real test database; let it settle.
    await tester.runAsync(SqliteService.getUserRomFolders);
    await tester.pump();
    return key.currentState!;
  }

  List<GlobalNotificationData> refusals() => notifications.notifier.value
      .where((n) => n.id == 'tools_still_running')
      .toList();

  testWidgets('a press on either tool while one runs is refused, in one '
      'bell row', (tester) async {
    final tools = await pumpTools(tester);
    expect(LibraryFileToolLock.tryAcquire('x'), isTrue);

    for (var i = 0; i < 3; i++) {
      tools.selectItem(organiserIndex);
      await tester.pump();
      tools.selectItem(cleanupIndex);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Six refusals, one row: the id is reused, so each replaces the last.
    expect(notifications.notifier.value, hasLength(1));
    final row = refusals().single;
    expect(row.message, AppLocale.en[AppLocale.toolsStillRunning]);
    expect(row.type, GlobalNotificationType.info);
    expect(row.ongoing, isFalse);
    // Neither tool got as far as asking.
    expect(find.byType(ConfirmActionDialog), findsNothing);
  });

  testWidgets('once the lock is released, the tools run again', (tester) async {
    final tools = await pumpTools(tester);
    expect(LibraryFileToolLock.tryAcquire('x'), isTrue);
    tools.selectItem(organiserIndex);
    await tester.pump();
    expect(refusals(), hasLength(1));

    LibraryFileToolLock.release('x');
    notifications.notifier.value = [];

    // The organiser asks for confirmation instead of refusing.
    tools.selectItem(organiserIndex);
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmActionDialog), findsOneWidget);
    expect(
      find.text(AppLocale.en[AppLocale.organizeMultiDiscGames] as String),
      findsWidgets,
    );
    await tester.tap(find.text(AppLocale.en[AppLocale.cancel] as String));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmActionDialog), findsNothing);

    // The cleanup gets past the refusal to its media folder check.
    tools.selectItem(cleanupIndex);
    await tester.pumpAndSettle();
    expect(refusals(), isEmpty);
    expect(
      notifications.notifier.value.single.message,
      AppLocale.en[AppLocale.cleanOrphanedMetadataMediaUnavailable],
    );
    expect(LibraryFileToolLock.isHeld, isFalse);
  });

  testWidgets('a tool that starts while the organiser asks refuses the '
      'confirmation', (tester) async {
    final tools = await pumpTools(tester);
    tools.selectItem(organiserIndex);
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmActionDialog), findsOneWidget);

    // The other tool starts while the dialogue is up.
    expect(LibraryFileToolLock.tryAcquire('x'), isTrue);
    await tester.tap(find.text(AppLocale.en[AppLocale.confirm] as String));
    await tester.pumpAndSettle();

    expect(find.byType(ConfirmActionDialog), findsNothing);
    expect(refusals(), hasLength(1));
    // The organiser never took the lock or reported a run.
    expect(LibraryFileToolLock.isHeldBy('x'), isTrue);
    expect(notifications.notifier.value, hasLength(1));
  });
}
