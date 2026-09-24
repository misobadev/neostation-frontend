import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/providers/romm_provider.dart';

/// Covers the bulk-sync engine: enumeration paging, the already-downloaded
/// filter, the bounded worker pool, and cancellation.
///
/// [RommBulkSync.run] takes its server/disk access as callbacks precisely so
/// this can be exercised without a RomM server or a filesystem — the fakes
/// below stand in for `getRomsPage`, `isDownloadedCached` and `downloadRom`.

RommRom _rom(
  int id, {
  int sizeBytes = 0,
  bool multiFile = false,
  int platformId = 1,
}) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: platformId,
  platformSlug: 'snes',
  fsName: 'game$id.sfc',
  fsNameNoExt: 'game$id',
  fsExtension: 'sfc',
  fsSizeBytes: sizeBytes,
  hasMultipleFiles: multiFile,
);

RommDownload _completed(RommRom rom) =>
    RommDownload(romId: rom.id, status: RommDownloadStatus.completed);

RommDownload _failed(
  RommRom rom, [
  RommDownloadError error = RommDownloadError.network,
]) => RommDownload(
  romId: rom.id,
  status: RommDownloadStatus.failed,
  error: error,
);

/// A local file matched to [rom], as the enumeration hands it on — matched
/// only, never written.
RommPendingLink _pending(RommRom rom, {bool alreadyLinked = false}) =>
    RommPendingLink(
      rom: rom,
      romname: rom.fsNameNoExt,
      alreadyLinked: alreadyLinked,
    );

/// Stands in for the mapping write: records every call and writes every match
/// it is given, so a test can assert both *when* it ran and how often.
class _FakeLinkWriter {
  final List<List<RommPendingLink>> calls = [];

  Future<RommLinkWriteResult> write(List<RommPendingLink> pending) async {
    calls.add(pending);
    return (written: pending.length, failed: 0);
  }

  /// Every match written across every call.
  int get written => calls.fold(0, (sum, c) => sum + c.length);
}

/// A page fetcher over a fixed ROM list, honouring limit/offset the way RomM
/// does (and reporting the full match count as `total`).
RommPageFetcher _pagesOver(List<RommRom> all, {List<int>? requestedOffsets}) {
  return ({required int limit, required int offset}) async {
    requestedOffsets?.add(offset);
    final end = (offset + limit).clamp(0, all.length);
    return RommRomPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      total: all.length,
    );
  };
}

Future<bool> _nothingDownloaded(RommRom _) async => false;

/// A destination probe putting every ROM on one volume with [freeBytes] left.
RommDestinationProbe _oneVolume(int? freeBytes, {String volume = '/storage'}) =>
    (_) async => RommSyncDestination(volume: volume, freeBytes: freeBytes);

/// A destination probe that reads its answer from a per-platform map, so a
/// queue can be spread across volumes the way a multi-system sync really is.
/// A platform missing from the map resolves to nothing.
RommDestinationProbe _volumeByPlatform(
  Map<int, RommSyncDestination> byPlatform,
) =>
    (rom) async => byPlatform[rom.platformId];

void main() {
  group('enumeration', () {
    test('pages the whole source and queues every ROM', () async {
      final all = [for (var i = 0; i < 25; i++) _rom(i)];
      final offsets = <int>[];
      final downloaded = <int>[];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all, requestedOffsets: offsets),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloaded.add(rom.id);
          return _completed(rom);
        },
        pageSize: 10,
        concurrency: 1,
      );

      expect(offsets, [0, 10, 20]);
      expect(downloaded.length, 25);
      expect(sync.completed, 25);
      expect(sync.total, 25);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });

    test('stops once the server-reported total is reached', () async {
      // A page that comes back exactly full at the end of the results must not
      // trigger another request.
      final all = [for (var i = 0; i < 20; i++) _rom(i)];
      final offsets = <int>[];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all, requestedOffsets: offsets),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        pageSize: 10,
        concurrency: 1,
      );

      expect(offsets, [0, 10]);
      expect(sync.completed, 20);
    });

    test('ROMs already on disk are linked and skipped, not queued', () async {
      final all = [for (var i = 0; i < 6; i++) _rom(i)];
      final downloaded = <int>[];
      final matched = <int>[];
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id.isEven,
        // Rom 0 already had a row; the other two on-disk ROMs gain one.
        resolveLink: (rom) async {
          matched.add(rom.id);
          return _pending(rom, alreadyLinked: rom.id == 0);
        },
        writeLinks: writer.write,
        download: (rom) async {
          downloaded.add(rom.id);
          return _completed(rom);
        },
        concurrency: 1,
      );

      expect(downloaded, [1, 3, 5]);
      expect(matched, [
        0,
        2,
        4,
      ], reason: 'every on-disk ROM is offered a link, nothing else is');
      expect(sync.skipped, 3);
      expect(sync.linked, 2);
      expect(sync.alreadyLinked, 1);
      expect(sync.total, 3);
      expect(sync.enumerated, 6);
    });

    test('a linked ROM is never downloaded and fetches no media', () async {
      // The engine only ever reaches the outside world through the callbacks
      // it is given: `download` is the sole path to a transfer and to the
      // metadata/media import that rides on it. A ROM that links must not
      // reach it, and the linker itself is handed nothing to fetch with.
      final all = [_rom(1, sizeBytes: 500)];
      var downloads = 0;
      var links = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async {
          links++;
          return _pending(rom);
        },
        writeLinks: _FakeLinkWriter().write,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
        concurrency: 1,
      );

      expect(links, 1);
      expect(downloads, 0);
      expect(sync.total, 0, reason: 'not queued');
      expect(sync.totalBytes, 0, reason: 'nothing priced for transfer');
      expect(sync.linked, 1);
      expect(sync.skipped, 1);
    });

    test(
      'without a linker, on-disk ROMs are only counted as skipped',
      () async {
        final all = [_rom(1), _rom(2)];
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: (_) async => true,
          download: (rom) async => _completed(rom),
          concurrency: 1,
        );

        expect(sync.skipped, 2);
        expect(sync.linked, 0);
        expect(sync.alreadyLinked, 0);
      },
    );

    test(
      'a matcher that throws is logged and does not stop the sync',
      () async {
        final all = [_rom(1), _rom(2), _rom(3)];
        final downloaded = <int>[];
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: (rom) async => rom.id == 2,
          resolveLink: (_) async => throw StateError('db closed'),
          writeLinks: _FakeLinkWriter().write,
          download: (rom) async {
            downloaded.add(rom.id);
            return _completed(rom);
          },
          concurrency: 1,
        );

        expect(downloaded, [1, 3]);
        expect(sync.skipped, 1);
        expect(sync.linked, 0);
        expect(
          sync.alreadyLinked,
          0,
          reason: 'a failure is never booked as already linked',
        );
        expect(sync.linkFailed, 1);
      },
    );

    test('a write that fails is counted apart from already linked', () async {
      final all = [_rom(1), _rom(2)];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: (pending) async => (written: 0, failed: pending.length),
        download: (rom) async => _completed(rom),
        concurrency: 1,
      );

      expect(sync.linked, 0);
      expect(sync.alreadyLinked, 0);
      expect(sync.linkFailed, 2);
    });

    test('a row that appeared meanwhile counts as already linked', () async {
      final all = [_rom(1), _rom(2)];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async => _pending(rom),
        // The insert-if-absent write skipped one row: something else had
        // written it between the match and the write.
        writeLinks: (_) async => (written: 1, failed: 0),
        download: (rom) async => _completed(rom),
        concurrency: 1,
      );

      expect(sync.linked, 1);
      expect(sync.alreadyLinked, 1);
      expect(sync.linkFailed, 0);
    });

    // The confirmation offers the links as part of what the user is agreeing
    // to ("{count} linked to RomM"), so they must not already be written when
    // the question is asked — and declining must leave the table untouched.
    test('nothing is written before the plan is approved', () async {
      final all = [_rom(1), _rom(2), _rom(3)];
      final writer = _FakeLinkWriter();
      var writtenAtConfirm = -1;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id != 3,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (plan) async {
          writtenAtConfirm = writer.written;
          expect(plan.linked, 2, reason: 'the plan proposes two links');
          return true;
        },
        concurrency: 1,
      );

      expect(
        writtenAtConfirm,
        0,
        reason: 'the dialog proposed, it did not report',
      );
      expect(writer.written, 2, reason: 'written once approved');
      expect(sync.linked, 2);
    });

    test('declining the plan writes no link at all', () async {
      final all = [_rom(1), _rom(2), _rom(3)];
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id != 3,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (_) async => false,
        concurrency: 1,
      );

      expect(sync.declined, isTrue);
      expect(writer.calls, isEmpty, reason: 'the user said no');
      expect(sync.linked, 0);
    });

    test('a cancel during enumeration writes no link', () async {
      final all = [_rom(1), _rom(2)];
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async {
          sync.cancel();
          return _pending(rom);
        },
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (_) async => true,
        concurrency: 1,
      );

      expect(sync.cancelRequested, isTrue);
      expect(writer.calls, isEmpty);
      expect(sync.linked, 0);
    });

    // Inverted, with its reasoning. It used to assert the links were written
    // straight through on the grounds that there was no size to approve — but
    // the size was never the only thing being approved. A mapping row is the
    // gate for save sync, so syncing a platform already held entirely would
    // enrol every ROM on it with no dialog and no cancel. It was the one path
    // that wrote rows with no preview at all.
    test('with nothing to download the links are still confirmed', () async {
      final all = [_rom(1), _rom(2)];
      final writer = _FakeLinkWriter();
      var confirmed = false;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (_) async {
          confirmed = true;
          return true;
        },
        concurrency: 1,
      );

      expect(
        confirmed,
        isTrue,
        reason: 'rows that gate save sync are a proposal, not a side effect',
      );
      expect(sync.linked, 2);
    });

    test('with nothing to download, declining writes nothing', () async {
      // The half that matters. Asking is only worth anything if "no" is
      // honoured, and a row written here would have enrolled the game for save
      // sync on the strength of a dialog the user rejected.
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver([_rom(1), _rom(2)]),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (_) async => false,
        concurrency: 1,
      );

      expect(writer.calls, isEmpty);
      expect(sync.linked, 0);
      expect(sync.declined, isTrue);
    });

    // One transaction per ROM in the phase the confirmation is waiting on is
    // what the library link pass already avoids by batching.
    test('every approved link is written in one call', () async {
      final all = [for (var i = 0; i < 25; i++) _rom(i)];
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id != 24,
        resolveLink: (rom) async => _pending(rom),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        confirm: (_) async => true,
        concurrency: 1,
      );

      expect(writer.calls, hasLength(1), reason: '24 matches, one write');
      expect(writer.calls.single, hasLength(24));
      expect(sync.linked, 24);
    });

    test('already-linked matches are never handed to the writer', () async {
      final all = [_rom(1), _rom(2), _rom(3)];
      final writer = _FakeLinkWriter();
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        resolveLink: (rom) async => _pending(rom, alreadyLinked: rom.id != 2),
        writeLinks: writer.write,
        download: (rom) async => _completed(rom),
        concurrency: 1,
      );

      expect(writer.calls.single.map((m) => m.rom.id), [2]);
      expect(sync.linked, 1);
      expect(sync.alreadyLinked, 2);
    });

    test('the plan carries the linked counts', () async {
      final all = [_rom(1), _rom(2), _rom(3)];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id != 3,
        resolveLink: (rom) async => _pending(rom, alreadyLinked: rom.id != 1),
        writeLinks: _FakeLinkWriter().write,
        download: (rom) async => _completed(rom),
        confirm: (plan) async {
          seen = plan;
          return true;
        },
        concurrency: 1,
      );

      expect(seen, isNotNull);
      expect(seen!.skipped, 2);
      expect(seen!.linked, 1);
      expect(seen!.alreadyLinked, 1);
      expect(seen!.romCount, 1);
    });

    test('queued bytes count only what is actually downloaded', () async {
      final all = [
        _rom(1, sizeBytes: 100),
        _rom(2, sizeBytes: 200), // already local
        _rom(3, sizeBytes: 300),
      ];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id == 2,
        download: (rom) async => rom.id == 3 ? _failed(rom) : _completed(rom),
        concurrency: 1,
      );

      expect(sync.totalBytes, 400, reason: 'the skipped ROM is not queued');
      expect(sync.doneBytes, 100, reason: 'only the successful ROM counts');
    });

    test('an enumeration failure ends the sync without downloading', () async {
      var downloads = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required int limit, required int offset}) async {
          throw StateError('server down');
        },
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
      );

      expect(downloads, 0);
      expect(sync.lastError, RommDownloadError.network);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });
  });

  group('worker pool', () {
    test('never exceeds the concurrency cap', () async {
      final all = [for (var i = 0; i < 12; i++) _rom(i)];
      final gates = <int, Completer<void>>{};
      var inFlight = 0;
      var peak = 0;
      final sync = RommBulkSync();

      final run = sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          final gate = gates[rom.id] = Completer<void>();
          await gate.future;
          inFlight--;
          return _completed(rom);
        },
        concurrency: 3,
      );

      // Release transfers one at a time; each completion should let exactly one
      // more start, holding the pool at its cap.
      for (var released = 0; released < all.length; released++) {
        await pumpEventQueue();
        expect(inFlight, lessThanOrEqualTo(3));
        final pending = gates.values.where((g) => !g.isCompleted).toList();
        expect(pending, isNotEmpty);
        pending.first.complete();
      }
      await run;

      expect(peak, 3);
      expect(sync.completed, 12);
    });

    test('a failing ROM is counted and the queue carries on', () async {
      final all = [for (var i = 0; i < 5; i++) _rom(i)];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => rom.id == 2
            ? _failed(rom, RommDownloadError.noWritableFolder)
            : _completed(rom),
        concurrency: 2,
      );

      expect(sync.completed, 4);
      expect(sync.failed, 1);
      expect(sync.lastError, RommDownloadError.noWritableFolder);
      expect(sync.finished, 5);
    });

    test(
      'a download that throws does not abandon the rest of the queue',
      () async {
        final all = [for (var i = 0; i < 5; i++) _rom(i)];
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async {
            if (rom.id == 1) throw StateError('disk exploded');
            return _completed(rom);
          },
          concurrency: 1,
        );

        expect(sync.completed, 4);
        expect(sync.failed, 1);
      },
    );

    test('a second run is a no-op while one is in flight', () async {
      final all = [for (var i = 0; i < 3; i++) _rom(i)];
      final gate = Completer<void>();
      var starts = 0;
      final sync = RommBulkSync();

      final first = sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          starts++;
          await gate.future;
          return _completed(rom);
        },
        concurrency: 1,
      );
      await pumpEventQueue();

      await sync.run(
        sourceLabel: 'Mega Drive',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
      );
      expect(sync.sourceLabel, 'SNES', reason: 'the running sync is untouched');

      gate.complete();
      await first;
      expect(starts, 3);
    });
  });

  _writeProbeTests();

  _preflightTests();

  _renderedPercentTests();

  group('cancellation', () {
    test(
      'stops handing out work and cancels the transfers in flight',
      () async {
        final all = [for (var i = 0; i < 10; i++) _rom(i)];
        final gates = <int, Completer<void>>{};
        final cancelledIds = <int>[];
        var started = 0;
        final sync = RommBulkSync();

        final run = sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async {
            started++;
            final gate = gates[rom.id] = Completer<void>();
            await gate.future;
            // Mirrors the real downloader: a cancelled transfer resolves to a
            // cancelled record rather than throwing.
            return RommDownload(
              romId: rom.id,
              status: cancelledIds.contains(rom.id)
                  ? RommDownloadStatus.cancelled
                  : RommDownloadStatus.completed,
            );
          },
          cancelDownload: cancelledIds.add,
          concurrency: 2,
        );
        await pumpEventQueue();
        expect(started, 2);

        sync.cancel();
        expect(sync.cancelRequested, isTrue);
        expect(
          cancelledIds..sort(),
          [0, 1],
          reason:
              'the two in-flight transfers are cancelled, not just the queue',
        );

        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await run;

        expect(started, 2, reason: 'no further ROMs were handed out');
        expect(
          sync.cancelled,
          10,
          reason: '2 abandoned in flight + 8 never started',
        );
        expect(sync.completed, 0);
        expect(sync.phase, RommBulkSyncPhase.idle);
      },
    );

    test('cancelling during enumeration never reaches the queue', () async {
      final all = [for (var i = 0; i < 100; i++) _rom(i)];
      var downloads = 0;
      final sync = RommBulkSync();
      late final RommBulkSync self;
      self = sync;

      final run = sync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required int limit, required int offset}) async {
          // Cancel as soon as the first page is being served.
          Future.microtask(self.cancel);
          final end = (offset + limit).clamp(0, all.length);
          return RommRomPage(
            items: all.sublist(offset, end),
            total: all.length,
          );
        },
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
        pageSize: 10,
      );
      await run;

      expect(downloads, 0);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });

    test('cancel is a no-op when nothing is running', () {
      final sync = RommBulkSync();
      sync.cancel();
      expect(sync.cancelRequested, isFalse);
      expect(sync.isRunning, isFalse);
    });
  });
}

/// Regression: a bulk sync resolves destinations for several ROMs of the same
/// system at once, and the writability probe used to be a single shared
/// filename. Concurrent probes then deleted each other's file, the loser's
/// delete threw, and the folder was reported unwritable — ROMs failed with
/// "no writable folder" on a bulk sync and then downloaded fine on a retry.
void _writeProbeTests() {
  group('dirIfWritable', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('romm_probe_test');
    });
    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    test('concurrent probes of the same directory all succeed', () async {
      final target = p.join(temp.path, 'msx');
      final results = await Future.wait([
        for (var i = 0; i < 8; i++) RommProvider.dirIfWritable(target),
      ]);

      expect(
        results.where((r) => r == null),
        isEmpty,
        reason: 'every concurrent probe must see the folder as writable',
      );
      expect(results.every((r) => r == target), isTrue);
    });

    test('leaves no probe files behind', () async {
      final target = p.join(temp.path, 'snes');
      await Future.wait([
        for (var i = 0; i < 8; i++) RommProvider.dirIfWritable(target),
      ]);

      final leftovers = Directory(target)
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('.romm_write_test'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('an unwritable destination still reports null', () async {
      // A path whose parent is a *file* can never be created as a directory.
      final blocker = File(p.join(temp.path, 'blocker'))..writeAsStringSync('');
      expect(
        await RommProvider.dirIfWritable(p.join(blocker.path, 'sub')),
        isNull,
      );
    });
  });

  /// The pre-flight has to name a destination *before* the user has agreed to
  /// the sync, so unlike the download path it must not create one.
  group('plannedDestDir', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('romm_planned_test');
    });
    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    SystemModel system(String folderName, {List<String> folders = const []}) =>
        SystemModel(
          folderName: folderName,
          realName: folderName.toUpperCase(),
          iconImage: '',
          color: '#000000',
          folders: folders,
        );

    test('names the canonical folder without creating it', () async {
      final planned = await RommProvider().plannedDestDir(system('snes'), [
        temp.path,
      ]);

      expect(planned, p.join(temp.path, 'snes'));
      expect(
        Directory(planned!).existsSync(),
        isFalse,
        reason: 'a declined plan must not leave folders for the scan to index',
      );
      expect(
        temp.listSync(),
        isEmpty,
        reason: 'and no probe file in the ROM folder either',
      );
    });

    test('prefers an existing folder under any alias', () async {
      // Sega CD is indexed under both names; a sync must be priced against the
      // folder the download will actually reuse.
      final existing = Directory(p.join(temp.path, 'segacd'))
        ..createSync(recursive: true);

      final planned = await RommProvider().plannedDestDir(
        system('scd', folders: ['segacd']),
        [temp.path],
      );

      expect(planned, existing.path);
    });

    test('falls through a ROM folder it cannot write to', () async {
      final blocked = File(p.join(temp.path, 'blocked'))..writeAsStringSync('');
      final usable = Directory(p.join(temp.path, 'usable'))
        ..createSync(recursive: true);

      final planned = await RommProvider().plannedDestDir(system('nes'), [
        blocked.path,
        usable.path,
      ]);

      expect(planned, p.join(usable.path, 'nes'));
    });

    test('reports nothing when no ROM folder is usable', () async {
      final blocked = File(p.join(temp.path, 'blocked'))..writeAsStringSync('');
      expect(
        await RommProvider().plannedDestDir(system('nes'), [blocked.path]),
        isNull,
      );
    });
  });
}

/// The pre-flight check: the queue is priced and the destination measured
/// *after* the enumeration, then put to the user before a byte is fetched.
void _preflightTests() {
  group('pre-flight confirmation', () {
    test('prices the queue and reports free space', () async {
      final all = [
        for (var i = 0; i < 4; i++) _rom(i, sizeBytes: 1000),
        _rom(99, sizeBytes: 500),
      ];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        // The last ROM is already on disk, so it is priced out of the plan.
        isDownloaded: (rom) async => rom.id == 99,
        download: (rom) async => _completed(rom),
        destination: _oneVolume(10000),
        confirm: (plan) async {
          seen = plan;
          return true;
        },
        concurrency: 1,
      );

      expect(seen, isNotNull);
      expect(seen!.sourceLabel, 'SNES');
      expect(seen!.romCount, 4);
      expect(seen!.skipped, 1);
      expect(seen!.downloadBytes, 4000);
      expect(seen!.requiredBytes, 4000, reason: 'no multi-disc ROMs to unpack');
      expect(seen!.freeBytes, 10000);
      expect(seen!.fits, isTrue);
      expect(seen!.spaceUnknown, isFalse);
      expect(seen!.volumes.single.romCount, 4);
      expect(seen!.unresolvedRoms, 0);
      expect(sync.completed, 4, reason: 'approving runs the queue');
    });

    test('declining downloads nothing and is not a cancellation', () async {
      final all = [for (var i = 0; i < 5; i++) _rom(i, sizeBytes: 1000)];
      var downloads = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
        confirm: (_) async => false,
      );

      expect(downloads, 0);
      expect(sync.declined, isTrue);
      expect(sync.cancelRequested, isFalse);
      expect(sync.completed, 0);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });

    test('is never asked when everything is already on disk', () async {
      final all = [for (var i = 0; i < 5; i++) _rom(i, sizeBytes: 1000)];
      var asked = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (_) async => true,
        download: (rom) async => _completed(rom),
        confirm: (_) async {
          asked++;
          return true;
        },
      );

      expect(asked, 0, reason: 'an empty queue has nothing to confirm');
      expect(sync.skipped, 5);
      expect(sync.declined, isFalse);
    });

    test('an unmeasurable volume fits by default', () async {
      final all = [for (var i = 0; i < 3; i++) _rom(i, sizeBytes: 1 << 30)];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        destination: _oneVolume(null),
        confirm: (plan) async {
          seen = plan;
          return true;
        },
      );

      expect(seen!.spaceUnknown, isTrue);
      expect(seen!.fits, isTrue, reason: 'a missing number must not obstruct');
      expect(seen!.shortfallBytes, 0);
      expect(
        seen!.volumes.single.downloadBytes,
        3 << 30,
        reason: 'an unmeasurable volume is still a known destination',
      );
    });

    test('a probe that throws is as good as no probe', () async {
      final all = [_rom(1, sizeBytes: 10)];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        destination: (_) async => throw const FileSystemException('nope'),
        confirm: (plan) async {
          seen = plan;
          return true;
        },
      );

      expect(seen!.spaceUnknown, isTrue);
      expect(seen!.volumes, isEmpty);
      expect(seen!.unresolvedRoms, 1);
      expect(seen!.downloadBytes, 10, reason: 'still priced into the total');
      expect(sync.completed, 1, reason: 'the sync still ran');
    });

    test(
      'a ROM with no resolvable destination is priced, not checked',
      () async {
        // Platform 2 has no local system / no writable folder, so nothing can be
        // said about where its bytes would go.
        final all = [
          _rom(1, sizeBytes: 1000),
          _rom(2, sizeBytes: 4000, platformId: 2),
        ];
        RommBulkSyncPlan? seen;
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'Mixed',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async => _completed(rom),
          destination: _volumeByPlatform({
            1: const RommSyncDestination(volume: '/storage', freeBytes: 2000),
          }),
          confirm: (plan) async {
            seen = plan;
            return true;
          },
        );

        expect(seen!.downloadBytes, 5000);
        expect(seen!.unresolvedRoms, 1);
        expect(seen!.volumes.single.downloadBytes, 1000);
        expect(
          seen!.fits,
          isTrue,
          reason:
              'the 4000 that cannot be placed cannot be held against /storage',
        );
      },
    );

    test('reports the shortfall when the queue does not fit', () async {
      final all = [for (var i = 0; i < 3; i++) _rom(i, sizeBytes: 1000)];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        destination: _oneVolume(2500),
        confirm: (plan) async {
          seen = plan;
          // Warned, not refused — the caller still decides.
          return false;
        },
      );

      expect(seen!.fits, isFalse);
      expect(seen!.shortfallBytes, 500);
      expect(sync.declined, isTrue);
    });

    test(
      'each volume is checked against its own share, not the roomiest',
      () async {
        // The regression this replaced: reporting the roomiest ROM folder let a
        // queue "fit" because *somewhere* had room. Platform 1's 3000 bytes go to
        // a volume with 1000 free; platform 2's 1000 go to one with 500k free.
        // The total (4000) fits in the roomiest volume, and the sync still can't
        // run as planned.
        final all = [
          _rom(1, sizeBytes: 3000),
          _rom(2, sizeBytes: 1000, platformId: 2),
        ];
        RommBulkSyncPlan? seen;
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'Everything',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async => _completed(rom),
          destination: _volumeByPlatform({
            1: const RommSyncDestination(volume: '/internal', freeBytes: 1000),
            2: const RommSyncDestination(volume: '/sdcard', freeBytes: 500000),
          }),
          confirm: (plan) async {
            seen = plan;
            return false;
          },
        );

        expect(seen!.volumes.map((v) => v.volume), ['/internal', '/sdcard']);
        expect(seen!.volumes.first.requiredBytes, 3000);
        expect(seen!.volumes.last.requiredBytes, 1000);
        expect(seen!.fits, isFalse);
        expect(
          seen!.shortfallBytes,
          2000,
          reason: 'the internal volume is short',
        );
        expect(seen!.tightestVolume!.volume, '/internal');
        expect(
          seen!.freeBytes,
          isNull,
          reason: 'no single free-space figure answers for two volumes',
        );
        expect(
          seen!.spaceUnknown,
          isFalse,
          reason: 'both volumes were measured — the plan just does not fit',
        );
      },
    );

    test('ROMs sharing a volume are added together, not checked apart', () async {
      // Two platforms, one volume: 3000 + 3000 against 5000 free is a shortfall
      // even though neither platform on its own would be.
      final all = [
        _rom(1, sizeBytes: 3000),
        _rom(2, sizeBytes: 3000, platformId: 2),
      ];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'Everything',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        destination: _volumeByPlatform({
          1: const RommSyncDestination(volume: '/internal', freeBytes: 5000),
          2: const RommSyncDestination(volume: '/internal', freeBytes: 5000),
        }),
        confirm: (plan) async {
          seen = plan;
          return false;
        },
      );

      expect(seen!.volumes, hasLength(1));
      expect(seen!.volumes.single.romCount, 2);
      expect(seen!.volumes.single.requiredBytes, 6000);
      expect(seen!.shortfallBytes, 1000);
    });

    test(
      'a cancel while destinations resolve skips the confirmation',
      () async {
        final all = [for (var i = 0; i < 3; i++) _rom(i, sizeBytes: 1000)];
        var asked = 0;
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async => _completed(rom),
          destination: (rom) async {
            sync.cancel();
            return const RommSyncDestination(volume: '/storage', freeBytes: 10);
          },
          confirm: (_) async {
            asked++;
            return true;
          },
        );

        expect(asked, 0, reason: 'nothing to approve once it is called off');
        expect(sync.cancelRequested, isTrue);
        expect(sync.completed, 0);
      },
    );

    test('cancelling during the confirmation stays a cancellation', () async {
      final all = [for (var i = 0; i < 3; i++) _rom(i, sizeBytes: 1000)];
      var downloads = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
        confirm: (_) async {
          sync.cancel();
          return true;
        },
      );

      expect(downloads, 0);
      expect(sync.cancelRequested, isTrue);
      expect(sync.declined, isFalse);
    });
  });

  group('transient headroom', () {
    test('single-file queues need nothing beyond their download size', () {
      final sync = RommBulkSync();
      expect(sync.transientHeadroomBytes(3), 0);
    });

    test(
      'a multi-disc ROM is counted twice, but only while it is unpacking',
      () async {
        // 4 multi-disc ROMs, 3 workers: at most 3 zips exist beside their
        // extracted discs at once, so the peak overshoot is the 3 largest.
        final all = [
          _rom(1, sizeBytes: 100, multiFile: true),
          _rom(2, sizeBytes: 400, multiFile: true),
          _rom(3, sizeBytes: 300, multiFile: true),
          _rom(4, sizeBytes: 200, multiFile: true),
          _rom(5, sizeBytes: 50),
        ];
        RommBulkSyncPlan? seen;
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'PS1',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async => _completed(rom),
          confirm: (plan) async {
            seen = plan;
            return false;
          },
          concurrency: 3,
        );

        expect(seen!.downloadBytes, 1050);
        expect(
          seen!.requiredBytes,
          1050 + 400 + 300 + 200,
          reason: 'the three largest multi-disc ROMs, not the whole queue',
        );
      },
    );

    test('the headroom never exceeds what the queue holds', () async {
      final all = [
        _rom(1, sizeBytes: 100, multiFile: true),
        _rom(2, sizeBytes: 100),
      ];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'PS1',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        confirm: (plan) async {
          seen = plan;
          return false;
        },
        // More workers than there are multi-disc ROMs to unpack.
        concurrency: 8,
      );

      expect(seen!.requiredBytes, 300);
    });

    test('each volume reserves headroom for its own multi-disc ROMs', () async {
      final all = [
        _rom(1, sizeBytes: 500, multiFile: true),
        _rom(2, sizeBytes: 100, multiFile: true, platformId: 2),
      ];
      RommBulkSyncPlan? seen;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'PS1 + Saturn',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        destination: _volumeByPlatform({
          1: const RommSyncDestination(volume: '/internal', freeBytes: 100000),
          2: const RommSyncDestination(volume: '/sdcard', freeBytes: 100000),
        }),
        confirm: (plan) async {
          seen = plan;
          return false;
        },
        concurrency: 3,
      );

      // The zip that unpacks on /internal needs no room on /sdcard: 2× the ROM
      // that actually lands there, not 2× the queue.
      expect(seen!.volumes.first.requiredBytes, 1000);
      expect(seen!.volumes.last.requiredBytes, 200);
    });
  });
}

/// The rule behind the download-progress notification gate.
///
/// `RommProvider` notifies its listeners — and so rebuilds the whole browse
/// subtree — once per network chunk unless the tick is filtered. Nothing
/// renders the raw byte count; the card draws a bar and this rounded figure,
/// so chunks that land on the same percent have nothing to say.
void _renderedPercentTests() {
  group('renderedPercent', () {
    test('an unknown content length has no figure to draw', () {
      expect(RommProvider.renderedPercent(null), isNull);
    });

    test('collapses the chunks that round to the same percent', () {
      // Consecutive 8 KB chunks of a 1 GB ROM.
      const total = 1 << 30;
      const chunk = 8 * 1024;
      final percents = <int?>{};
      for (var received = 0; received < total ~/ 100; received += chunk) {
        percents.add(RommProvider.renderedPercent(received / total));
      }
      expect(
        percents.length,
        lessThanOrEqualTo(2),
        reason: 'the first 1% of a 1 GB ROM is ~1300 chunks and one figure',
      );
    });

    test('never leaves the 0–100 range', () {
      expect(RommProvider.renderedPercent(0), 0);
      expect(RommProvider.renderedPercent(1), 100);
      // A server that under-reports content-length would otherwise overshoot.
      expect(RommProvider.renderedPercent(1.4), 100);
      expect(RommProvider.renderedPercent(-0.2), 0);
    });
  });
}
