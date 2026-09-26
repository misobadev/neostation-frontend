import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/nav_tabs.dart';

void main() {
  test('places Android Apps after Systems from a fixed-length tab list', () {
    final tabs = List<NavTab>.of([
      NavTab.systems,
      NavTab.search,
      NavTab.settings,
      NavTab.androidApps,
    ], growable: false);

    expect(
      orderNavTabs(tabs),
      equals([
        NavTab.systems,
        NavTab.androidApps,
        NavTab.search,
        NavTab.settings,
      ]),
    );
  });
}
