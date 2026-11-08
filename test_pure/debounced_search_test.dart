import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:neostation/utils/debounced_search.dart';

/// The debounce behind the RomM in-platform search field, under a fake
/// clock: one run per typing pause, an immediate run for a cleared field,
/// and results that arrive for a term the user has already typed past are
/// never surfaced.

const _delay = Duration(milliseconds: 400);

void main() {
  group('DebouncedSearch', () {
    test('six keystrokes inside the delay make one run', () {
      fakeAsync((async) {
        final runs = <String>[];
        final search = DebouncedSearch<int>(
          delay: _delay,
          run: (term) async {
            runs.add(term);
            return term.length;
          },
        );

        for (final term in ['c', 'ch', 'chr', 'chro', 'chron', 'chrono']) {
          search.submit(term);
          async.elapse(const Duration(milliseconds: 50));
        }
        expect(runs, isEmpty, reason: 'still inside the pause');
        expect(search.hasPending, isTrue);

        async.elapse(_delay);
        expect(runs, ['chrono']);
        expect(search.hasPending, isFalse);
      });
    });

    test('a second term after the first ran makes a second run', () {
      fakeAsync((async) {
        final runs = <String>[];
        final results = <String>[];
        final search = DebouncedSearch<void>(
          delay: _delay,
          run: (term) async => runs.add(term),
          onResult: (term, _) => results.add(term),
        );

        search.submit('mario');
        async.elapse(_delay);
        search.submit('mario k');
        async.elapse(_delay);

        expect(runs, ['mario', 'mario k']);
        expect(results, ['mario', 'mario k']);
        expect(search.latestId, 2);
      });
    });

    test('a completion for a superseded term is ignored', () {
      fakeAsync((async) {
        final completers = <String, Completer<String>>{};
        final surfaced = <String>[];
        final search = DebouncedSearch<String>(
          delay: _delay,
          run: (term) {
            final completer = Completer<String>();
            completers[term] = completer;
            return completer.future;
          },
          onResult: (term, result) => surfaced.add('$term=$result'),
        );

        // "ch" settles and goes to the server ...
        search.submit('ch');
        async.elapse(_delay);
        final first = search.latestId;
        expect(search.isStale(first), isFalse);

        // ... the user keeps typing; "chrono" settles and is issued too.
        search.submit('chrono');
        async.elapse(_delay);
        expect(search.isStale(first), isTrue);

        // The slow first response lands last: it must not be surfaced.
        completers['chrono']!.complete('six');
        async.flushMicrotasks();
        completers['ch']!.complete('two');
        async.flushMicrotasks();

        expect(surfaced, ['chrono=six']);
      });
    });

    test('a stale failure is dropped; a current one reaches onError', () {
      fakeAsync((async) {
        final completers = <String, Completer<void>>{};
        final errors = <String>[];
        final search = DebouncedSearch<void>(
          delay: _delay,
          run: (term) {
            final completer = Completer<void>();
            completers[term] = completer;
            return completer.future;
          },
          onError: (term, error, _) => errors.add('$term:$error'),
        );

        search.submit('a');
        async.elapse(_delay);
        search.submit('ab');
        async.elapse(_delay);

        completers['a']!.completeError(StateError('timeout'));
        async.flushMicrotasks();
        expect(errors, isEmpty, reason: '"a" was superseded by "ab"');

        completers['ab']!.completeError(StateError('offline'));
        async.flushMicrotasks();
        expect(errors, ['ab:Bad state: offline']);
      });
    });

    test('an empty term runs at once and cancels a pending one', () {
      fakeAsync((async) {
        final runs = <String>[];
        final search = DebouncedSearch<void>(
          delay: _delay,
          run: (term) async => runs.add(term),
        );

        search.submit('zel');
        async.elapse(const Duration(milliseconds: 100));
        search.submit('');
        expect(runs, [''], reason: 'a clear does not wait out the debounce');
        expect(search.hasPending, isFalse);

        async.elapse(_delay);
        expect(runs, [''], reason: 'the cancelled "zel" never ran');
      });
    });

    test('flush runs the pending term without waiting', () {
      fakeAsync((async) {
        final runs = <String>[];
        final search = DebouncedSearch<void>(
          delay: _delay,
          run: (term) async => runs.add(term),
        );

        search.flush();
        expect(runs, isEmpty, reason: 'nothing pending');

        search.submit('sonic');
        search.flush();
        expect(runs, ['sonic']);
        async.elapse(_delay);
        expect(runs, ['sonic'], reason: 'the timer was cancelled by flush');
      });
    });

    test('cancel drops the pending term and stales in-flight runs', () {
      fakeAsync((async) {
        final runs = <String>[];
        final surfaced = <String>[];
        final completer = Completer<void>();
        final search = DebouncedSearch<void>(
          delay: _delay,
          run: (term) {
            runs.add(term);
            return completer.future;
          },
          onResult: (term, _) => surfaced.add(term),
        );

        search.submit('metroid');
        async.elapse(_delay);
        expect(runs, ['metroid']);

        search.submit('metroid p');
        search.cancel();
        async.elapse(_delay);
        expect(runs, ['metroid'], reason: 'the pending term was dropped');

        completer.complete();
        async.flushMicrotasks();
        expect(surfaced, isEmpty, reason: 'the in-flight run went stale');
      });
    });
  });
}
