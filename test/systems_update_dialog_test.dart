import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/widgets/systems_update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});

    // Stub the gamepads plugin so GamepadNavigation.initialize() finds no
    // devices instead of relying on a real platform channel.
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

  const updateInfo = SystemsUpdateInfo(
    currentVersion: '0.3.9',
    remoteVersion: '0.3.11',
  );

  // Matches ScreenUtilInit in main.dart. At the RG DS's 640x480 panel the
  // scale factor is therefore exactly 1.0, which is the tightest case the
  // dialog ever sees — larger screens scale it up proportionally.
  const appDesignSize = Size(640, 480);

  /// Pumps the dialog at [size] with an injected [runner].
  ///
  /// The RG DS is the smallest panel the app targets, and the download state is
  /// the tallest the dialog ever gets, so 640x480 is the case worth pinning.
  Future<void> pumpDialog(
    WidgetTester tester, {
    required SystemsUpdateRunner runner,
    Size size = const Size(640, 480),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: ScreenUtilInit(
          designSize: appDesignSize,
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: SystemsUpdateDialog(updateInfo: updateInfo, runner: runner),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A runner that never completes, parking the dialog in its download state.
  SystemsUpdateRunner pendingRunner({
    void Function(bool Function()? shouldCancel)? capture,
    void Function(void Function(double, String)? onProgress)? captureProgress,
  }) {
    return ({knownUpdate, onProgress, shouldCancel}) {
      capture?.call(shouldCancel);
      captureProgress?.call(onProgress);
      return Completer<SystemsUpdateResult?>().future;
    };
  }

  for (final size in <Size>[
    const Size(640, 480),
    const Size(1280, 720),
    const Size(1920, 1080),
    const Size(3840, 2160),
  ]) {
    testWidgets('version typography scales with dialog at $size', (
      tester,
    ) async {
      await pumpDialog(tester, runner: pendingRunner(), size: size);
      final scale = math.min(size.width / 640, size.height / 480);
      for (final version in [
        updateInfo.currentVersion,
        updateInfo.remoteVersion,
      ]) {
        final text = tester.widget<Text>(find.textContaining(version));
        expect(text.style?.fontSize, closeTo(9 * scale, 0.01));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('progress typography scales with dialog at $size', (
      tester,
    ) async {
      void Function(double, String)? progress;
      await pumpDialog(
        tester,
        runner: pendingRunner(captureProgress: (p) => progress = p),
        size: size,
      );
      await tester.tap(find.text('UPDATE NOW'));
      await tester.pump();
      progress!(0.5, 'Scaling test progress');
      await tester.pump();
      final scale = math.min(size.width / 640, size.height / 480);
      for (final label in ['Scaling test progress', '50%']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, closeTo(9 * scale, 0.01));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('idle dialog fits a 640x480 panel', (tester) async {
    await pumpDialog(tester, runner: pendingRunner());

    expect(find.text('UPDATE NOW'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download state fits a 640x480 panel', (tester) async {
    await pumpDialog(tester, runner: pendingRunner());

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    // The download state adds a progress bar and a cancel row over the idle
    // layout; an overflow here would surface as a RenderFlex exception.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel control is offered while downloading', (tester) async {
    await pumpDialog(tester, runner: pendingRunner());

    expect(find.text('Cancel'), findsNothing);

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('tapping cancel flips the shouldCancel signal', (tester) async {
    bool Function()? captured;
    await pumpDialog(
      tester,
      runner: pendingRunner(capture: (s) => captured = s),
    );

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!(), isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(captured!(), isTrue);
  });

  testWidgets('progress updates drive the status line', (tester) async {
    void Function(double, String)? progress;
    await pumpDialog(
      tester,
      runner: pendingRunner(captureProgress: (p) => progress = p),
    );

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    progress!(0.5, 'Downloading systems (60/121)...');
    await tester.pump();

    expect(find.text('Downloading systems (60/121)...'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('cancelling freezes the status line at cancelling', (
    tester,
  ) async {
    void Function(double, String)? progress;
    await pumpDialog(
      tester,
      runner: pendingRunner(captureProgress: (p) => progress = p),
    );

    await tester.tap(find.text('UPDATE NOW'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    // Downloads already in flight keep reporting; they must not overwrite the
    // cancelling message.
    progress!(0.9, 'Downloading systems (110/121)...');
    await tester.pump();

    expect(find.text('Cancelling...'), findsOneWidget);
    expect(find.text('Downloading systems (110/121)...'), findsNothing);
  });
}
