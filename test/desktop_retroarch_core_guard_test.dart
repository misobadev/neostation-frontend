import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/game_launch_service.dart';

/// The desktop pre-launch core guard must only abort on evidence it can trust.
///
/// 0.16.0 probed a guessed cores directory and aborted any core it did not
/// find there. RetroArch resolves relative `-L` names from its own
/// `libretro_directory` (which the frontend cannot read), so working Linux
/// installs failed before RetroArch ever started.
void main() {
  test('a relative core name is left for RetroArch to resolve', () {
    expect(
      GameLaunchService.desktopCoreIsPositivelyMissing(
        coreArg: 'snes9x_libretro.so',
        coreFileExists: false,
      ),
      isFalse,
    );
  });

  test('an absolute core path that does not exist aborts', () {
    expect(
      GameLaunchService.desktopCoreIsPositivelyMissing(
        coreArg: '/home/deck/.config/retroarch/cores/snes9x_libretro.so',
        coreFileExists: false,
      ),
      isTrue,
    );
  });

  test('an absolute core path that exists does not abort', () {
    expect(
      GameLaunchService.desktopCoreIsPositivelyMissing(
        coreArg: '/usr/lib/libretro/snes9x_libretro.so',
        coreFileExists: true,
      ),
      isFalse,
    );
  });

  test('an empty core argument does not abort', () {
    expect(
      GameLaunchService.desktopCoreIsPositivelyMissing(
        coreArg: '',
        coreFileExists: false,
      ),
      isFalse,
    );
  });
}
