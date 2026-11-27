import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'model.dart';
import 'sub_screen_platform_interface.dart';

const _methodChannelName = 'com.hcoderlee.subscreen.sub_screen/methods';

class MethodChannelSubScreen extends SubScreenPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel(_methodChannelName);

  @override
  Future<List<Display>> getDisplays() async {
    final result = await methodChannel.invokeMethod('getDisplays');
    final displays = (result['displays'] as List)
        .map((json) => Display.fromMap(Map<String, dynamic>.from(json)))
        .toList();
    return displays;
  }

  @override
  void setOnMultiDisplayListener(OnMultiDisplayListener listener) {
    methodChannel.setMethodCallHandler(
      (call) => _handleMethodCall(call, listener),
    );
  }

  Future<void> _handleMethodCall(
    MethodCall call,
    OnMultiDisplayListener listener,
  ) async {
    switch (call.method) {
      case 'onDisplayAdded':
        final display = Display.fromMap(
          Map<String, dynamic>.from(call.arguments['display']),
        );
        listener.onDisplayAdded(display);
        break;

      case 'onDisplayRemoved':
        final displayId = call.arguments['displayId'] as int;
        listener.onDisplayRemoved(displayId);
        break;

      case 'onDisplayChanged':
        final display = Display.fromMap(
          (call.arguments['display'] as Map<String, dynamic>),
        );
        listener.onDisplayChanged(display);
        break;
    }
  }
}
