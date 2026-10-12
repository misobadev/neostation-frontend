import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/widgets/romm_upload_notification_listener.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'romm_save_inventory_fakes.dart' show InventorySync;

class _Romm extends InventorySync
    with ChangeNotifier
    implements RomMSyncProvider {
  _Romm() : super(RomMSyncProvider.kProviderId);

  @override
  final ValueNotifier<RommUploadFailures> uploadFailures = ValueNotifier(
    RommUploadFailures.none,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = SyncManager.instance;
  final notifications = GlobalNotificationService();
  late _Romm romm;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() {
    notifications.notifier.value = [];
    romm = _Romm();
    manager.register(romm);
  });

  tearDown(() {
    manager.unregister(RomMSyncProvider.kProviderId);
    romm.uploadFailures.dispose();
    romm.dispose();
    notifications.notifier.value = [];
  });

  /// Settled, as the app's localizations load before anything builds.
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: ChangeNotifierProvider<SyncManager>.value(
          value: manager,
          child: const RommUploadNotificationListener(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String failedFor(String games) => AppLocale
      .en[AppLocale.rommUploadsFailedFor]!
      .replaceFirst('{games}', games);

  List<String> shown() => [for (final n in notifications.notifier.value) n.id];

  testWidgets('names up to four games, else three and the rest', (
    tester,
  ) async {
    await pump(tester);

    romm.uploadFailures.value = const RommUploadFailures(['Alpha', 'Beta']);
    expect(
      notifications.notifier.value.single.message,
      failedFor('Alpha, Beta'),
    );

    // Never "and 1 more" for a name that fits in its place.
    romm.uploadFailures.value = const RommUploadFailures([
      'Alpha',
      'Beta',
      'Gamma',
      'Delta',
    ]);
    expect(
      notifications.notifier.value.single.message,
      failedFor('Alpha, Beta, Gamma, Delta'),
    );

    romm.uploadFailures.value = const RommUploadFailures([
      'Alpha',
      'Beta',
      'Gamma',
      'Delta',
      'Epsilon',
    ]);
    final notification = notifications.notifier.value.single;
    expect(notification.message, failedFor('Alpha, Beta, Gamma and 2 more'));
    expect(notification.type, GlobalNotificationType.error);
  });

  testWidgets('a failure that names no game says so', (tester) async {
    await pump(tester);

    romm.uploadFailures.value = const RommUploadFailures(
      [],
      unidentified: true,
    );

    expect(
      notifications.notifier.value.single.message,
      AppLocale.en[AppLocale.rommUploadsFailed],
    );
  });

  testWidgets('one notification is replaced, then dismissed, alone', (
    tester,
  ) async {
    await pump(tester);
    romm.uploadFailures.value = const RommUploadFailures(['Alpha']);
    notifications.show(id: 'unrelated', message: 'Another notification');

    romm.uploadFailures.value = const RommUploadFailures(['Beta']);
    expect(shown(), [
      'unrelated',
      RommUploadNotificationListener.notificationId,
    ]);

    romm.uploadFailures.value = RommUploadFailures.none;
    expect(shown(), ['unrelated']);
  });

  testWidgets('stops listening once it is gone', (tester) async {
    await pump(tester);
    await tester.pumpWidget(const SizedBox());

    romm.uploadFailures.value = const RommUploadFailures(['Alpha']);

    expect(shown(), isEmpty);
  });
}
