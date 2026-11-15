import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/secondary_apps_service.dart';

/// Covers the bottom screen's power signal — the one that decides whether a
/// game's preview video is allowed to play.
///
/// The secondary display runs in its own Flutter engine that never receives
/// Android lifecycle callbacks, so "is the device awake" has to be told to it.
/// It used to be told only through the cross-engine shared state, which ships
/// whole snapshots with no ordering guarantee: a snapshot built moments before
/// the screen went off could land after the screen-off write and flip the flag
/// back to `true`, restarting the trailer — audio and all — under a closed lid,
/// with nothing to correct it until the next real screen event.
///
/// These calls travel on the secondary engine's own channel instead: ordered
/// edges that can't be clobbered, plus a live read of the display itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.neogamelab.neostation/secondary_apps');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Delivers a native→Dart call the way the presentation does.
  Future<void> pushFromNative(String method) {
    return messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  bool? displayOnAnswer;

  setUp(() {
    displayOnAnswer = true;
    SecondaryAppsService.deviceScreenOn.value = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isDisplayOn') return displayOnAnswer;
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('seeds itself from the display when the listener is wired', () async {
    displayOnAnswer = false;
    SecondaryAppsService.listenForScreenState();
    // An engine that started while the device was already asleep must not sit
    // on the optimistic `true` default waiting for an edge that never comes.
    await pumpEventQueue();
    expect(SecondaryAppsService.deviceScreenOn.value, isFalse);
  });

  test('native edges drive the notifier', () async {
    await pushFromNative('onDeviceScreenOn');
    expect(SecondaryAppsService.deviceScreenOn.value, isTrue);

    await pushFromNative('onDeviceScreenOff');
    expect(SecondaryAppsService.deviceScreenOn.value, isFalse);

    await pushFromNative('onDeviceScreenOn');
    expect(SecondaryAppsService.deviceScreenOn.value, isTrue);
  });

  test('isDisplayOn reports what the display says', () async {
    displayOnAnswer = false;
    expect(await SecondaryAppsService.isDisplayOn(), isFalse);

    displayOnAnswer = true;
    expect(await SecondaryAppsService.isDisplayOn(), isTrue);
  });

  test('isDisplayOn fails open when the channel cannot answer', () async {
    // A display we can't read must never disable the preview on a device that
    // is plainly awake — the pushed flags still gate playback in that case.
    displayOnAnswer = null;
    expect(await SecondaryAppsService.isDisplayOn(), isTrue);

    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'ERROR');
    });
    expect(await SecondaryAppsService.isDisplayOn(), isTrue);

    messenger.setMockMethodCallHandler(channel, null);
    expect(await SecondaryAppsService.isDisplayOn(), isTrue);
  });
}
