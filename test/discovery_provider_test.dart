import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/providers/discovery_provider.dart';
import 'package:neostation/services/discovery/discovery_service.dart';

/// A service that counts the boards it builds, and can hold one back so a test
/// can act while a load is running.
class _FakeDiscoveryService implements DiscoveryService {
  int loads = 0;
  int rerolls = 0;
  Completer<void>? hold;
  bool fail = false;

  /// Failing loads left before the service recovers, when [fail] is set. A
  /// cap rather than failing for good, so a provider that kept retrying shows
  /// up as a count instead of hanging the test.
  int failuresLeft = 5;

  @override
  String get currentWeekKey => '2026-W47';

  @override
  Future<DiscoveryBoard> loadBoard() async {
    loads++;
    final gate = hold;
    if (gate != null) await gate.future;
    if (fail && failuresLeft > 0) {
      failuresLeft--;
      throw StateError('database unavailable');
    }
    return DiscoveryBoard(weekKey: currentWeekKey, entries: const []);
  }

  @override
  Future<DiscoveryBoard> reroll(
    String slotId, {
    Set<String> alsoExclude = const {},
  }) async {
    rerolls++;
    final gate = hold;
    if (gate != null) await gate.future;
    return DiscoveryBoard(weekKey: currentWeekKey, entries: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeDiscoveryService service;
  late DiscoveryProvider provider;

  setUp(() {
    service = _FakeDiscoveryService();
    provider = DiscoveryProvider(service: service);
  });

  group('hidden systems', () {
    test('the same hidden systems reuse the board in memory', () async {
      await provider.load(hiddenSystems: {'amiga'});
      await provider.load(hiddenSystems: {'amiga'});

      expect(service.loads, 1);
    });

    test('hiding a system rebuilds the board', () async {
      await provider.load(hiddenSystems: const {});
      await provider.load(hiddenSystems: {'amiga'});

      expect(service.loads, 2);
    });

    test('showing a system again rebuilds the board', () async {
      await provider.load(hiddenSystems: {'amiga'});
      await provider.load(hiddenSystems: const {});

      expect(service.loads, 2);
    });

    test('the set is compared by content, not by identity', () async {
      await provider.load(hiddenSystems: {'amiga', 'snes'});
      await provider.load(hiddenSystems: {'snes', 'amiga'});

      expect(service.loads, 1);
    });

    test('a load without a set keeps the last one passed', () async {
      await provider.load(hiddenSystems: {'amiga'});
      await provider.load();

      expect(service.loads, 1);
    });

    test(
      'a system hidden while a load runs gets a board of its own after it',
      () async {
        service.hold = Completer<void>();
        final first = provider.load(hiddenSystems: const {});
        await Future<void>.delayed(Duration.zero);

        // The tab comes back from Settings before the first board is ready.
        final second = provider.load(hiddenSystems: {'amiga'});
        service.hold!.complete();
        await Future.wait([first, second]);

        expect(service.loads, 2);
        await provider.load(hiddenSystems: {'amiga'});
        expect(service.loads, 2, reason: 'the second board is now current');
      },
    );

    test('a system hidden while a re-roll runs rebuilds the board', () async {
      await provider.load(hiddenSystems: const {});
      service.hold = Completer<void>();

      final rolling = provider.reroll('hero');
      await Future<void>.delayed(Duration.zero);
      final loading = provider.load(hiddenSystems: {'amiga'});
      service.hold!.complete();
      await Future.wait([rolling, loading]);

      expect(service.rerolls, 1);
      expect(service.loads, 2);
    });

    test(
      'hiding a system drops the old board while the new one builds',
      () async {
        await provider.load(hiddenSystems: const {});
        expect(provider.board, isNotNull);
        service.hold = Completer<void>();

        final loading = provider.load(hiddenSystems: {'amiga'});
        await Future<void>.delayed(Duration.zero);

        expect(provider.loading, isTrue);
        expect(provider.board, isNull, reason: 'it may hold hidden games');
        service.hold!.complete();
        await loading;
        expect(provider.board, isNotNull);
      },
    );

    test('a forced reload keeps the board on screen while it builds', () async {
      await provider.load(hiddenSystems: const {});
      service.hold = Completer<void>();

      final loading = provider.load(force: true);
      await Future<void>.delayed(Duration.zero);

      expect(provider.loading, isTrue);
      expect(provider.board, isNotNull);
      service.hold!.complete();
      await loading;
    });

    test('a failed load is not retried on its own', () async {
      service.fail = true;
      await provider.load(hiddenSystems: const {});

      expect(provider.failed, isTrue);
      expect(service.loads, 1);
    });

    test(
      'a failed rebuild after hiding a system is not retried on its own',
      () async {
        await provider.load(hiddenSystems: const {});
        service.fail = true;

        await provider.load(hiddenSystems: {'amiga'});

        expect(provider.failed, isTrue);
        expect(service.loads, 2);
      },
    );

    test(
      'a re-roll records the hidden systems its board was built under',
      () async {
        // A board from an earlier load, then a rebuild under new hidden systems
        // that fails, leaving the old board on screen.
        await provider.load(hiddenSystems: const {});
        service.fail = true;
        service.failuresLeft = 1;
        await provider.load(hiddenSystems: {'amiga'});
        expect(service.loads, 2);

        // The re-roll reads the library afresh, so its board already leaves the
        // hidden system out and the next visit needs no rebuild.
        await provider.reroll('hero');
        await provider.load(hiddenSystems: {'amiga'});

        expect(service.loads, 2);
      },
    );
  });

  group('markStale', () {
    test('a board on screen is rebuilt straight away', () async {
      await provider.load(hiddenSystems: const {});

      provider.markStale();
      await pumpEventQueue();

      expect(service.loads, 2);
    });

    test('with no board yet, nothing is built', () async {
      provider.markStale();
      await pumpEventQueue();

      expect(service.loads, 0);
    });

    test('the next visit after a rebuild reuses it', () async {
      await provider.load(hiddenSystems: const {});
      provider.markStale();
      await pumpEventQueue();

      await provider.load(hiddenSystems: const {});

      expect(service.loads, 2);
    });

    test('marked stale while a load runs, it is rebuilt after it', () async {
      service.hold = Completer<void>();
      final loading = provider.load(hiddenSystems: const {});
      await Future<void>.delayed(Duration.zero);

      // A game is hidden while the first board is still being built.
      provider.markStale();
      service.hold!.complete();
      await loading;
      await pumpEventQueue();

      expect(service.loads, 2);
    });

    test('a forced reload asked for during a load runs after it', () async {
      service.hold = Completer<void>();
      final first = provider.load(hiddenSystems: const {});
      await Future<void>.delayed(Duration.zero);

      // Returning from a pick while the board is still being built.
      final forced = provider.load(force: true);
      service.hold!.complete();
      await Future.wait([first, forced]);

      expect(service.loads, 2);
    });
  });
}
