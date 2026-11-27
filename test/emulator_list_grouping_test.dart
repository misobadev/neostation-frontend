import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/standalone_emulator_model.dart';
import 'package:neostation/widgets/system_emulator_settings_dialog/models/emulator_list_item.dart';

CoreEmulatorModel _core(String id, {bool installed = false}) =>
    CoreEmulatorModel(
      uniqueId: id,
      osId: 1,
      systemId: '1',
      name: id,
      isStandalone: false,
      isDefault: false,
      isretroAchievementsCompatible: false,
      isInstalled: installed,
    );

StandaloneEmulatorModel _standalone(String name, {String? userPath}) =>
    StandaloneEmulatorModel(
      osId: 1,
      systemId: '1',
      name: name,
      uniqueIdentifier: name,
      isStandalone: true,
      isDefault: false,
      isretroAchievementsCompatible: false,
      userPath: userPath,
    );

EmulatorGroupedCoreItem _retroArch(
  String name, {
  bool installed = false,
  bool configured = false,
}) => EmulatorGroupedCoreItem(
  groupName: name,
  cores: [_core(name, installed: installed)],
  isInstalled: installed,
  retroArchConfigured: configured,
);

String _label(EmulatorListItem item) => switch (item) {
  EmulatorHeaderItem(:final title) => '# $title',
  EmulatorGroupedCoreItem(:final groupName) => groupName,
  EmulatorStandaloneItem(:final standalone) => standalone.name,
  _ => '?',
};

void main() {
  group('groupEmulatorsByAvailability', () {
    test('Android: installed first, not installed after, order kept', () {
      final items = <EmulatorListItem>[
        _retroArch('RetroArch 64', installed: true),
        _retroArch('RetroArch 32'),
        EmulatorStandaloneItem(_standalone('Dolphin')),
        EmulatorStandaloneItem(_standalone('Flycast'), isInstalled: true),
        EmulatorStandaloneItem(_standalone('Redream'), isInstalled: true),
      ];

      final grouped = groupEmulatorsByAvailability(items, isAndroid: true);

      expect(grouped.map(_label), [
        '# ${AppLocale.installed}',
        'RetroArch 64',
        'Flycast',
        'Redream',
        '# ${AppLocale.notInstalled}',
        'RetroArch 32',
        'Dolphin',
      ]);
    });

    test('desktop: splits by configured path, not package install', () {
      final items = <EmulatorListItem>[
        // Installed flags are Android-only; desktop must ignore them.
        _retroArch('RetroArch', installed: true),
        EmulatorStandaloneItem(
          _standalone('PCSX2', userPath: '/usr/bin/pcsx2'),
        ),
        EmulatorStandaloneItem(_standalone('DuckStation'), isInstalled: true),
      ];

      final grouped = groupEmulatorsByAvailability(items, isAndroid: false);

      expect(grouped.map(_label), [
        '# ${AppLocale.configured}',
        'PCSX2',
        '# ${AppLocale.notConfigured}',
        'RetroArch',
        'DuckStation',
      ]);
    });

    test('an empty section gets no header', () {
      final grouped = groupEmulatorsByAvailability([
        _retroArch('RetroArch', installed: true),
      ], isAndroid: true);

      expect(grouped.map(_label), ['# ${AppLocale.installed}', 'RetroArch']);
      expect(groupEmulatorsByAvailability([], isAndroid: true), isEmpty);
    });

    test('regrouping an already grouped list does not duplicate headers', () {
      final once = groupEmulatorsByAvailability([
        _retroArch('RetroArch', installed: true),
        _retroArch('RetroArch 32'),
      ], isAndroid: true);

      expect(
        groupEmulatorsByAvailability(once, isAndroid: true).map(_label),
        once.map(_label),
      );
    });
  });
}
