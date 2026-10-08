import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/smart_collection_rules.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/screens/collections_screen/smart_collection_editor.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LibraryProvider extends CollectionsProvider {
  @override
  Future<List<DatabaseGameModel>> ruleLibrary() async => [
    DatabaseGameModel(
      filename: 'Chrono.sfc',
      romPath: '/snes/Chrono.sfc',
      realName: 'Chrono Trigger',
      systemFolderName: 'snes',
      systemRealName: 'Super Nintendo',
      genre: 'RPG',
    ),
    DatabaseGameModel(
      filename: 'Mario.nes',
      romPath: '/nes/Mario.nes',
      realName: 'Super Mario Bros.',
      systemFolderName: 'nes',
      systemRealName: 'Nintendo Entertainment System',
    ),
  ];
}

class _ArtworkProvider extends FileProvider {
  _ArtworkProvider(this.artworkPath);
  final String artworkPath;

  @override
  bool get isInitialized => true;

  @override
  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) => artworkPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory artworkDirectory;
  late String artworkPath;
  setUpAll(() async {
    artworkDirectory = await Directory.systemTemp.createTemp(
      'smart-editor-art',
    );
    artworkPath = '${artworkDirectory.path}/cover.png';
    final bytes = await rootBundle.load('assets/images/icons/image-bulk.png');
    await File(artworkPath).writeAsBytes(bytes.buffer.asUint8List());
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
    SfxService().setEnabled(false);
    const fontPath = String.fromEnvironment('SMART_COLLECTION_FONT');
    if (fontPath.isNotEmpty) {
      final loader = FontLoader('Roboto');
      loader.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final icons = FontLoader(
        'packages/material_symbols_icons/MaterialSymbolsRounded',
      );
      icons.addFont(
        rootBundle.load(
          'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
        ),
      );
      await icons.load();
    }
  });
  tearDownAll(() async => artworkDirectory.delete(recursive: true));

  final rules = SmartCollectionRules(
    rules: [
      SmartRule(
        field: SmartField.system,
        operator: SmartOperator.isEqual,
        value: ['snes'],
      ),
      SmartRule(
        field: SmartField.played,
        operator: SmartOperator.isEqual,
        value: false,
      ),
    ],
  );
  final collection = CollectionModel(
    id: 'smart',
    name: 'Unplayed SNES',
    isSmart: true,
    rules: rules,
  );

  Future<BuildContext> host(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late BuildContext ctx;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CollectionsProvider>(
            create: (_) => _LibraryProvider(),
          ),
          ChangeNotifierProvider<FileProvider>(
            create: (_) => _ArtworkProvider(artworkPath),
          ),
        ],
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            theme: ThemeData.dark(),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Builder(
              builder: (context) {
                ctx = context;
                return const Scaffold(body: SizedBox.shrink());
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        ResizeImage(FileImage(File(artworkPath)), width: (112.r).round()),
        ctx,
      ),
    );
    return ctx;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('SMART_COLLECTION_CAPTURE')) return;
    await tester.runAsync(() async {
      final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary),
      );
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(
        '/tmp/smart-collection-$name.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [const Size(1280, 720), const Size(800, 450)]) {
    testWidgets('editor previews and saves rules at ${size.width}', (
      tester,
    ) async {
      final ctx = await host(tester, size);
      final depth = GamepadNavigationManager.stackDepth;
      final result = SmartCollectionEditor.show(
        ctx,
        collection: collection,
        initialName: collection.name,
      );
      await tester.pumpAndSettle();
      expect(GamepadNavigationManager.stackDepth, depth + 1);
      expect(find.text('1 matching game'), findsOneWidget);
      await capture(tester, '${size.width.toInt()}');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(find.text('Chrono Trigger'), findsOneWidget);
      final preview = find.byKey(const ValueKey('preview:/snes/Chrono.sfc'));
      expect(
        find.descendant(of: preview, matching: find.byType(Image)),
        findsOneWidget,
      );
      final artwork = tester.widget<Image>(
        find.descendant(of: preview, matching: find.byType(Image)),
      );
      expect((artwork.image as ResizeImage).imageProvider, isA<FileImage>());
      expect(
        tester.getTopLeft(preview).dx,
        lessThan(tester.getTopLeft(find.text('Save')).dx),
      );
      expect(
        tester.getTopLeft(preview).dy,
        greaterThan(tester.getBottomLeft(find.text('Add rule')).dy),
      );
      expect(tester.takeException(), isNull);
      await capture(tester, '${size.width.toInt()}-games');
      await tester.ensureVisible(find.text('Match all rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Match all rules'));
      await tester.pumpAndSettle();
      expect(find.text('2 matching games'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final draft = await result;
      expect(draft!.name, collection.name);
      expect(draft.rules.matchAll, isFalse);
      expect(draft.rules.rules.length, 2);
      expect(GamepadNavigationManager.stackDepth, depth);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'direction keys reach rule controls and cancel returns input to the host',
    (tester) async {
      final ctx = await host(tester, const Size(1280, 720));
      final depth = GamepadNavigationManager.stackDepth;
      final result = SmartCollectionEditor.show(
        ctx,
        collection: collection,
        initialName: collection.name,
      );
      await tester.pumpAndSettle();
      // The navigation translator deliberately ignores input just after activation.
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await key(LogicalKeyboardKey.arrowDown);
      await key(LogicalKeyboardKey.enter);
      expect(find.text('Match any rule'), findsOneWidget);
      expect(find.text('2 matching games'), findsOneWidget);
      await key(LogicalKeyboardKey.arrowDown);
      await key(LogicalKeyboardKey.enter);
      expect(find.text('Genre'), findsOneWidget);
      expect(GamepadNavigationManager.stackDepth, depth + 2);
      await key(LogicalKeyboardKey.backspace);
      expect(GamepadNavigationManager.stackDepth, depth + 1);
      bool selected(String label) {
        final button = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(OutlinedButton),
          ),
        );
        return button.style!.backgroundColor!.resolve({}) != null;
      }

      expect(selected('System'), isTrue);
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.arrowRight);
      expect(selected('Super Nintendo'), isTrue);
      await key(LogicalKeyboardKey.arrowDown);
      expect(selected('No'), isTrue);
      await key(LogicalKeyboardKey.arrowUp);
      expect(selected('Super Nintendo'), isTrue);
      await key(LogicalKeyboardKey.arrowLeft);
      await key(LogicalKeyboardKey.arrowLeft);
      expect(selected('System'), isTrue);
      await key(LogicalKeyboardKey.arrowLeft);
      expect(selected('System'), isTrue);
      await key(LogicalKeyboardKey.arrowDown);
      expect(selected('Played'), isTrue);
      await key(LogicalKeyboardKey.arrowDown);
      expect(selected('Add rule'), isTrue);
      await key(LogicalKeyboardKey.arrowDown);
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const ValueKey('preview:/snes/Chrono.sfc')),
                    )
                    .decoration!
                as BoxDecoration)
            .border,
        isNotNull,
      );
      await key(LogicalKeyboardKey.arrowRight);
      expect(selected('Save'), isTrue);
      await key(LogicalKeyboardKey.arrowUp);
      await key(LogicalKeyboardKey.arrowLeft);
      expect(selected('Cancel'), isTrue);
      await key(LogicalKeyboardKey.arrowUp);
      await key(LogicalKeyboardKey.arrowDown);
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const ValueKey('preview:/nes/Mario.nes')),
                    )
                    .decoration!
                as BoxDecoration)
            .border,
        isNotNull,
      );
      await key(LogicalKeyboardKey.arrowDown);
      expect(selected('Cancel'), isTrue);
      await key(LogicalKeyboardKey.arrowRight);
      expect(selected('Save'), isTrue);
      await key(LogicalKeyboardKey.backspace);
      expect(await result, isNull);
      expect(GamepadNavigationManager.stackDepth, depth);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty rule draft cannot save; system picker supports multiple selections',
    (tester) async {
      final ctx = await host(tester, const Size(1280, 720));
      final result = SmartCollectionEditor.show(ctx, initialName: 'New smart');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid value for this rule.'), findsOneWidget);
      await tester.tap(find.text('Choose a value'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Super Nintendo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nintendo Entertainment System'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('2 matching games'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final draft = await result;
      expect(draft!.rules.rules.single.value, containsAll(['snes', 'nes']));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('B keeps selected systems without scrolling to Done', (
    tester,
  ) async {
    final ctx = await host(tester, const Size(1280, 720));
    final result = SmartCollectionEditor.show(ctx, initialName: 'New smart');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a value'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Super Nintendo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nintendo Entertainment System'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(find.text('2 matching games'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final draft = await result;
    expect(draft!.rules.rules.single.value, containsAll(['snes', 'nes']));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unsupported rules are explained and cancelling preserves the source',
    (tester) async {
      final ctx = await host(tester, const Size(1280, 720));
      final invalid = CollectionModel.fromJson({
        'id': 'bad',
        'name': 'Invalid',
        'collection_type': 'smart',
        'rules_json': '{"version":2}',
      });
      final result = SmartCollectionEditor.show(
        ctx,
        collection: invalid,
        initialName: invalid.name,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'These rules cannot be read. Edit them to restore this collection.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(invalid.rulesInvalid, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
