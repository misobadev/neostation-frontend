import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/recent_games_cycler.dart';

/// The systems screen's recent card shows one of the last few played games at
/// a time. These tests pin which one it shows, how the triggers step through
/// them, and when the timer is allowed to move it on its own.
void main() {
  const games = ['a.zip', 'b.zip', 'c.zip', 'd.zip', 'e.zip'];

  test('shows the most recent game first', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    expect(cycler.pick(games), 0);
  });

  test('steps both ways and wraps around', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    cycler.pick(games);

    cycler.step(1);
    expect(cycler.pick(games), 1);
    cycler.step(-2);
    expect(cycler.pick(games), 4);
    cycler.step(1);
    expect(cycler.pick(games), 0);
  });

  test('a newly played game resets the card to it', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    cycler.pick(games);
    cycler.step(1);
    cycler.step(1);

    expect(cycler.pick(['z.zip', ...games.take(4)]), 0);
  });

  test('a single recent game never cycles', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    cycler.pick(['a.zip']);
    cycler.step(1);
    expect(cycler.pick(['a.zip']), 0);
  });

  test('reports the count, index and direction the card needs', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    cycler.pick(games);
    expect(cycler.count, 5);
    expect(cycler.index, 0);

    cycler.step(-1);
    expect(cycler.index, 4);
    expect(cycler.direction, -1);
    cycler.step(1);
    expect(cycler.direction, 1);
  });

  test('stepping notifies so the card repaints', () {
    final cycler = RecentGamesCycler();
    addTearDown(cycler.dispose);
    cycler.pick(games);
    var notified = 0;
    cycler.addListener(() => notified++);

    cycler.step(1);
    expect(notified, 1);
  });

  group('auto-cycle', () {
    test('moves on by itself while the card is not focused', () {
      fakeAsync((async) {
        final cycler = RecentGamesCycler();
        cycler.pick(games);
        cycler.setFocused(false);

        // Last moved back by hand, so the timer must reset the direction.
        cycler.step(-1);
        async.elapse(RecentGamesCycler.interval);
        expect(cycler.pick(games), 0);
        expect(cycler.direction, 1, reason: 'the timer always moves forward');
        async.elapse(RecentGamesCycler.interval);
        expect(cycler.pick(games), 1);
        cycler.dispose();
      });
    });

    test('holds still while the card is focused', () {
      fakeAsync((async) {
        final cycler = RecentGamesCycler();
        cycler.pick(games);
        cycler.setFocused(true);

        async.elapse(RecentGamesCycler.interval * 3);
        expect(cycler.pick(games), 0);
        cycler.dispose();
      });
    });

    test('resumes a full interval after focus leaves', () {
      fakeAsync((async) {
        final cycler = RecentGamesCycler();
        cycler.pick(games);
        cycler.setFocused(false);
        async.elapse(RecentGamesCycler.interval ~/ 2);
        cycler.setFocused(true);
        cycler.setFocused(false);

        // The half interval spent before focus does not carry over.
        async.elapse(RecentGamesCycler.interval ~/ 2);
        expect(cycler.pick(games), 0);
        async.elapse(RecentGamesCycler.interval ~/ 2);
        expect(cycler.pick(games), 1);
        cycler.dispose();
      });
    });

    test('does not run with fewer than two games', () {
      fakeAsync((async) {
        final cycler = RecentGamesCycler();
        var notified = 0;
        cycler.addListener(() => notified++);
        cycler.pick(['a.zip']);
        cycler.setFocused(false);

        async.elapse(RecentGamesCycler.interval * 3);
        expect(notified, 0);
        expect(async.pendingTimers, isEmpty);
        cycler.dispose();
      });
    });

    test('stops when disposed', () {
      fakeAsync((async) {
        final cycler = RecentGamesCycler();
        cycler.pick(games);
        cycler.setFocused(false);
        cycler.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
