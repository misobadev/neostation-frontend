import 'package:neostation/utils/android_shortcut_id.dart';
import 'package:test/test.dart';

const _action = 'android.intent.action.VIEW';
const _component = 'com.droiddeck.launcher/.FrontEndActivity';
const _package = 'com.droiddeck.launcher';

void main() {
  group('AndroidShortcutId', () {
    test('is stable for the same intent', () {
      expect(
        AndroidShortcutId.of(
          packageName: _package,
          shortcutId: 'game:1',
          action: _action,
          component: _component,
          data: 'droiddeck://game/1',
        ),
        AndroidShortcutId.of(
          packageName: _package,
          shortcutId: 'game:1',
          action: _action,
          component: _component,
          data: 'droiddeck://game/1',
        ),
      );
    });

    test('separates two shortcut ids on the same launcher', () {
      expect(
        AndroidShortcutId.of(packageName: _package, shortcutId: 'game:1'),
        isNot(
          AndroidShortcutId.of(packageName: _package, shortcutId: 'game:2'),
        ),
      );
    });

    test('separates two games on the same launcher', () {
      expect(
        AndroidShortcutId.of(
          packageName: _package,
          shortcutId: 'game:1',
          action: _action,
          component: _component,
          data: 'droiddeck://game/1',
        ),
        isNot(
          AndroidShortcutId.of(
            action: _action,
            packageName: _package,
            component: _component,
            data: 'droiddeck://game/2',
          ),
        ),
      );
    });

    test('keeps the fields from bleeding into each other', () {
      expect(
        AndroidShortcutId.of(packageName: 'ab', action: 'c'),
        isNot(AndroidShortcutId.of(packageName: 'a', action: 'bc')),
      );
    });

    test('produces a file-name-safe id', () {
      final id = AndroidShortcutId.of(packageName: _package, shortcutId: 'g:1');

      expect(id, startsWith(AndroidShortcutId.prefix));
      expect(RegExp(r'^[a-z0-9-]+$').hasMatch(id), isTrue);
      expect(id.contains(':'), isFalse);
    });

    test('recognises only its own ids', () {
      expect(AndroidShortcutId.isShortcut('shortcut-0123456789abcdef'), isTrue);
      expect(AndroidShortcutId.isShortcut('com.tencent.ig'), isFalse);
      expect(AndroidShortcutId.isShortcut(null), isFalse);
    });
  });
}
