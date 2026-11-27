import 'package:neostation/l10n/app_locale.dart';

import '../../../models/core_emulator_model.dart';
import '../../../models/standalone_emulator_model.dart';

// Helper classes for grouped display
abstract class EmulatorListItem {}

class EmulatorHeaderItem extends EmulatorListItem {
  final String title;
  final bool isInstalled;
  final String? packageName;

  EmulatorHeaderItem({
    required this.title,
    this.isInstalled = false,
    this.packageName,
  });
}

class EmulatorCoreItem extends EmulatorListItem {
  final CoreEmulatorModel core;
  final bool retroArchConfigured;
  final String? retroArchPath;

  EmulatorCoreItem(
    this.core, {
    this.retroArchConfigured = false,
    this.retroArchPath,
  });
}

class EmulatorStandaloneItem extends EmulatorListItem {
  final StandaloneEmulatorModel standalone;
  final bool isInstalled;

  EmulatorStandaloneItem(this.standalone, {this.isInstalled = false});
}

class EmulatorGroupedCoreItem extends EmulatorListItem {
  final String groupName;
  final String? packageName;
  final List<CoreEmulatorModel> cores;
  final bool isInstalled;
  final bool retroArchConfigured;
  final String? retroArchPath;

  EmulatorGroupedCoreItem({
    required this.groupName,
    this.packageName,
    required this.cores,
    this.isInstalled = false,
    this.retroArchConfigured = false,
    this.retroArchPath,
  });
}

/// Whether [item] can be used right now: installed on Android, configured on
/// desktop. Mirrors the enabled/disabled state the rows draw.
bool isEmulatorItemAvailable(EmulatorListItem item, {required bool isAndroid}) {
  if (item is EmulatorGroupedCoreItem) {
    return isAndroid ? item.isInstalled : item.retroArchConfigured;
  }
  if (item is EmulatorStandaloneItem) {
    return isAndroid ? item.isInstalled : item.standalone.isConfigured;
  }
  if (item is EmulatorCoreItem) {
    return isAndroid ? item.core.isInstalled : item.retroArchConfigured;
  }
  return false;
}

/// Splits [items] into an available section followed by an unavailable one,
/// each under an [EmulatorHeaderItem]. Order inside a section is preserved
/// and an empty section gets no header.
///
/// The header's [EmulatorHeaderItem.title] is an `AppLocale` key: the
/// installed/not-installed pair on Android, configured/not-configured on
/// desktop, matching the status badge on each row.
List<EmulatorListItem> groupEmulatorsByAvailability(
  List<EmulatorListItem> items, {
  required bool isAndroid,
}) {
  final available = <EmulatorListItem>[];
  final unavailable = <EmulatorListItem>[];
  for (final item in items) {
    if (item is EmulatorHeaderItem) continue;
    (isEmulatorItemAvailable(item, isAndroid: isAndroid)
            ? available
            : unavailable)
        .add(item);
  }

  return [
    if (available.isNotEmpty) ...[
      EmulatorHeaderItem(
        title: isAndroid ? AppLocale.installed : AppLocale.configured,
        isInstalled: true,
      ),
      ...available,
    ],
    if (unavailable.isNotEmpty) ...[
      EmulatorHeaderItem(
        title: isAndroid ? AppLocale.notInstalled : AppLocale.notConfigured,
      ),
      ...unavailable,
    ],
  ];
}
