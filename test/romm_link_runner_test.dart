import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm/romm_link_runner.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/romm_failure_message.dart';

/// The Tools runner's notification contract.
///
/// The pass moved off the connect path and behind a button, so what the user
/// sees is now the whole interface to it: a progress row while it walks, and
/// one terminal row that says which of linked / nothing-to-do / stopped-early /
/// failed / unavailable happened.
void main() {
  const strings = RommLinkStrings(
    title: 'Link library',
    preparing: 'Preparing…',
    progressTemplate: '{done} of {total} — {system}',
    doneTemplate: 'Linked {count} games',
    nothingToDo: 'Nothing new to link',
    failed: 'Linking failed',
    unavailable: 'Not available right now',
    stoppedEarlyTemplate: 'Stopped early — linked {count} games so far',
    failureTexts: {},
  );

  setUp(() => GlobalNotificationService().notifier.value = []);
  tearDown(() => GlobalNotificationService().notifier.value = []);

  group('a pass that could not run', () {
    final withReasons = RommLinkStrings(
      title: strings.title,
      preparing: strings.preparing,
      progressTemplate: strings.progressTemplate,
      doneTemplate: strings.doneTemplate,
      nothingToDo: strings.nothingToDo,
      failed: strings.failed,
      unavailable: strings.unavailable,
      stoppedEarlyTemplate: strings.stoppedEarlyTemplate,
      failureTexts: {
        for (final key in rommBrowseFailureKeys)
          key: AppLocale.en[key] as String,
      },
    );

    test('says why when RomM failed, in the browse screen\'s words', () {
      expect(
        withReasons.failedBecause(
          RommLinkPassException(
            'platform enumeration failed',
            RommException(
              'Cannot reach server',
              kind: RommFailure.unreachable,
              detail: 'Connection refused',
            ),
          ),
        ),
        "Can't reach the RomM server: Connection refused",
      );
      expect(
        withReasons.failedBecause(
          RommLinkPassException(
            'platform enumeration failed',
            RommException(
              'Request failed (500)',
              statusCode: 500,
              kind: RommFailure.serverError,
            ),
          ),
        ),
        'The RomM server answered with an error (500).',
      );
      // The server is already known to be RomM, so not "check the server
      // URL" as when connecting.
      expect(
        withReasons.failedBecause(
          RommLinkPassException(
            'platform enumeration failed',
            RommException('Not a RomM answer', kind: RommFailure.notRomm),
          ),
        ),
        "The RomM server sent an answer the app couldn't read.",
      );
    });

    test('keeps "Linking failed" for anything that isn\'t a RomM failure', () {
      expect(
        withReasons.failedBecause(
          RommLinkPassException('library index failed', StateError('db')),
        ),
        'Linking failed',
      );
      expect(withReasons.failedBecause(Exception('boom')), 'Linking failed');
    });

    test('keeps "Linking failed" without the failure texts', () {
      expect(
        strings.failedBecause(
          RommException('Request timed out', kind: RommFailure.timeout),
        ),
        'Linking failed',
      );
    });

    test('every text a RomM failure can need is resolved up front', () {
      // The texts are looked up before the run, while the Tools screen is
      // still there; one missing here would read "Linking failed" instead.
      final used = <String>{};
      for (final kind in RommFailure.values) {
        for (final e in [
          RommException('x', kind: kind),
          RommException('x', kind: kind, statusCode: 502, detail: 'why'),
        ]) {
          rommFailureMessage(e, (key) {
            used.add(key);
            return key;
          }, browsing: true);
        }
      }
      expect(rommBrowseFailureKeys.toSet(), containsAll(used));
    });
  });

  group('string substitution', () {
    test('progress fills all three placeholders', () {
      expect(strings.progress(3, 12, 'SNES'), '3 of 12 — SNES');
    });

    test('done fills the count', () {
      expect(strings.done(1234), 'Linked 1234 games');
    });

    test('stoppedEarly fills the count', () {
      expect(
        strings.stoppedEarly(12),
        'Stopped early — linked 12 games so far',
      );
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
      // A finished run's summary must not sit under the bar it left behind.
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
