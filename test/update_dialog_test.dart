import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/update_service.dart';
import 'package:neostation/widgets/update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

/// The app-update dialogue had no way out once the download started: B did
/// nothing, so a stalled download left it stuck. On Android every failure
/// said the permission to install unknown apps was missing, even a failed
/// download. It now offers Cancel while downloading, closes quietly when
/// cancelled, and only blames the permission when that is what failed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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

  setUp(() {
    GlobalNotificationService().dismiss();
    resetGamepadClock();
  });
  tearDown(restoreGamepadClock);

  final info = UpdateInfo(
    currentVersion: '1.0.0',
    latestVersion: '2.0.0',
    downloadUrl: 'http://127.0.0.1/neostation.apk',
    fileName: 'neostation.apk',
    fileSize: 40 * 1024 * 1024,
  );

  const size = Size(640, 480);

  /// Opens the dialogue with [runner] and returns the future of its result.
  Future<Future<bool?>> openDialog(
    WidgetTester tester,
    UpdateRunner runner,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext hostContext;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: ScreenUtilInit(
          designSize: size,
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Builder(
              builder: (context) {
                hostContext = context;
                return const Scaffold();
              },
            ),
          ),
        ),
      ),
    );
    // ScreenUtilInit builds its child once it has a size.
    await tester.pump();
    final result = showDialog<bool>(
      context: hostContext,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(updateInfo: info, runner: runner),
    );
    await tester.pumpAndSettle();
    return result;
  }

  List<String> shownMessages() => [
    for (final n in GlobalNotificationService().notifier.value) n.message,
  ];

  /// A runner that stays in its download until [finish] completes.
  UpdateRunner runnerUntil(
    Completer<UpdateOutcome> finish, {
    void Function(bool Function()? shouldCancel)? capture,
  }) {
    return (info, onProgress, {shouldCancel}) {
      capture?.call(shouldCancel);
      onProgress?.call(0.3);
      return finish.future;
    };
  }

  testWidgets('Cancel is offered while downloading', (tester) async {
    await openDialog(tester, runnerUntil(Completer()));
    expect(find.text('Cancel'), findsNothing);

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    expect(find.text('Cancel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel asks the download to stop', (tester) async {
    bool Function()? shouldCancel;
    await openDialog(
      tester,
      runnerUntil(Completer(), capture: (s) => shouldCancel = s),
    );
    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();
    expect(shouldCancel!(), isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(shouldCancel!(), isTrue);
    expect(find.text('Cancelling...'), findsOneWidget);
  });

  testWidgets('B while downloading asks the download to stop', (tester) async {
    bool Function()? shouldCancel;
    await openDialog(
      tester,
      runnerUntil(Completer(), capture: (s) => shouldCancel = s),
    );
    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();
    // Navigation ignores keys for a moment after it activates.
    advanceGamepadClock(const Duration(milliseconds: 600));

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(shouldCancel!(), isTrue);
  });

  testWidgets('once downloaded, the update can no longer be cancelled', (
    tester,
  ) async {
    bool Function()? captured;
    await openDialog(tester, (info, onProgress, {shouldCancel}) {
      captured = shouldCancel;
      onProgress?.call(1.0);
      return Completer<UpdateOutcome>().future;
    });
    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();
    advanceGamepadClock(const Duration(milliseconds: 600));

    expect(find.text('Cancel'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(captured!(), isFalse);
  });

  testWidgets('a cancelled download closes the dialogue quietly', (
    tester,
  ) async {
    final finish = Completer<UpdateOutcome>();
    final result = await openDialog(tester, runnerUntil(finish));
    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    finish.complete(UpdateOutcome.cancelled);
    await tester.pumpAndSettle();

    expect(await result, isFalse);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(shownMessages(), isEmpty);
  });

  final generic = AppLocale.en[AppLocale.updateErrorDesktop] as String;
  final permission = AppLocale.en[AppLocale.updateErrorAndroid] as String;

  for (final (outcome, expected) in [
    (UpdateOutcome.downloadFailed, generic),
    (UpdateOutcome.installFailed, generic),
    (UpdateOutcome.installPermissionDenied, permission),
  ]) {
    testWidgets('$outcome says "$expected"', (tester) async {
      final finish = Completer<UpdateOutcome>();
      await openDialog(tester, runnerUntil(finish));
      await tester.tap(find.text('UPDATE NOW'));
      await tester.pump();

      finish.complete(outcome);
      await tester.pumpAndSettle();

      expect(shownMessages(), [expected]);
      // The dialogue stays open, ready to try again.
      expect(find.text('UPDATE NOW'), findsOneWidget);
    });
  }
}
