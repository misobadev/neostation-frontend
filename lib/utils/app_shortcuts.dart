import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The keyboard shortcuts the app's [WidgetsApp] uses, or null for Flutter's
/// defaults.
///
/// On desktop, `GamepadNavigation` reads the keyboard itself and moves its own
/// cursor. Flutter's focus system sees every key as well — whether or not a
/// keyboard handler already took it — and by default the arrow keys move
/// Flutter's focus onto whatever focusable widget lies that way. Enter then
/// activated *that* widget too, on top of the gamepad navigation's selection:
/// one press ran a menu row twice, and the second `Navigator.pop` closed the
/// screen beneath the menu.
///
/// So on desktop the arrow keys no longer move Flutter's focus; the gamepad
/// navigation owns them. Everything else stays as Flutter has it: Enter and
/// Space still activate a focused widget (dialogs that autofocus a button
/// rely on that), Tab still traverses, Escape still dismisses, Ctrl+arrows
/// still scroll, and text fields keep their own arrow-key shortcuts. Android
/// is left alone: its controller does not reach the focus system this way.
Map<ShortcutActivator, Intent>? appShortcuts() {
  if (kIsWeb) return null;
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      return Map.of(WidgetsApp.defaultShortcuts)
        ..removeWhere((_, intent) => intent is DirectionalFocusIntent);
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return null;
  }
}
