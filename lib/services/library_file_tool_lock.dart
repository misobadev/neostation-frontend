import 'package:flutter/foundation.dart';

/// Keeps the Tools that rewrite the library on disk from running at the same
/// time: the multi-disc organiser and the orphan metadata cleanup.
///
/// The two are not independent. The organiser moves a set's discs into a new
/// folder and hands the set's metadata to its `.m3u`, but the library only
/// learns about the `.m3u` when the organiser's rescan runs at the end. A
/// cleanup that analyses in between finds that metadata with no ROM behind it
/// and deletes it, along with the media it just renamed.
///
/// One holder, owned here rather than by either runner, so each runner can
/// refuse while the other runs without the two importing each other, and
/// Tools can check a single flag before it even starts the cleanup's analysis.
///
/// A run that never finishes (a rescan that hangs, say) keeps the lock until
/// the app restarts, as `RommLinkRunner`'s running flag does.
class LibraryFileToolLock {
  LibraryFileToolLock._();

  static String? _holder;

  /// True while either tool is running.
  static bool get isHeld => _holder != null;

  /// True while [tool] — a runner's notification id — is the one running.
  static bool isHeldBy(String tool) => _holder == tool;

  /// Takes the lock for [tool], or returns false when a tool already holds it.
  ///
  /// Synchronous on purpose: a runner calls it before its first await, so a
  /// second press that lands while the first run is still starting is
  /// refused rather than racing it.
  static bool tryAcquire(String tool) {
    if (_holder != null) return false;
    _holder = tool;
    return true;
  }

  /// Releases the lock if [tool] holds it.
  static void release(String tool) {
    if (_holder == tool) _holder = null;
  }

  /// Drops the lock whoever holds it, so a test that left a run held can't
  /// refuse the next test's.
  @visibleForTesting
  static void debugReset() => _holder = null;
}
