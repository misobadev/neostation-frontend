import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/utils/systems_update_flow.dart';

/// The systems update check runs from two places, start-up and the
/// "Check for Systems Updates" row in Settings > General. Both go through
/// [SystemsUpdateFlow], which owns the order of the steps (check, dialogue,
/// reload, rescan), makes sure only one check is ever in flight, and decides
/// whether the outcome is worth telling the user about.
void main() {
  const update = SystemsUpdateInfo(
    currentVersion: '0.4.2',
    remoteVersion: '0.4.3',
  );

  late List<String> calls;
  late int checks;
  late int dialogs;

  /// Records what the flow asks of the library, in order.
  SystemsUpdateLibrary recordingLibrary({Future<void> Function()? idle}) =>
      SystemsUpdateLibrary(
        reloadDefinitions: () async => calls.add('reload'),
        whenScansIdle: () async {
          calls.add('idle');
          await idle?.call();
        },
        rescan: () async => calls.add('rescan'),
      );

  void answerCheckWith(SystemsUpdateCheck result) {
    SystemsUpdateFlow.check = () async {
      checks++;
      return result;
    };
  }

  void answerDialogWith(bool? accepted) {
    SystemsUpdateFlow.showUpdateDialog = (context, info) async {
      dialogs++;
      return accepted;
    };
  }

  setUp(() {
    calls = [];
    checks = 0;
    dialogs = 0;
    SystemsUpdateFlow.debugReset();
    GlobalNotificationService().dismiss();
    answerDialogWith(false);
  });

  tearDown(() {
    SystemsUpdateFlow.debugReset();
    GlobalNotificationService().dismiss();
  });

  /// Pumps a bare app and hands back a context inside its navigator.
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  List<GlobalNotificationData> notifications() =>
      GlobalNotificationService().notifier.value;

  String english(String key) => appLocaleEn[key] as String;

  group('single flight', () {
    testWidgets('a second call while one is in flight shares it', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      final pending = Completer<SystemsUpdateCheck>();
      SystemsUpdateFlow.check = () {
        checks++;
        return pending.future;
      };
      answerDialogWith(true);

      final first = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.startup,
        library: recordingLibrary(),
      );
      final second = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
      expect(SystemsUpdateFlow.isRunning, isTrue);

      pending.complete(const SystemsUpdateAvailable(update));
      expect(await first, isTrue);
      expect(await second, isTrue);

      expect(checks, 1);
      expect(dialogs, 1, reason: 'two dialogues would stack on each other');
      expect(calls, ['reload', 'idle', 'rescan']);
      expect(SystemsUpdateFlow.isRunning, isFalse);
    });

    testWidgets('a call after the last one finished checks again', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      answerCheckWith(const SystemsUpToDate('0.4.2'));

      await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
      await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );

      expect(checks, 2);
    });

    testWidgets('a check that throws still releases the guard', (tester) async {
      final context = await pumpHost(tester);
      SystemsUpdateFlow.check = () async {
        checks++;
        throw StateError('boom');
      };

      final updated = await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );

      expect(updated, isFalse);
      expect(SystemsUpdateFlow.isRunning, isFalse);
      // A throw is a check that could not be made, and says so.
      expect(
        notifications().single.message,
        english(AppLocale.systemsUpdateCheckFailed),
      );
    });

    testWidgets('checking is raised only while the check runs', (tester) async {
      final context = await pumpHost(tester);
      final pending = Completer<SystemsUpdateCheck>();
      SystemsUpdateFlow.check = () => pending.future;

      expect(SystemsUpdateFlow.checking.value, isFalse);
      final run = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
      expect(SystemsUpdateFlow.checking.value, isTrue);

      pending.complete(const SystemsUpToDate('0.4.2'));
      await run;
      expect(SystemsUpdateFlow.checking.value, isFalse);
    });
  });

  group('manual outcomes', () {
    Future<void> runManual(WidgetTester tester) async {
      final context = await pumpHost(tester);
      await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
    }

    testWidgets('up to date names the installed version', (tester) async {
      answerCheckWith(const SystemsUpToDate('0.4.2'));
      await runManual(tester);

      final shown = notifications().single;
      expect(shown.message, 'Systems are up to date (v0.4.2)');
      expect(shown.type, GlobalNotificationType.info);
      expect(dialogs, 0);
    });

    testWidgets('a failed check says so, as an error', (tester) async {
      answerCheckWith(const SystemsUpdateCheckFailed());
      await runManual(tester);

      final shown = notifications().single;
      expect(
        shown.message,
        "Couldn't check for systems updates. Check your internet connection "
        'and try again.',
      );
      expect(shown.type, GlobalNotificationType.error);
    });

    testWidgets('an update for a newer app says to update the app', (
      tester,
    ) async {
      answerCheckWith(const SystemsUpdateNeedsNewerApp());
      await runManual(tester);

      expect(
        notifications().single.message,
        english(AppLocale.systemsUpdateNeedsNewerApp),
      );
      expect(dialogs, 0);
    });

    testWidgets('pressing again replaces the message instead of stacking', (
      tester,
    ) async {
      answerCheckWith(const SystemsUpToDate('0.4.2'));
      await runManual(tester);
      await runManual(tester);

      expect(notifications(), hasLength(1));
    });

    testWidgets('an available update opens the dialogue, not a message', (
      tester,
    ) async {
      answerCheckWith(const SystemsUpdateAvailable(update));
      await runManual(tester);

      expect(dialogs, 1);
      expect(notifications(), isEmpty);
    });

    testWidgets('a manual press joining the start-up check gets the outcome', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      final pending = Completer<SystemsUpdateCheck>();
      SystemsUpdateFlow.check = () {
        checks++;
        return pending.future;
      };

      final startup = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.startup,
        library: recordingLibrary(),
      );
      final manual = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
      pending.complete(const SystemsUpToDate('0.4.2'));
      await startup;
      await manual;

      expect(checks, 1);
      expect(notifications().single.message, 'Systems are up to date (v0.4.2)');
    });
  });

  group('start-up stays silent', () {
    for (final outcome in const <SystemsUpdateCheck>[
      SystemsUpToDate('0.4.2'),
      SystemsUpdateCheckFailed(),
      SystemsUpdateNeedsNewerApp(),
    ]) {
      testWidgets('on ${outcome.runtimeType}', (tester) async {
        final context = await pumpHost(tester);
        answerCheckWith(outcome);

        final updated = await SystemsUpdateFlow.run(
          context,
          trigger: SystemsUpdateTrigger.startup,
          library: recordingLibrary(),
        );

        expect(updated, isFalse);
        expect(notifications(), isEmpty);
        expect(calls, isEmpty);
      });
    }
  });

  group('after the dialogue', () {
    testWidgets('an accepted update reloads definitions, then rescans', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      answerCheckWith(const SystemsUpdateAvailable(update));
      answerDialogWith(true);

      final updated = await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );

      expect(updated, isTrue);
      expect(calls, ['reload', 'idle', 'rescan']);
    });

    testWidgets('the rescan waits for a running scan to finish', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      answerCheckWith(const SystemsUpdateAvailable(update));
      answerDialogWith(true);
      final scanRunning = Completer<void>();

      final run = SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.startup,
        library: recordingLibrary(idle: () => scanRunning.future),
      );
      await tester.pump();

      // A scan started while one runs is dropped, so it must not go yet.
      expect(calls, ['reload', 'idle']);

      scanRunning.complete();
      expect(await run, isTrue);
      expect(calls, ['reload', 'idle', 'rescan']);
    });

    testWidgets('the dialogue still opens after the caller has gone', (
      tester,
    ) async {
      // The user leaves Settings while the check runs: the row that asked is
      // unmounted by the time the update is found.
      final showCaller = ValueNotifier(true);
      addTearDown(showCaller.dispose);
      late BuildContext caller;
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: showCaller,
            builder: (context, show, _) => show
                ? Builder(
                    builder: (context) {
                      caller = context;
                      return const SizedBox.shrink();
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ),
      );
      final pending = Completer<SystemsUpdateCheck>();
      SystemsUpdateFlow.check = () => pending.future;
      BuildContext? shownOn;
      SystemsUpdateFlow.showUpdateDialog = (context, info) async {
        dialogs++;
        shownOn = context;
        return false;
      };

      final run = SystemsUpdateFlow.run(
        caller,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );
      showCaller.value = false;
      await tester.pump();
      expect(caller.mounted, isFalse);

      pending.complete(const SystemsUpdateAvailable(update));
      await run;

      expect(dialogs, 1);
      expect(shownOn!.mounted, isTrue);
      expect(
        (shownOn! as StatefulElement).state,
        isA<NavigatorState>(),
        reason: 'shown on the root navigator captured at the start',
      );
    });

    testWidgets('a declined update leaves the library alone', (tester) async {
      final context = await pumpHost(tester);
      answerCheckWith(const SystemsUpdateAvailable(update));
      answerDialogWith(false);

      final updated = await SystemsUpdateFlow.run(
        context,
        trigger: SystemsUpdateTrigger.manual,
        library: recordingLibrary(),
      );

      expect(updated, isFalse);
      expect(calls, isEmpty);
      expect(notifications(), isEmpty);
    });
  });

  group('strings', () {
    // Every key must also be in every locale map; `app_locale_test.dart`
    // enforces that. What it cannot see is a value pasted in English, or a
    // translation that dropped the placeholder the flow fills in.
    const newKeys = [
      AppLocale.checkSystemsUpdates,
      AppLocale.systemsUpdateChecking,
      AppLocale.systemsUpToDate,
      AppLocale.systemsUpdateCheckFailed,
      AppLocale.systemsUpdateNeedsNewerApp,
    ];
    const translations = <String, Map<String, dynamic>>{
      'de': appLocaleDe,
      'es': appLocaleEs,
      'fr': appLocaleFr,
      'id': appLocaleId,
      'it': appLocaleIt,
      'ja': appLocaleJa,
      'ko': appLocaleKo,
      'pt': appLocalePt,
      'ru': appLocaleRu,
      'zh': appLocaleZh,
      'zh_Hant': appLocaleZhHant,
    };

    test('English defines every new key', () {
      for (final key in newKeys) {
        expect(appLocaleEn[key], isA<String>(), reason: key);
      }
    });

    for (final entry in translations.entries) {
      test('${entry.key} translates every new key', () {
        for (final key in newKeys) {
          final value = entry.value[key];
          expect(value, isA<String>(), reason: key);
          expect(value, isNot(appLocaleEn[key]), reason: '$key is English');
        }
        expect(
          entry.value[AppLocale.systemsUpToDate] as String,
          contains('{version}'),
        );
      });
    }
  });
}
