import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/romm/romm_link_runner.dart';

/// The Tools runner's notification contract.
///
/// The pass moved off the connect path and behind a button, so what the user
/// sees is now the whole interface to it: a progress row while it walks, and
/// one terminal row that says which of linked / nothing-to-do / failed /
/// unavailable happened.
void main() {
  const strings = RommLinkStrings(
    title: 'Link library',
    preparing: 'Preparing…',
    progressTemplate: '{done} of {total} — {system}',
    doneTemplate: 'Linked {count} games',
    nothingToDo: 'Nothing new to link',
    failed: 'Linking failed',
    unavailable: 'Not available right now',
  );

  setUp(() => GlobalNotificationService().notifier.value = []);
  tearDown(() => GlobalNotificationService().notifier.value = []);

  group('string substitution', () {
    test('progress fills all three placeholders', () {
      expect(strings.progress(3, 34, 'SNES'), '3 of 34 — SNES');
    });

    test('done fills the count', () {
      expect(strings.done(6774), 'Linked 6774 games');
    });
  });

  group('the run', () {
    test(
      'with no RomM sync provider it reports unavailable, not failed',
      () async {
        // No SyncManager provider is registered in a bare test, which is the
        // same shape as "RomM is not set up". Saying "failed" for it would send
        // someone looking for a fault that is not there.
        final linked = await RommLinkRunner.run(strings: strings);

        expect(linked, isNull);
        final row = GlobalNotificationService().notifier.value.firstWhere(
          (n) => n.id == RommLinkRunner.notificationId,
        );
        expect(row.message, strings.unavailable);
      },
    );

    test('the terminal row carries no progress bar', () async {
      await RommLinkRunner.run(strings: strings);

      final row = GlobalNotificationService().notifier.value.firstWhere(
        (n) => n.id == RommLinkRunner.notificationId,
      );
      // `update` resolves progress as `progress ?? existing.progress`, so a
      // terminal row written with `update(progress: null)` keeps whatever bar
      // the run left behind. The runner uses `show`, which replaces the row.
      expect(row.progress, isNull);
      expect(row.ongoing, isFalse, reason: 'the run is over');
    });

    test('it does not leave isRunning set', () async {
      await RommLinkRunner.run(strings: strings);

      expect(
        RommLinkRunner.isRunning,
        isFalse,
        reason: 'a stuck flag would refuse every later run for the session',
      );
    });

    test('progress state changes are reported to the caller', () async {
      // Tools redraws its row from this, so a run that never reports leaves
      // the button rendering the wrong state until something else rebuilds.
      var changes = 0;
      await RommLinkRunner.run(
        strings: strings,
        onProgressStateChanged: () => changes++,
      );

      expect(changes, greaterThanOrEqualTo(2), reason: 'start and finish');
    });
  });
}
