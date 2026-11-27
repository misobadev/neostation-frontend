import 'package:flutter/material.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// Builds a button hint around the glyph for the active controller's West face
/// button.
///
/// The glyphs are Xbox ones, so West is drawn as X — except on controllers
/// that report West as Y (see [GamepadEventTranslator.isWestReportedAsY]),
/// where Y is also the label printed on that button.
class WestButtonGlyph extends StatelessWidget {
  final Widget Function(BuildContext context, String iconPath) builder;

  const WestButtonGlyph({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GamepadInputType>(
      valueListenable: GamepadNavigation.activeWestButton,
      builder: (context, west, _) => builder(
        context,
        west == GamepadInputType.buttonY
            ? 'assets/images/gamepad/Xbox_Y_button.png'
            : 'assets/images/gamepad/Xbox_X_button.png',
      ),
    );
  }
}
