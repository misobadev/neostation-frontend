import 'dart:async';

/// A counting semaphore that admits the *most recently* queued waiter first.
///
/// [Semaphore] (`semaphore.dart`) serves its queue FIFO, which is right when
/// every waiter is equally wanted — a bulk sync, a scrape run — because it is
/// fair and nothing starves.
///
/// It is wrong for work whose value decays while it waits. A grid of image
/// tiles is the clear case: scrolling queues a fetch for every tile it passes,
/// and under FIFO the covers now on screen sit behind every tile already
/// scrolled past. With a 30-second timeout per fetch and a handful of slots,
/// the visible rows can wait minutes for images nobody will ever look at.
/// Newest-first inverts that — whatever was asked for last is, by construction,
/// what the user is looking at now.
///
/// The trade is starvation: with a queue that never drains, an early waiter may
/// wait indefinitely. That is acceptable *only* because a stale cover request
/// losing its place costs nothing — the tile that wanted it is gone, and if it
/// returns it simply asks again and goes to the front. Do not reach for this
/// class for work that must complete.
class LifoSemaphore {
  /// How many holders may be inside the guarded section at once.
  final int maxCount;

  int _currentCount = 0;

  /// Waiters, oldest first. [release] takes from the end.
  final List<Completer<void>> _waitQueue = <Completer<void>>[];

  LifoSemaphore(this.maxCount) : assert(maxCount > 0);

  /// Holders currently inside the guarded section. Test seam.
  int get inFlight => _currentCount;

  /// Waiters that have not been admitted yet. Test seam.
  int get waiting => _waitQueue.length;

  /// Acquires a slot, waiting behind later arrivals if [maxCount] is reached.
  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    await completer.future;
  }

  /// Releases a slot and admits the newest waiter.
  ///
  /// The slot is handed straight to that waiter rather than decremented and
  /// re-acquired, so a release can never let more than [maxCount] holders in.
  void release() {
    if (_waitQueue.isNotEmpty) {
      _waitQueue.removeLast().complete();
    } else {
      _currentCount--;
    }
  }
}
