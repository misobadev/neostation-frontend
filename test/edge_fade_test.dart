import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/edge_fade.dart';

void main() {
  late ValueNotifier<int> rows;
  late ScrollController controller;

  setUp(() {
    rows = ValueNotifier(3);
    controller = ScrollController();
  });
  tearDown(() {
    rows.dispose();
    controller.dispose();
  });

  /// A 200px list of 50px rows: three fit, ten do not.
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 200,
            child: EdgeFade(
              extent: 8,
              child: ValueListenableBuilder<int>(
                valueListenable: rows,
                builder: (context, count, _) => ListView.builder(
                  controller: controller,
                  itemExtent: 50,
                  itemCount: count,
                  itemBuilder: (context, i) => Text('row $i'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> resize(WidgetTester tester, int count) async {
    rows.value = count;
    await tester.pumpAndSettle();
  }

  testWidgets('a list that fits is never masked', (tester) async {
    await pump(tester);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('the mask comes and goes without remounting the list', (
    tester,
  ) async {
    await pump(tester);
    final list = tester.state(find.byType(Scrollable));

    await resize(tester, 10);
    expect(find.byType(ShaderMask), findsOneWidget, reason: 'rows below');
    expect(tester.state(find.byType(Scrollable)), same(list));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsOneWidget, reason: 'rows above');
    expect(controller.offset, 300, reason: 'the scroll position survives');

    await resize(tester, 3);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.state(find.byType(Scrollable)), same(list));
    expect(tester.takeException(), isNull);
  });
}
