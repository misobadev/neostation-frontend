import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/services/update_service.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/folder_not_empty_dialog.dart';
import 'package:neostation/widgets/move_user_data_dialog.dart';
import 'package:neostation/widgets/systems_update_dialog.dart';
import 'package:neostation/widgets/update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Later / Cancel buttons of the update and folder dialogues sit on the
/// theme's tertiary colour, which follows primary. Their labels must use the
/// matching onTertiary colour: onSurface is the same colour as primary in the
/// Dark and Light themes, which left the labels invisible.
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

  String en(String key) => AppLocale.en[key] as String;

  Future<void> pumpDialog(
    WidgetTester tester,
    ThemeData theme,
    Widget dialog,
  ) async {
    // ScreenUtil scales by the smaller axis, so the extra height keeps the
    // 640x480 scale while leaving room for the test font, whose wider glyphs
    // wrap the Move user data text onto more lines than a real font does.
    const size = Size(640, 600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            theme: theme,
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(body: dialog),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Checks that the button labelled [label] draws its text in onTertiary on
  /// a tertiary background.
  void expectReadableSecondary(WidgetTester tester, String label) {
    final control = find.byWidgetPredicate(
      (w) => w is GamepadControl && w.label == label,
    );
    expect(control, findsOneWidget);

    final colorScheme = Theme.of(tester.element(control)).colorScheme;
    final text = tester.widget<Text>(
      find.descendant(of: control, matching: find.text(label)),
    );
    expect(
      tester.widget<GamepadControl>(control).backgroundColor,
      colorScheme.tertiary,
    );
    expect(text.style?.color, colorScheme.onTertiary);
  }

  final appUpdate = UpdateInfo(
    currentVersion: '0.1.0',
    latestVersion: '99.0.0',
    downloadUrl: 'https://example.invalid/neostation.apk',
    fileName: 'neostation.apk',
    fileSize: 1,
  );

  SystemsUpdateRunner pendingRunner() =>
      ({knownUpdate, onProgress, shouldCancel}) =>
          Completer<SystemsUpdateResult?>().future;

  for (final entry in ThemeProvider.availableThemes.entries) {
    group('${entry.key} theme', () {
      testWidgets('app update: Later', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          UpdateDialog(updateInfo: appUpdate),
        );
        expectReadableSecondary(tester, en(AppLocale.updateLater));
      });

      testWidgets('app update: Cancel while downloading', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          UpdateDialog(
            updateInfo: appUpdate,
            runner: (info, onProgress, {shouldCancel}) =>
                Completer<UpdateOutcome>().future,
          ),
        );
        await tester.tap(find.text(en(AppLocale.updateNow)));
        await tester.pump();
        expectReadableSecondary(tester, en(AppLocale.cancel));
      });

      testWidgets('systems update: Later', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          SystemsUpdateDialog(
            updateInfo: const SystemsUpdateInfo(
              currentVersion: '0.3.9',
              remoteVersion: '0.3.11',
            ),
            runner: pendingRunner(),
          ),
        );
        expectReadableSecondary(tester, en(AppLocale.updateLater));
      });

      testWidgets('systems update: Cancel while downloading', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          SystemsUpdateDialog(
            updateInfo: const SystemsUpdateInfo(
              currentVersion: '0.3.9',
              remoteVersion: '0.3.11',
            ),
            runner: pendingRunner(),
          ),
        );
        await tester.tap(find.text(en(AppLocale.updateNow)));
        await tester.pump();
        expectReadableSecondary(tester, en(AppLocale.cancel));
      });

      testWidgets('folder not empty: Cancel', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          const FolderNotEmptyDialog(path: '/roms', itemCount: 3),
        );
        expectReadableSecondary(tester, en(AppLocale.cancel));
      });

      testWidgets('move user data: Cancel', (tester) async {
        await pumpDialog(
          tester,
          entry.value,
          const MoveUserDataDialog(
            fromPath: '/old',
            toPath: '/new',
            destItemCount: 2,
          ),
        );
        expectReadableSecondary(tester, en(AppLocale.cancel));
      });
    });
  }
}
