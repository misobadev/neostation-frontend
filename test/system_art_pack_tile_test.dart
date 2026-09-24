import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/system_art_pack_dialog.dart';
import 'package:neostation/widgets/system_art_pack_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  const pack = NeoAssetsTheme(
    name: 'NeoStation',
    folder: 'neostation',
    author: 'NeoStation Team',
    description: 'First and Official System Art Pack.',
    donationUrl: 'https://ko-fi.com/neostation',
    version: '1.0',
    previewUrl: '',
    backgrounds: [],
    downloads: 15,
    systemsCovered: 96,
    isAi: false,
  );

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(640, 480),
    builder: (_, _) => ChangeNotifierProvider(
      create: (_) => NeoAssetsProvider(),
      child: MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );

  testWidgets('the list tile shows name and author but no action buttons', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SystemArtPackTile(pack: pack)));
    await tester.pump();

    expect(find.text('NeoStation'), findsOneWidget);
    expect(find.textContaining('NeoStation Team'), findsOneWidget);
    // Description and the apply/support buttons live in the dialog now.
    expect(find.textContaining('First and Official'), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dialog shows the description and the gamepad controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => SystemArtPackDialog.show(context, pack),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('NeoStation'), findsWidgets);
    expect(find.text('First and Official System Art Pack.'), findsOneWidget);
    // Bottom gamepad controls: A apply, X support, B close.
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
