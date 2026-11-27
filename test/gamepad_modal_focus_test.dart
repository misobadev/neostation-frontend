import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';

void main() {
  test('restoreFocusOwner leaves an open modal in front', () {
    var gridActive = false;
    var dialogActive = false;

    GamepadNavigationManager.pushLayer(
      'test_grid',
      onActivate: () => gridActive = true,
      onDeactivate: () => gridActive = false,
    );
    GamepadNavigationManager.rememberFocusOwner('test_grid');
    GamepadNavigationManager.pushLayer(
      'test_dialog',
      onActivate: () => dialogActive = true,
      onDeactivate: () => dialogActive = false,
      modal: true,
    );

    expect(gridActive, isFalse);
    expect(dialogActive, isTrue);

    // This is the launch-failure path: the launch dialog's dispose calls
    // restoreFocusOwner while the error dialog is already on screen.
    GamepadNavigationManager.restoreFocusOwner();

    expect(
      gridActive,
      isFalse,
      reason: 'the grid must not take input from the open error dialog',
    );
    expect(dialogActive, isTrue);

    GamepadNavigationManager.popLayer('test_dialog');
    expect(gridActive, isTrue);

    GamepadNavigationManager.popLayer('test_grid');
  });
}
