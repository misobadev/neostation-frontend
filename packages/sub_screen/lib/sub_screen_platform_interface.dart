import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'model.dart';
import 'sub_screen_method_channel.dart';

abstract class SubScreenPlatform extends PlatformInterface {
  /// Constructs a SubScreenPlatform.
  SubScreenPlatform() : super(token: _token);

  static final Object _token = Object();

  static SubScreenPlatform _instance = MethodChannelSubScreen();

  /// The default instance of [SubScreenPlatform] to use.
  ///
  /// Defaults to [MethodChannelSubScreen].
  static SubScreenPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [SubScreenPlatform] when
  /// they register themselves.
  static set instance(SubScreenPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<List<Display>> getDisplays() {
    throw UnimplementedError('getDisplays() has not been implemented.');
  }

  void setOnMultiDisplayListener(OnMultiDisplayListener listener) {
    throw UnimplementedError(
      'setOnMultiDisplayListener() has not been implemented.',
    );
  }
}
