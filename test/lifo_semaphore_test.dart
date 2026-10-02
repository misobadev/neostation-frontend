import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/lifo_semaphore.dart';

/// The cover gate admits the newest waiter, not the oldest.
///
/// Under the fair FIFO `Semaphore` a scroll queued a fetch for every tile it
/// passed, and the covers actually on screen waited behind all of them — on a
/// slow server, minutes for images nobody would look at. Newest-first makes
/// the head of the queue whatever the user is looking at now.
void main() {
  test('admits up to maxCount without queueing', () async {
    final gate = LifoSemaphore(3);

    await gate.acquire();
    await gate.acquire();
    await gate.acquire();

    expect(gate.inFlight, 3);
    expect(gate.waiting, isZero);
  });

  test('the newest waiter is served first', () async {
    final gate = LifoSemaphore(1);
    final order = <String>[];

    await gate.acquire(); // the holder

    // Three tiles queue in the order the grid built them.
    final queued = <Future<void>>[
      for (final name in ['scrolled-past', 'nearly-visible', 'on-screen'])
        gate.acquire().then((_) {
          order.add(name);
          gate.release();
        }),
    ];
    await pumpEventQueue();
    expect(gate.waiting, 3, reason: 'all three should be waiting on the gate');

    gate.release();
    await Future.wait(queued);

    // Not just "on-screen first" — the whole queue unwinds newest-first.
    expect(order, ['on-screen', 'nearly-visible', 'scrolled-past']);
  });

  test('a waiter admitted after a release still holds a real slot', () async {
    final gate = LifoSemaphore(2);
    await gate.acquire();
    await gate.acquire();

    var thirdRan = false;
    final third = gate.acquire().then((_) => thirdRan = true);

    await pumpEventQueue();
    expect(thirdRan, isFalse, reason: 'the gate is full');
    expect(gate.inFlight, 2);

    gate.release();
    await third;

    // The slot was handed over rather than decremented and re-taken, so the
    // count never dips and never exceeds maxCount.
    expect(thirdRan, isTrue);
    expect(gate.inFlight, 2);
    expect(gate.waiting, isZero);
  });

  test('never admits more than maxCount at once', () async {
    final gate = LifoSemaphore(4);
    var live = 0;
    var peak = 0;

    await Future.wait([
      for (var i = 0; i < 40; i++)
        () async {
          await gate.acquire();
          live++;
          peak = peak > live ? peak : live;
          await Future<void>.delayed(Duration.zero);
          live--;
          gate.release();
        }(),
    ]);

    expect(peak, lessThanOrEqualTo(4));
    expect(gate.inFlight, isZero, reason: 'every slot came back');
    expect(gate.waiting, isZero);
  });
}
