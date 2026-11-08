import 'model.dart';
import 'sub_screen_platform_interface.dart';

class SubScreenPlugin {
  static Future<List<Display>> getDisplays() {
    return SubScreenPlatform.instance.getDisplays();
  }

  static void setOnMultiDisplayListener(OnMultiDisplayListener listener) {
    SubScreenPlatform.instance.setOnMultiDisplayListener(listener);
  }
}
