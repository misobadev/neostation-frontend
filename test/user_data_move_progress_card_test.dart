import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/widgets/user_data_move_progress_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// NEO-228: Settings rebuilds Directories whenever the user leaves it, so the
// bar of a user-data move that was still running was gone on the way back,
// and every action there did nothing without saying why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  String en(String key) => AppLocale.en[key] as String;

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
  }

  group('the move progress card', () {
    late ValueNotifier<UserDataMoveProgress?> progress;

    setUp(() => progress = ValueNotifier(null));
    tearDown(() => progress.dispose());

    testWidgets('shows nothing when no move runs', (tester) async {
      await pump(tester, UserDataMoveProgressCard(progress: progress));

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(en(AppLocale.migratingUserData)), findsNothing);
    });

    testWidgets('shows a move that was already running when it opened', (
      tester,
    ) async {
      progress.value = const UserDataMoveProgress(0.3, 'nes.xml');

      await pump(tester, UserDataMoveProgressCard(progress: progress));

      expect(find.text(en(AppLocale.migratingUserData)), findsOneWidget);
      expect(find.text('30%'), findsOneWidget);
      expect(find.text('nes.xml'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.3);
    });

    testWidgets('follows the move and goes when it ends', (tester) async {
      await pump(tester, UserDataMoveProgressCard(progress: progress));

      progress.value = const UserDataMoveProgress(0.1, 'a.xml');
      await tester.pump();
      expect(find.text('10%'), findsOneWidget);

      progress.value = const UserDataMoveProgress(0.4, 'b.xml');
      await tester.pump();
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('b.xml'), findsOneWidget);

      progress.value = null;
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('says the data is still moving at the half-way mark', (
      tester,
    ) async {
      // At 50 % the copies are renamed into place: nothing is deleted yet.
      progress.value = const UserDataMoveProgress(0.5, '');

      await pump(tester, UserDataMoveProgressCard(progress: progress));

      expect(find.text(en(AppLocale.migratingUserData)), findsOneWidget);
      expect(
        find.text(en(AppLocale.userDataMoveRemovingOldCopy)),
        findsNothing,
      );
    });

    testWidgets('says the old copy is being removed past half-way', (
      tester,
    ) async {
      progress.value = const UserDataMoveProgress(0.75, 'a.png');

      await pump(tester, UserDataMoveProgressCard(progress: progress));

      expect(
        find.text(en(AppLocale.userDataMoveRemovingOldCopy)),
        findsOneWidget,
      );
      expect(find.text(en(AppLocale.migratingUserData)), findsNothing);
      expect(find.text('75%'), findsOneWidget);
    });

    testWidgets('follows the move service by default', (tester) async {
      UserDataLocationService.progress.value = const UserDataMoveProgress(
        0.2,
        'x.xml',
      );
      addTearDown(() => UserDataLocationService.progress.value = null);

      await pump(tester, const UserDataMoveProgressCard());

      expect(find.text('20%'), findsOneWidget);
    });
  });

  group('an action refused while the data moves', () {
    final bell = GlobalNotificationService();
    setUp(bell.dismiss);
    tearDown(bell.dismiss);

    testWidgets('says why, once however often it is tried', (tester) async {
      late BuildContext context;
      await pump(
        tester,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );

      reportUserDataMoveRunning(context);
      reportUserDataMoveRunning(context);
      reportUserDataMoveRunning(context);

      expect(bell.notifier.value, hasLength(1));
      expect(
        bell.notifier.value.single.message,
        en(AppLocale.userDataMoveRunning),
      );
    });

    testWidgets('is taken away once the move has ended', (tester) async {
      late BuildContext context;
      await pump(
        tester,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      reportUserDataMoveRunning(context);
      bell.show(id: 'other', message: 'unrelated');

      clearUserDataMoveRunningNotice();

      expect(bell.notifier.value.map((n) => n.id), ['other']);
    });
  });
}
