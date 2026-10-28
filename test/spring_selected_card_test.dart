import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/spring_selected_card.dart';

void main() {
  testWidgets('selected card springs up and settles when deselected', (
    tester,
  ) async {
    Widget host(bool selected) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: SpringSelectedCard(
              selected: selected,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);

    await tester.pumpWidget(host(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_scale(tester), closeTo(1.04, 0.001));

    await tester.pumpWidget(host(false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_scale(tester), closeTo(1.0, 0.001));
  });
}

double _scale(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.descendant(
      of: find.byType(SpringSelectedCard),
      matching: find.byType(Transform),
    ),
  );
  return transform.transform.storage[0];
}
