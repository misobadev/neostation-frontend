import 'dart:io';

import 'package:test/test.dart';

// The kept copies of saves are reached from the game's Manage tab (either
// save provider) and from the NeoSync dashboard. Both open the same view,
// which drives the gamepad through its own navigation layer.

String method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature not found');
  final end = source.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: '$signature has no end');
  return source.substring(start, end);
}

void main() {
  final manageTab = File(
    'lib/screens/game_screen/game_settings_dialog/game_settings_manage_tab.dart',
  ).readAsStringSync();
  final dashboard = File(
    'lib/screens/neo_sync_screen/login_screen/neo_sync_content.dart',
  ).readAsStringSync();
  final view = File('lib/screens/saves_screen/kept_copies_view.dart')
      .readAsStringSync();

  test('the Manage tab opens the game\'s copies with A', () {
    final trigger = method(manageTab, 'void trigger() {');
    expect(
      trigger,
      matches(
        RegExp(
          r'idx == _keptCopiesIdx\) \{\s*if \(_hasKeptCopies\) _openKeptCopies\(\);',
        ),
      ),
    );
    expect(
      method(manageTab, 'Future<void> _openKeptCopies('),
      contains('KeptCopiesView.showForGame(context, _gameWithSystem)'),
    );
  });

  test('as a dashboard section, L1/R1 switch the app\'s tabs; in a dialog '
      'they don\'t', () {
    expect(
      view,
      contains(
        'onPreviousTab: widget.inDialog ? null : AppNavigation.previousTab',
      ),
    );
    expect(
      view,
      contains('onNextTab: widget.inDialog ? null : AppNavigation.nextTab'),
    );
  });

  test('the Manage tab row is skipped by the D-pad while there are none', () {
    expect(
      method(manageTab, 'bool _isEnabledIndex('),
      contains('if (idx == _keptCopiesIdx && !_hasKeptCopies) return false;'),
    );
  });

  test('the Manage tab rows keep their order: cloud sync, kept copies, '
      'play time', () {
    int index(String getter) => int.parse(
      RegExp('int get $getter => (\\d+);').firstMatch(manageTab)!.group(1)!,
    );
    expect(index('_cloudSyncIdx'), 0);
    expect(index('_keptCopiesIdx'), 1);
    expect(index('_playTimeIdx'), 2);
    final cloud = manageTab.indexOf('key: _itemKey(_cloudSyncIdx)');
    final kept = manageTab.indexOf('key: _itemKey(_keptCopiesIdx)');
    final playTime = manageTab.indexOf('key: _itemKey(_playTimeIdx)');
    expect(cloud, lessThan(kept));
    expect(kept, lessThan(playTime));
  });

  test('the NeoSync dashboard has a kept copies section after the save '
      'list', () {
    final sections = RegExp(r'_menuSections = \[([^\]]*)\]')
        .firstMatch(dashboard)!
        .group(1)!;
    expect(
      sections.replaceAll(RegExp(r'\s'), ''),
      'NeoSyncSection.saveList,NeoSyncSection.keptCopies,'
      'NeoSyncSection.customFolders,NeoSyncSection.plans,',
    );
    final entries = method(dashboard, 'Widget _buildMenuList() {');
    final saveList = entries.indexOf('AppLocale.saveListMenu');
    final kept = entries.indexOf('AppLocale.keptCopiesTitle');
    final folders = entries.indexOf('AppLocale.customSaveFoldersMenu');
    expect(saveList, lessThan(kept));
    expect(kept, lessThan(folders));
    expect(
      dashboard,
      matches(
        RegExp(r'case NeoSyncSection\.keptCopies:\s*return KeptCopiesView\('),
      ),
    );
  });

  test('the view registers its own gamepad layer and removes it', () {
    final init = method(view, 'void initState() {');
    expect(init, contains('addPostFrameCallback'));
    expect(init, contains('GamepadNavigationManager.pushLayer('));
    expect(
      method(view, 'void dispose() {'),
      contains('GamepadNavigationManager.popLayer(_layerId);'),
    );
  });

  test('the view maps A to restore, X to delete and B to back', () {
    final init = method(view, 'void initState() {');
    expect(init, contains('onSelectItem: _restore,'));
    expect(init, contains('onXButton: _delete,'));
    expect(init, contains('onBack: _back,'));
  });
}
