import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/utils/user_data_move_guard.dart';
import 'package:neostation/widgets/user_data_move_progress_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// NEO-236: scans, scrapes, downloads, tools and game launches started
// elsewhere in the app while the user data moved wrote to the old folder,
// which the move then deleted. They now wait, and say why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bell = GlobalNotificationService();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(bell.dismiss);
  tearDown(() {
    UserDataLocationService.debugMoving = false;
    bell.dismiss();
  });

  test('with no move running, nothing waits', () {
    expect(refuseWhileUserDataMoves(), isFalse);
    expect(bell.notifier.value, isEmpty);
  });

  test('during a move, the action waits and the bell says why, once', () {
    UserDataLocationService.debugMoving = true;

    expect(refuseWhileUserDataMoves(), isTrue);
    expect(refuseWhileUserDataMoves(), isTrue);

    expect(bell.notifier.value, hasLength(1));
    expect(
      bell.notifier.value.single.message,
      AppLocale.en[AppLocale.userDataMoveRunning],
    );
  });

  test('the entry goes when the move ends', () {
    UserDataLocationService.debugMoving = true;
    refuseWhileUserDataMoves();

    clearUserDataMoveRunningNotice();

    expect(bell.notifier.value, isEmpty);
  });
}
