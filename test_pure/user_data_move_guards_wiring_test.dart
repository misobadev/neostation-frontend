import 'dart:io';

import 'package:test/test.dart';

// NEO-236: while the user data moves, an action that writes the library or
// the user-data folder has to wait, or what it writes is lost with the old
// folder. These start from screens and services that need the database,
// platform plugins or a running emulator, so the wiring is checked in the
// source: each refuses before it does anything.
void main() {
  const guard = 'if (refuseWhileUserDataMoves())';

  String body(String file, String signature) {
    final source = File(file).readAsStringSync();
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found in $file');
    // A method ends at the class member indent, a top-level function at the
    // margin.
    final indent = start - source.lastIndexOf('\n', start) - 1;
    final end = source.indexOf('\n${' ' * indent}}\n', start);
    return source.substring(start, end == -1 ? source.length : end);
  }

  void refusesBefore(String file, String signature, String firstStep) {
    final text = body(file, signature);
    final at = text.indexOf(guard);
    expect(at, isNot(-1), reason: '$signature has no guard');
    final step = text.indexOf(firstStep);
    expect(step, isNot(-1), reason: '$firstStep not in $signature');
    expect(at, lessThan(step), reason: '$signature acts before its guard');
  }

  const scanning = 'lib/providers/sqlite_config_provider/scanning.dart';
  test('scans', () {
    refusesBefore(scanning, 'Future<void> scanSystems(', '_isScanning');
    refusesBefore(scanning, 'Future<void> rescanSystem(', '_scanStarted()');
    refusesBefore(
      scanning,
      'Future<ScanSummary> rescanSystemSilent(',
      '_config.romFolders',
    );
  });

  // Each launcher tears its own screen down (input off, list freed) before
  // it hands over, so it refuses before that, not inside the shared launch.
  test('game launches', () {
    refusesBefore(
      'lib/screens/game_screen/my_games_list/launch_flow.dart',
      'Future<void> _selectCurrentGame(',
      '_isGameLaunching = true',
    );
    refusesBefore(
      'lib/screens/search_screen/search_screen.dart',
      'Future<void> _launch(',
      '_gamepadNav.deactivate()',
    );
    refusesBefore(
      'lib/screens/systems_screen/my_systems_section/my_systems_carousel.dart',
      'Future<void> _navigateToSystemInternal(',
      '_isGameLaunching = true',
    );
    refusesBefore(
      'lib/screens/systems_screen/my_systems_section/my_systems_grid.dart',
      'void _navigateToSystem(',
      'gridLaunchNotifier.value = true',
    );
    expect(
      body(
        'lib/utils/game_launch_utils.dart',
        'Future<void> launchGameWithDialog(',
      ),
      isNot(contains(guard)),
      reason: 'refused after the caller had torn its screen down',
    );
  });

  test('single-game scrapes', () {
    refusesBefore(
      'lib/screens/game_screen/my_games_list.dart',
      'Future<void> _scrapeSelectedGame(',
      'hasSavedCredentials()',
    );
    refusesBefore(
      'lib/screens/game_screen/game_settings_dialog/'
          'game_settings_scrapping_tab.dart',
      'Future<void> _forceRescrape(',
      '_isScraping = true',
    );
    refusesBefore(
      'lib/screens/game_screen/game_details_card/game_details_card_list.dart',
      'Future<void> _startSingleGameScrape(',
      'videoController',
    );
  });

  // A refused silent scan returns an empty summary, which the dialog would
  // report as "no changes found".
  test("the system settings' rescan", () {
    final file = File('lib/widgets/system_emulator_settings_dialog.dart')
        .readAsStringSync();
    final at = file.indexOf(guard);
    expect(at, isNot(-1));
    expect(at, lessThan(file.indexOf('.rescanSystemSilent(')));
  });

  // A download finished during a move is indexed after it, not dropped.
  test("RomM's post-download scan waits for the move", () {
    final text = body(
      'lib/providers/romm_provider.dart',
      'Future<void> _runSettle(',
    );
    final moving = text.indexOf('UserDataLocationService.isMoving');
    expect(moving, isNot(-1));
    expect(moving, lessThan(text.indexOf('clearDownloadedSystems()')));
  });

  test('ScreenScraper sessions', () {
    refusesBefore(
      'lib/screens/settings_screen/new_settings_options/screenscraper/'
          'scrape_session.dart',
      'Future<void> startScrapeSession(',
      'startScraping(',
    );
  });

  test('library tools', () {
    const tools =
        'lib/screens/settings_screen/new_settings_options/'
        'tools_settings_content.dart';
    for (final tool in [
      'Future<void> _linkRommLibrary(',
      'Future<void> _organizeMultiDiscGames(',
      'Future<void> _cleanOrphanedMetadata(',
      'Future<void> _rematchAchievements(',
    ]) {
      final text = body(tools, tool);
      expect(
        text.indexOf(guard),
        allOf(isNot(-1), lessThan(text.indexOf('await'))),
        reason: '$tool waits for its guard',
      );
    }
  });

  test('art-pack downloads and theme imports', () {
    refusesBefore(
      'lib/widgets/system_art_pack_dialog.dart',
      'Future<void> _apply(',
      'setState(',
    );
    refusesBefore(
      'lib/screens/settings_screen/new_settings_options/'
          'themes_settings_content.dart',
      'Future<void> _importTheme(',
      'Picker',
    );
  });

  // NEO-236: the log kept writing to the old folder's app.log, which the
  // move deletes, so the end of every move, and any failure in it, was lost.
  test("the move's log goes on in the new folder", () {
    final text = File('lib/services/user_data_location_service.dart')
        .readAsStringSync();
    final switched = text.indexOf('await setCustomPath(destPath);');
    final reopened = text.indexOf('LoggerService.instance.reinitialize()');
    final deleting = text.indexOf('// ---- Delete phase');
    expect(switched, isNot(-1));
    expect(reopened, greaterThan(switched));
    expect(reopened, lessThan(deleting));
  });
}
