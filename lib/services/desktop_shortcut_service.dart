import '../repositories/desktop_shortcut_repository.dart';

class DesktopShortcutService {
  static Future<void> launch(String filename) =>
      DesktopShortcutRepository.launch(filename);
}
