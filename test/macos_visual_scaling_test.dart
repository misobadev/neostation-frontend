import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/widgets/achievements_badge.dart';
import 'package:neostation/widgets/collection_badge.dart';

void main() {
  for (final size in [
    const Size(640, 480),
    const Size(1920, 1080),
    const Size(3840, 2160),
  ]) {
    testWidgets('inline badges match the resolved row font at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late double rowFontSize;
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (_, _) {
            rowFontSize = 11.r;
            return MaterialApp(
              home: Scaffold(
                body: Row(
                  children: [
                    CollectionBadge.inline(
                      color: Colors.orange,
                      inlineSize: rowFontSize,
                    ),
                    Text('Crash', style: TextStyle(fontSize: rowFontSize)),
                    AchievementsBadge.inline(
                      game: const GameModel(
                        romname: 'crash.chd',
                        realname: 'Crash',
                        name: 'Crash',
                        year: '',
                        developer: '',
                        publisher: '',
                        genre: '',
                        players: '',
                        rating: 0,
                        idRa: 1,
                        raNumAchievements: 80,
                      ),
                      color: Colors.orange,
                      inlineSize: rowFontSize,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Symbols.bookmark_rounded)).size,
        rowFontSize,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Symbols.emoji_events_rounded)).size,
        rowFontSize,
      );
    });
  }
}
