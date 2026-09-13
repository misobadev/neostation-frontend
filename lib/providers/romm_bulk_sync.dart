import 'package:flutter/foundation.dart';

import '../models/romm_rom.dart';
import '../models/romm_rom_page.dart';
import '../services/logger_service.dart';
import '../services/romm/romm_paging.dart';
import 'romm_provider.dart';

/// Fetches one page of the source being synced. Offset/limit paging only — the
/// filter (platform, collection, search) is bound by whoever supplies this.
typedef RommPageFetcher =
    Future<RommRomPage> Function({required int limit, required int offset});

/// True when [rom] is already on disk and should be skipped.
typedef RommDownloadedCheck = Future<bool> Function(RommRom rom);

/// An on-disk ROM the enumeration matched to its RomM entry, held until the
/// plan is approved and written afterwards.
@immutable
class RommPendingLink {
  /// The server entry the local file matches.
  final RommRom rom;

  /// Extension-stripped local name — the key the sync provider caches state
  /// under, for the caller that refreshes it once a row is written.
  final String romname;

  /// True when the local file already had a mapping row when it was matched.
  /// Those are carried anyway so the plan can count them; the write skips them.
  final bool alreadyLinked;

  const RommPendingLink({
    required this.rom,
    required this.romname,
    required this.alreadyLinked,
  });
}

/// Matches a ROM the downloaded check found on disk to its RomM entry and
/// reports whether it is already linked. **Writes nothing**: the enumeration
/// runs before the user has approved anything, and a link written then
/// survives declining the dialog.
///
/// Returns null when there is no local copy after all (it vanished between the
/// downloaded check and the match, or its platform resolves to no local
/// system).
typedef RommLocalLinkResolver = Future<RommPendingLink?> Function(RommRom rom);

/// What writing the approved links came to: rows actually written, and rows
/// whose write failed (never folded into "already linked" — they have no row).
typedef RommLinkWriteResult = ({int written, int failed});

/// Writes the mapping rows for the matches the plan was approved with, in as
/// few transactions as the writer can manage. Rows only — never metadata or
/// media: a sync can touch thousands of ROMs.
typedef RommLocalLinkWriter =
    Future<RommLinkWriteResult> Function(List<RommPendingLink> pending);

/// Downloads one ROM, resolving to its final [RommDownload] record.
typedef RommRomDownloader = Future<RommDownload> Function(RommRom rom);

/// Where a queued ROM's bytes will land.
///
/// [volume] is both the grouping key and the name shown to the user: two ROMs
/// reporting the same volume draw from the same free space, and a sync that
/// spans volumes has to be checked against each one separately rather than
/// against whichever is roomiest.
@immutable
class RommSyncDestination {
  /// Identity of the destination volume (a mount point / volume root — see
  /// `VolumeSpace.id`).
  final String volume;

  /// Free bytes on it, or null when it couldn't be measured. Null is "don't
  /// know", never "none".
  final int? freeBytes;

  const RommSyncDestination({required this.volume, this.freeBytes});
}

/// Resolves the volume [rom] will be written to, for the pre-flight check.
///
/// Returning null means the destination couldn't be worked out (no matching
/// local system, an unmappable ROM folder): the ROM is still priced into the
/// plan's totals, it just can't be weighed against a volume.
///
/// Called once per queued ROM, so implementations are expected to memoize —
/// the answer is a property of the ROM's platform, not of the ROM.
typedef RommDestinationProbe =
    Future<RommSyncDestination?> Function(RommRom rom);

/// Last chance to call the sync off, once its real size is known. Returning
/// false abandons the queue before anything is downloaded.
typedef RommBulkSyncConfirm = Future<bool> Function(RommBulkSyncPlan plan);

/// What a bulk sync is doing right now.
enum RommBulkSyncPhase {
  /// No sync running (either never started or finished).
  idle,

  /// Paging the source to learn the full ROM set and filtering out what is
  /// already on disk. The download queue isn't known yet.
  preparing,

  /// The queue is known and priced; waiting on the user to approve it.
  confirming,

  /// Working through the queue.
  downloading,
}

/// The share of a sync that lands on one volume, and whether it fits there.
///
/// A queue spanning several volumes is several independent space questions:
/// 40 GB free on the SD card does nothing for the 20 GB of PS1 games headed for
/// internal storage. This is one of those questions.
@immutable
class RommBulkSyncVolumePlan {
  /// The volume, as reported by [RommDestinationProbe] — also what the
  /// pre-flight names when a sync spans more than one.
  final String volume;

  /// Queued ROMs headed here.
  final int romCount;

  /// Sum of their `fs_size_bytes` — what will be transferred to this volume.
  final int downloadBytes;

  /// [downloadBytes] plus this volume's share of the transient multi-disc
  /// extraction headroom. The number to compare against [freeBytes].
  final int requiredBytes;

  /// Free bytes here, or null when it couldn't be measured.
  final int? freeBytes;

  const RommBulkSyncVolumePlan({
    required this.volume,
    required this.romCount,
    required this.downloadBytes,
    required this.requiredBytes,
    required this.freeBytes,
  });

  /// True when free space couldn't be measured, so [fits] means nothing.
  bool get spaceUnknown => freeBytes == null;

  /// True when this volume's share should fit. Unknown free space counts as
  /// fitting — a missing number must not stand in the way of a sync.
  bool get fits => freeBytes == null || requiredBytes <= freeBytes!;

  /// How much more space this volume needs than it has (0 when it fits).
  int get shortfallBytes => fits ? 0 : requiredBytes - freeBytes!;
}

/// The measured shape of a sync, handed to [RommBulkSyncConfirm] so the
/// confirmation can quote real numbers instead of warning in prose.
///
/// Everything here is known only *after* the enumeration pass — which is why
/// the confirmation happens in the middle of [RommBulkSync.run] rather than
/// before it.
class RommBulkSyncPlan {
  /// Platform/collection being synced.
  final String sourceLabel;

  /// ROMs actually queued (the source minus what is already on disk).
  final int romCount;

  /// ROMs the pass found already on disk and won't fetch again
  /// ([linked] + [alreadyLinked], plus any that matched no local file).
  final int skipped;

  /// Of [skipped], ROMs that *will* gain a RomM link if this plan is
  /// approved. Nothing has been written when the plan is offered: the rows go
  /// in after the confirmation, so declining leaves the table untouched.
  final int linked;

  /// Of [skipped], ROMs that were already linked to RomM.
  final int alreadyLinked;

  /// Sum of the queue's `fs_size_bytes` — what will be transferred.
  final int downloadBytes;

  /// [downloadBytes] plus the transient headroom multi-disc extraction needs
  /// (see [RommBulkSync.transientHeadroomBytes]). This is the number to
  /// compare against free space.
  final int requiredBytes;

  /// Where the queue lands, broken down per volume — one entry per distinct
  /// volume [RommDestinationProbe] resolved, in the order first seen.
  ///
  /// Empty when no destination could be resolved at all (see [unresolvedRoms]),
  /// which reads as "nothing to check" rather than as a problem.
  final List<RommBulkSyncVolumePlan> volumes;

  /// Queued ROMs whose destination couldn't be resolved. Their bytes are in
  /// [downloadBytes] but they belong to no volume, so nothing can be said about
  /// whether they fit.
  final int unresolvedRoms;

  const RommBulkSyncPlan({
    required this.sourceLabel,
    required this.romCount,
    required this.skipped,
    required this.downloadBytes,
    required this.requiredBytes,
    required this.volumes,
    this.linked = 0,
    this.alreadyLinked = 0,
    this.unresolvedRoms = 0,
  });

  /// True when no volume could be measured, so [fits] means nothing.
  bool get spaceUnknown =>
      volumes.isEmpty || volumes.every((v) => v.spaceUnknown);

  /// True when every volume the queue touches should fit. Unknown free space
  /// counts as fitting: a missing number must not stand in the way of a sync
  /// the user asked for.
  bool get fits => volumes.every((v) => v.fits);

  /// How much more space the sync needs than it has, added up across the
  /// volumes that come up short (0 when it fits).
  int get shortfallBytes => volumes.fold(0, (sum, v) => sum + v.shortfallBytes);

  /// Free bytes at the destination when the whole queue lands on one volume,
  /// and null otherwise — including a multi-volume queue, where there is no
  /// single number to quote and [volumes] has to be reported instead.
  int? get freeBytes => volumes.length == 1 ? volumes.single.freeBytes : null;

  /// The volume that comes up shortest, for a one-line summary of a plan that
  /// doesn't fit. Null when everything fits (or nothing is measurable).
  RommBulkSyncVolumePlan? get tightestVolume {
    RommBulkSyncVolumePlan? worst;
    for (final volume in volumes) {
      if (volume.fits) continue;
      if (worst == null || volume.shortfallBytes > worst.shortfallBytes) {
        worst = volume;
      }
    }
    return worst;
  }
}

/// Downloads an entire RomM platform or collection in one action.
///
/// Deliberately a [ChangeNotifier] of its own rather than more state on
/// [RommProvider]: a running sync ticks constantly, and the browse screen
/// watches the provider for its ROM list. Folding progress into the provider
/// would rebuild the whole browse tree on every queue step, which is the shape
/// of jank this app has been bitten by before. Listening here rebuilds only the
/// progress UI.
///
/// It is owned by the provider (not the screen) so a sync survives leaving the
/// tab, and so [RommProvider.disconnect] can stop it.
///
/// Per-ROM byte progress is intentionally *not* mirrored here — it already
/// lives on [RommProvider.downloadFor] for the ids in [activeRomIds], and
/// copying it would reintroduce the per-chunk notify storm this class exists to
/// avoid. Aggregate counters move once per queue item.
class RommBulkSync extends ChangeNotifier {
  static final _log = LoggerService.instance;

  /// Simultaneous transfers. One at a time is slow on a large platform; letting
  /// the whole queue run at once saturates a handheld's wifi and the server.
  /// Three is a starting point to be tuned against a real server on device.
  static const int defaultConcurrency = 3;

  /// Rows per enumeration request — [RommPaging.pageSize], the one definition
  /// this walk and the connect-time link pass share. Kept under this name for
  /// the callers and tests that already read it here.
  static const int defaultPageSize = RommPaging.pageSize;

  /// Hard stop on the enumeration loop, in pages — [RommPaging.maxPages],
  /// shared with the link pass for the same reason as [defaultPageSize].
  static const int maxPages = RommPaging.maxPages;

  RommBulkSyncPhase _phase = RommBulkSyncPhase.idle;
  String _sourceLabel = '';
  bool _cancelRequested = false;
  bool _declined = false;

  int _enumerated = 0;
  int _enumerateTotal = 0;

  final List<RommRom> _queue = [];

  /// Matches the enumeration found, waiting on the confirmation. Written in
  /// one go after the plan is approved, never before it.
  final List<RommPendingLink> _pendingLinks = [];
  int _completed = 0;
  int _failed = 0;
  int _skipped = 0;
  int _linked = 0;
  int _alreadyLinked = 0;
  int _linkFailures = 0;
  int _cancelled = 0;
  int _doneBytes = 0;
  int _queuedBytes = 0;

  final Set<int> _activeRomIds = {};

  RommDownloadError? _lastError;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// [notifyListeners] that tolerates being disposed mid-run.
  ///
  /// A sync outlives the screen that started it and is only torn down with the
  /// app, so the last few queue steps can land after disposal; notifying then
  /// would throw out of a worker for no useful reason.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ── Getters ────────────────────────────────────────────────────────────────

  RommBulkSyncPhase get phase => _phase;
  bool get isRunning => _phase != RommBulkSyncPhase.idle;

  /// Name of the platform/collection being synced (for the progress UI).
  String get sourceLabel => _sourceLabel;

  /// True once cancellation was asked for, while the queue winds down.
  bool get cancelRequested => _cancelRequested;

  /// True when the last run ended because the user turned down the plan at the
  /// confirmation, before anything was downloaded. Distinct from
  /// [cancelRequested]: nothing was started, so there is nothing to report.
  bool get declined => _declined;

  /// ROMs seen so far by the enumeration pass, and the server's reported total
  /// for the query. Both are 0 outside [RommBulkSyncPhase.preparing].
  int get enumerated => _enumerated;
  int get enumerateTotal => _enumerateTotal;

  /// ROMs actually queued for download (the enumeration minus what was already
  /// on disk).
  int get total => _queue.length;

  int get completed => _completed;
  int get failed => _failed;

  /// ROMs the enumeration pass found already on disk and never queued.
  int get skipped => _skipped;

  /// Of [skipped], ROMs that gained a RomM link during this run (a mapping
  /// row was written for the local file). 0 when [run] had no linker, and 0
  /// until the plan is approved — the rows are written after the confirmation.
  int get linked => _linked;

  /// Matches waiting on the confirmation: what [linked] will be if the plan
  /// is approved and every write lands.
  int get pendingLinks => _pendingLinks.length;

  /// Of [skipped], ROMs that were already linked when the pass reached them.
  int get alreadyLinked => _alreadyLinked;

  /// Of [skipped], ROMs whose link could not be written (a failed database
  /// write, or a linker that threw). Counted apart from [alreadyLinked]
  /// because they have no row at all; the connect-time pass retries them.
  int get linkFailed => _linkFailures;

  /// Queue items abandoned because the sync was cancelled mid-flight.
  int get cancelled => _cancelled;

  /// Queue items that have reached a terminal state, however they got there.
  int get finished => _completed + _failed + _cancelled;

  /// Bytes of successfully downloaded ROMs, against the queue's total size.
  /// Both come from RomM's `fs_size_bytes`, so they count what the *server*
  /// holds — an unpacked multi-disc archive occupies more on disk than this.
  int get doneBytes => _doneBytes;
  int get totalBytes => _queuedBytes;

  /// ROM ids transferring right now. The UI reads live byte progress for these
  /// from [RommProvider.downloadFor].
  Set<int> get activeRomIds => Set.unmodifiable(_activeRomIds);

  /// Why the most recent failure failed, or null when nothing has failed.
  /// A whole-queue outcome, not per ROM: the last failure wins.
  RommDownloadError? get lastError => _lastError;

  // ── Running ────────────────────────────────────────────────────────────────

  /// Enumerates [fetchPage]'s full result set, drops what [isDownloaded]
  /// reports as already local, and runs the rest through [download] with at
  /// most [concurrency] transfers in flight.
  ///
  /// Each ROM found on disk is handed to [resolveLink], which matches it to
  /// its RomM entry without writing anything; the matches are written by
  /// [writeLinks] *after* the plan is approved, so declining the confirmation
  /// leaves the mapping table exactly as it was. Without them on-disk ROMs are
  /// only counted as [skipped].
  ///
  /// [cancelDownload] is invoked for each in-flight ROM when [cancel] is
  /// called, so cancelling stops the transfers as well as the queue.
  ///
  /// When [confirm] is given it is asked to approve the queue once its size is
  /// known — after the enumeration, before the first byte is fetched — with the
  /// per-volume breakdown [destination] resolves folded into the plan.
  /// Returning false ends the run with [declined] set and nothing downloaded.
  /// Without [confirm] the queue runs unconditionally (the enumeration is still
  /// the only thing that knows the size, so the check simply doesn't happen).
  ///
  /// Never throws: a failure to enumerate ends the sync with [lastError] set,
  /// and a failing ROM is counted and stepped over. Returns when the queue is
  /// drained (or abandoned).
  ///
  /// No-op while another sync is running — one at a time, by design.
  Future<void> run({
    required String sourceLabel,
    required RommPageFetcher fetchPage,
    required RommDownloadedCheck isDownloaded,
    required RommRomDownloader download,
    RommLocalLinkResolver? resolveLink,
    RommLocalLinkWriter? writeLinks,
    void Function(int romId)? cancelDownload,
    RommBulkSyncConfirm? confirm,
    RommDestinationProbe? destination,
    int concurrency = defaultConcurrency,
    int pageSize = defaultPageSize,
  }) async {
    if (isRunning) return;

    _reset();
    _sourceLabel = sourceLabel;
    _phase = RommBulkSyncPhase.preparing;
    _notify();

    try {
      await _enumerate(fetchPage, isDownloaded, resolveLink, pageSize);
      // A cancel during the enumeration stops everything, links included:
      // nothing has been written yet, which is the point.
      if (_cancelRequested) return;
      if (_queue.isEmpty) {
        // Nothing to download means no confirmation is asked for — there is no
        // size to approve — so the links the user's sync found are written
        // straight away. They are the only work this run has.
        await _writeLinks(writeLinks);
        return;
      }

      if (confirm != null) {
        _phase = RommBulkSyncPhase.confirming;
        _notify();
        final plan = await _plan(destination, concurrency);
        // Resolving destinations touches the disk, so a cancel can land while
        // it runs; asking the user to approve a sync they just called off would
        // be a dialog with no right answer.
        if (_cancelRequested) return;
        final approved = await confirm(plan);
        // A cancel landing while the dialog was up stays a cancel: it is the
        // stronger statement, and the outcome toast reads better for it.
        if (_cancelRequested) return;
        if (!approved) {
          _declined = true;
          return;
        }
      }

      // Approved (or never asked): now the rows go in.
      await _writeLinks(writeLinks);
      if (_cancelRequested) return;

      _phase = RommBulkSyncPhase.downloading;
      _notify();
      await _drain(download, cancelDownload, concurrency);
    } finally {
      _activeRomIds.clear();
      _phase = RommBulkSyncPhase.idle;
      _notify();
    }
  }

  /// Asks the sync to stop: the queue stops handing out work and every transfer
  /// in flight is cancelled. Whatever has already landed stays on disk.
  void cancel() {
    if (!isRunning || _cancelRequested) return;
    _cancelRequested = true;
    // Reach the transfers themselves, not just the queue — otherwise cancelling
    // would leave the user waiting on up to [concurrency] multi-GB ROMs.
    final cancelDownload = _cancelDownload;
    if (cancelDownload != null) {
      for (final id in _activeRomIds.toList()) {
        cancelDownload(id);
      }
    }
    _notify();
  }

  /// Per-ROM cancel hook for the run in progress (null while idle).
  void Function(int romId)? _cancelDownload;

  /// Clears the counters from the last run so the UI can dismiss its summary.
  /// No-op while a sync is running.
  void clear() {
    if (isRunning) return;
    _reset();
    _notify();
  }

  /// Prices the queue and measures where it will land, for the confirmation.
  ///
  /// The queue is split by destination volume and each share priced against
  /// that volume's free space, because that is the question that actually
  /// decides whether a sync fits: a queue spread over internal storage and an
  /// SD card can fail on one while the other has room to spare.
  ///
  /// The probe is best-effort by contract: anything it throws leaves that ROM
  /// unassigned, which the plan treats as "nothing known about it" rather than
  /// as a failure.
  Future<RommBulkSyncPlan> _plan(
    RommDestinationProbe? destination,
    int concurrency,
  ) async {
    // Insertion-ordered, so the volumes are reported in the order the queue
    // first reaches them rather than in hash order.
    final byVolume = <String, List<RommRom>>{};
    final freeByVolume = <String, int?>{};
    var unresolved = 0;

    if (destination != null) {
      for (final rom in _queue) {
        if (_cancelRequested) break;
        RommSyncDestination? dest;
        try {
          dest = await destination(rom);
        } catch (e) {
          _log.w('RomM bulk sync: destination probe failed for ${rom.id}: $e');
        }
        if (dest == null) {
          unresolved++;
          continue;
        }
        byVolume.putIfAbsent(dest.volume, () => []).add(rom);
        freeByVolume[dest.volume] = dest.freeBytes;
      }
    } else {
      unresolved = _queue.length;
    }

    final volumes = <RommBulkSyncVolumePlan>[];
    for (final entry in byVolume.entries) {
      final bytes = entry.value.fold<int>(0, (sum, r) => sum + r.fsSizeBytes);
      volumes.add(
        RommBulkSyncVolumePlan(
          volume: entry.key,
          romCount: entry.value.length,
          downloadBytes: bytes,
          requiredBytes: bytes + _headroomFor(entry.value, concurrency),
          freeBytes: freeByVolume[entry.key],
        ),
      );
    }

    return RommBulkSyncPlan(
      sourceLabel: _sourceLabel,
      romCount: _queue.length,
      skipped: _skipped,
      linked: _pendingLinks.length,
      alreadyLinked: _alreadyLinked,
      downloadBytes: _queuedBytes,
      requiredBytes: _queuedBytes + transientHeadroomBytes(concurrency),
      volumes: volumes,
      unresolvedRoms: unresolved,
    );
  }

  /// Extra bytes the queue needs on top of its download size, at its peak.
  ///
  /// A multi-disc ROM arrives as a zip that is unpacked beside itself and only
  /// then deleted, so while it is being extracted it occupies roughly twice
  /// its size. That doubling is transient and per ROM, not a property of the
  /// whole queue: at most [concurrency] of them overlap, so the peak overshoot
  /// is the sum of the largest that many multi-disc ROMs. Doubling the whole
  /// queue instead would refuse syncs that fit comfortably.
  @visibleForTesting
  int transientHeadroomBytes(int concurrency) =>
      _headroomFor(_queue, concurrency);

  /// [transientHeadroomBytes] over an arbitrary slice of the queue, so each
  /// volume can be given its own share.
  ///
  /// Applied per volume this is deliberately conservative: the workers are
  /// shared across the whole queue, so all [concurrency] of them can only
  /// overlap on one volume at a time, yet each volume reserves as if they might.
  /// Which way to be wrong is a real choice, and over-reserving a few gigabytes
  /// on a check that only ever warns is the harmless one.
  int _headroomFor(List<RommRom> roms, int concurrency) {
    final workers = concurrency < 1 ? 1 : concurrency;
    final sizes = [
      for (final rom in roms)
        if (rom.isMultiFile) rom.fsSizeBytes,
    ]..sort((a, b) => b.compareTo(a));
    var extra = 0;
    for (var i = 0; i < sizes.length && i < workers; i++) {
      extra += sizes[i];
    }
    return extra;
  }

  void _reset() {
    _cancelRequested = false;
    _declined = false;
    _sourceLabel = '';
    _enumerated = 0;
    _enumerateTotal = 0;
    _queue.clear();
    _pendingLinks.clear();
    _completed = 0;
    _failed = 0;
    _skipped = 0;
    _linked = 0;
    _alreadyLinked = 0;
    _linkFailures = 0;
    _cancelled = 0;
    _doneBytes = 0;
    _queuedBytes = 0;
    _activeRomIds.clear();
    _lastError = null;
  }

  /// Matches one on-disk ROM to its RomM entry, without writing.
  ///
  /// A resolver failure is logged and counted as [linkFailed], never as
  /// [alreadyLinked]: the sync is about downloads first, and a mapping that
  /// couldn't be made now is picked up by the next connect-time link pass.
  Future<void> _resolveLink(RommLocalLinkResolver resolve, RommRom rom) async {
    try {
      final pending = await resolve(rom);
      if (pending == null) return;
      if (pending.alreadyLinked) {
        _alreadyLinked++;
        return;
      }
      _pendingLinks.add(pending);
    } catch (e) {
      _linkFailures++;
      _log.e(
        'RomM bulk sync: matching ${rom.fsName} (rom ${rom.id}) failed: $e',
      );
    }
  }

  /// Writes the matches the plan was approved with, in one call to the writer
  /// rather than one transaction per ROM.
  ///
  /// A row that appeared between the match and the write (a download that
  /// finished, another device's sync) is counted as already linked, which is
  /// what it is; a write that failed is counted as [linkFailed], never as
  /// already linked.
  Future<void> _writeLinks(RommLocalLinkWriter? writeLinks) async {
    if (writeLinks == null || _pendingLinks.isEmpty) return;
    final pending = List<RommPendingLink>.unmodifiable(_pendingLinks);
    try {
      final result = await writeLinks(pending);
      _linked += result.written;
      _linkFailures += result.failed;
      _alreadyLinked += pending.length - result.written - result.failed;
    } catch (e) {
      _linkFailures += pending.length;
      _log.e('RomM bulk sync: writing ${pending.length} link(s) failed: $e');
    }
    _notify();
  }

  /// Pages the whole source into [_queue], skipping ROMs already on disk.
  ///
  /// Filtering per page (rather than collecting everything and filtering after)
  /// keeps the queue and its byte total growing while the pass runs, so the
  /// progress UI has something truthful to show on a large platform.
  ///
  /// A ROM that is already on disk is the one case where the sync has work
  /// that isn't a download: the file predates RomM (or was copied over by
  /// hand) and has no mapping row, so save sync and the cloud badge can't see
  /// it. [resolveLink] matches it here and the row is written after the
  /// confirmation; the ROM is never queued either way.
  Future<void> _enumerate(
    RommPageFetcher fetchPage,
    RommDownloadedCheck isDownloaded,
    RommLocalLinkResolver? resolveLink,
    int pageSize,
  ) async {
    var offset = 0;
    for (var page = 0; page < maxPages; page++) {
      if (_cancelRequested) return;

      final RommRomPage result;
      try {
        result = await fetchPage(limit: pageSize, offset: offset);
      } catch (e) {
        _log.e('RomM bulk sync: enumeration failed at offset $offset: $e');
        _lastError = RommDownloadError.network;
        return;
      }

      // RomM reports the match count for the whole query, which is the only
      // honest denominator while paging.
      if (result.total > 0) _enumerateTotal = result.total;

      for (final rom in result.items) {
        if (_cancelRequested) return;
        _enumerated++;
        if (await isDownloaded(rom)) {
          _skipped++;
          if (resolveLink != null) await _resolveLink(resolveLink, rom);
        } else {
          _queue.add(rom);
          _queuedBytes += rom.fsSizeBytes;
        }
      }
      _notify();

      offset += result.items.length;
      // A short page is the end of the results. An empty one also guards the
      // pathological case of a server that ignores the offset.
      if (result.items.length < pageSize) return;
      if (_enumerateTotal > 0 && offset >= _enumerateTotal) return;
    }
    _log.w(
      'RomM bulk sync: enumeration hit the $maxPages-page cap for '
      '"$_sourceLabel" — syncing the ${_queue.length} ROMs found so far',
    );
  }

  /// Runs the queue through [concurrency] workers.
  ///
  /// The workers share a cursor rather than being handed fixed slices, so a
  /// worker stuck on a 4 GB disc image doesn't leave its share of the small
  /// ROMs waiting behind it. Dart's single-threaded event loop makes the
  /// cursor increment safe without a lock.
  Future<void> _drain(
    RommRomDownloader download,
    void Function(int romId)? cancelDownload,
    int concurrency,
  ) async {
    var cursor = 0;
    final workers = concurrency < 1 ? 1 : concurrency;

    Future<void> worker() async {
      while (true) {
        if (_cancelRequested || cursor >= _queue.length) return;
        final rom = _queue[cursor++];

        // Registering the id and starting the transfer happen in one
        // synchronous run, so [cancel] can never land between them and miss a
        // download that has no tracker yet.
        _activeRomIds.add(rom.id);
        _notify();
        try {
          final result = await download(rom);
          switch (result.status) {
            case RommDownloadStatus.completed:
              _completed++;
              _doneBytes += rom.fsSizeBytes;
              break;
            case RommDownloadStatus.cancelled:
              _cancelled++;
              break;
            case RommDownloadStatus.failed:
            case RommDownloadStatus.downloading:
              // `downloading` shouldn't reach here — downloadRom resolves only
              // on a terminal state — but treating an unfinished transfer as a
              // success would overstate what landed on disk.
              _failed++;
              if (result.error != RommDownloadError.none) {
                _lastError = result.error;
              }
              break;
          }
        } catch (e) {
          // downloadRom reports failures through the record rather than
          // throwing, so this is belt-and-braces: one bad ROM must not abandon
          // the rest of the queue.
          _log.e('RomM bulk sync: ${rom.fsName} threw: $e');
          _failed++;
          _lastError = RommDownloadError.network;
        } finally {
          _activeRomIds.remove(rom.id);
          _notify();
        }
      }
    }

    _cancelDownload = cancelDownload;
    try {
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    } finally {
      _cancelDownload = null;
      // Anything never handed out was abandoned by the cancel.
      if (_cancelRequested && cursor < _queue.length) {
        _cancelled += _queue.length - cursor;
      }
    }
  }
}
