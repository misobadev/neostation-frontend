import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/footer_label_pill.dart';

void main() {
  const secondary = Color(0xFF2196F3);
  const onSecondary = Color(0xFFFFFFFF);
  const surface = Color(0xFF121212);
  const onSurface = Color(0xFFEEEEEE);

  testWidgets('the system label uses secondary; its count chip stays surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            theme: ThemeData.from(
              colorScheme: const ColorScheme.dark(
                secondary: secondary,
                onSecondary: onSecondary,
                surface: surface,
                onSurface: onSurface,
              ),
            ),
            home: const Scaffold(
              body: FooterLabelPill(
                label: 'Atari 2600',
                countText: '88 Games',
                backgroundColor: secondary,
                foregroundColor: onSecondary,
              ),
            ),
          ),
        ),
      ),
    );

    final labelText = tester.widget<Text>(find.text('Atari 2600'));
    expect(labelText.style?.color, onSecondary);

    final labelContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Atari 2600'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((labelContainer.decoration as BoxDecoration).color, secondary);

    final countText = tester.widget<Text>(find.text('88 Games'));
    expect(countText.style?.color, onSurface);

    final countContainer = tester.widget<Container>(
      find
          .ancestor(of: find.text('88 Games'), matching: find.byType(Container))
          .first,
    );
    expect((countContainer.decoration as BoxDecoration).color, surface);
  });
}
