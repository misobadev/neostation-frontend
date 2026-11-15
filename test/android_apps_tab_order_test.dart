import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/nav_tabs.dart';

void main() {
  test('places Android Apps after Systems when Discovery is hidden', () {
    final tabs = List<NavTab>.of([
      NavTab.systems,
      NavTab.sync,
      NavTab.settings,
      NavTab.androidApps,
    ], growable: false);

    expect(
      orderNavTabs(tabs),
      equals([
        NavTab.systems,
        NavTab.androidApps,
        NavTab.sync,
        NavTab.settings,
      ]),
    );
  });

  test('places Android Apps after Discovery, keeping Discovery second', () {
    final tabs = List<NavTab>.of([
      NavTab.systems,
      NavTab.discovery,
      NavTab.sync,
      NavTab.settings,
      NavTab.androidApps,
    ], growable: false);

    expect(
      orderNavTabs(tabs),
      equals([
        NavTab.systems,
        NavTab.discovery,
        NavTab.androidApps,
        NavTab.sync,
        NavTab.settings,
      ]),
    );
  });
}
