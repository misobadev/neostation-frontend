import 'package:test/test.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_collection.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';

void main() {
  group('RommPlatform.fromJson', () {
    test('parses a full payload', () {
      final p = RommPlatform.fromJson({
        'id': 12,
        'name': 'Super Nintendo Entertainment System',
        'slug': 'snes',
        'fs_slug': 'snes',
        'rom_count': 42,
        'url_logo': 'https://cdn/igdb/snes.png',
      });
      expect(p.id, 12);
      expect(p.name, 'Super Nintendo Entertainment System');
      expect(p.slug, 'snes');
      expect(p.fsSlug, 'snes');
      expect(p.romCount, 42);
      expect(p.urlLogo, 'https://cdn/igdb/snes.png');
    });

    test('falls back to slug when name missing, defaults the rest', () {
      final p = RommPlatform.fromJson({'id': 1, 'slug': 'nes'});
      expect(p.name, 'nes');
      expect(p.slug, 'nes');
      expect(p.fsSlug, isNull);
      expect(p.romCount, 0);
      expect(p.urlLogo, isNull);
    });

    test('uses "Unknown" when both name and slug are absent', () {
      final p = RommPlatform.fromJson({'id': 1});
      expect(p.name, 'Unknown');
      expect(p.slug, '');
    });
  });

  group('RommRom.fromJson', () {
    test('parses a single-file ROM', () {
      final rom = RommRom.fromJson({
        'id': 99,
        'name': 'Chrono Trigger',
        'platform_id': 12,
        'platform_slug': 'snes',
        'fs_name': 'Chrono Trigger.sfc',
        'fs_name_no_ext': 'Chrono Trigger',
        'fs_extension': 'sfc',
        'fs_size_bytes': 4194304,
        'url_cover': '/assets/cover.png',
      });
      expect(rom.id, 99);
      expect(rom.name, 'Chrono Trigger');
      expect(rom.platformId, 12);
      expect(rom.platformSlug, 'snes');
      expect(rom.fsName, 'Chrono Trigger.sfc');
      expect(rom.fsExtension, 'sfc');
      expect(rom.fsSizeBytes, 4194304);
      expect(rom.urlCover, '/assets/cover.png');
      expect(rom.files, isEmpty);
      expect(rom.isMultiFile, isFalse);
    });

    test('parses multi-file ROM and flags isMultiFile', () {
      final rom = RommRom.fromJson({
        'id': 5,
        'name': 'FF VII',
        'files': [
          {'id': 1, 'file_name': 'disc1.bin', 'file_size_bytes': 100},
          {'id': 2, 'file_name': 'disc2.bin', 'file_size_bytes': 200},
        ],
      });
      expect(rom.files, hasLength(2));
      expect(rom.files.first.fileName, 'disc1.bin');
      expect(rom.files.first.fileSizeBytes, 100);
      expect(rom.isMultiFile, isTrue);
    });

    test('flags isMultiFile from has_multiple_files when files is empty', () {
      // The list endpoint (/api/roms) returns files: [] but sets the
      // has_multiple_files boolean — this is what the browse/download flow
      // consumes, so isMultiFile must honour the flag, not just files.length.
      final rom = RommRom.fromJson({
        'id': 7665,
        'name': 'The Secret of Monkey Island',
        'fs_name': 'The Secret of Monkey Island',
        'has_multiple_files': true,
        'files': const [],
      });
      expect(rom.files, isEmpty);
      expect(rom.hasMultipleFiles, isTrue);
      expect(rom.isMultiFile, isTrue);
    });

    test('a single file is not multi-file', () {
      final rom = RommRom.fromJson({
        'id': 5,
        'files': [
          {'id': 1, 'file_name': 'only.bin'},
        ],
      });
      expect(rom.files, hasLength(1));
      expect(rom.isMultiFile, isFalse);
      expect(rom.files.first.fileSizeBytes, 0);
    });

    test('falls back to fs_name then "Unknown" for name', () {
      expect(
        RommRom.fromJson({'id': 1, 'fs_name': 'game.gba'}).name,
        'game.gba',
      );
      expect(RommRom.fromJson({'id': 1}).name, 'Unknown');
    });

    test('applies defaults for missing optional fields', () {
      final rom = RommRom.fromJson({'id': 7});
      expect(rom.platformId, 0);
      expect(rom.platformSlug, '');
      expect(rom.fsName, '');
      expect(rom.fsNameNoExt, '');
      expect(rom.fsExtension, '');
      expect(rom.fsSizeBytes, 0);
      expect(rom.urlCover, isNull);
    });

    test('ignores non-map entries in the files list', () {
      final rom = RommRom.fromJson({
        'id': 1,
        'files': [
          'garbage',
          {'id': 2, 'file_name': 'real.bin'},
        ],
      });
      expect(rom.files, hasLength(1));
      expect(rom.files.first.fileName, 'real.bin');
    });

    test('parses RA presence and total from merged_ra_metadata', () {
      final rom = RommRom.fromJson({
        'id': 1,
        'ra_id': 14402,
        'merged_ra_metadata': {
          'achievements': [
            {'ra_id': 1},
            {'ra_id': 2},
            {'ra_id': 3},
          ],
        },
      });
      expect(rom.raId, 14402);
      expect(rom.raTotalAchievements, 3);
      expect(rom.hasRetroAchievements, isTrue);
    });

    test('falls back to max_possible for total when no achievement list', () {
      final rom = RommRom.fromJson({
        'id': 1,
        'ra_id': 5,
        'merged_ra_metadata': {'max_possible': 42},
      });
      expect(rom.raTotalAchievements, 42);
    });

    test('no RA data means hasRetroAchievements is false', () {
      final rom = RommRom.fromJson({'id': 1});
      expect(rom.raId, isNull);
      expect(rom.raTotalAchievements, 0);
      expect(rom.hasRetroAchievements, isFalse);
    });

    test('ra_id present but no achievements is not "has RAs"', () {
      final rom = RommRom.fromJson({'id': 1, 'ra_id': 5});
      expect(rom.raId, 5);
      expect(rom.raTotalAchievements, 0);
      expect(rom.hasRetroAchievements, isFalse);
    });
  });

  group('RommCollection.fromJson', () {
    test('parses a user collection with int id coerced to string', () {
      final c = RommCollection.fromJson({
        'id': 7,
        'name': 'Favourites',
        'rom_count': 3,
        'url_cover': '/c/cover.png',
      }, isVirtual: false);
      expect(c.id, '7');
      expect(c.name, 'Favourites');
      expect(c.romCount, 3);
      expect(c.isVirtual, isFalse);
      expect(c.urlCover, '/c/cover.png');
    });

    test('parses a virtual collection with string id', () {
      final c = RommCollection.fromJson({
        'id': 'series:mario',
        'name': 'Mario',
      }, isVirtual: true);
      expect(c.id, 'series:mario');
      expect(c.isVirtual, isTrue);
      expect(c.romCount, 0);
    });

    test('falls back to the first path_covers_small when url_cover empty', () {
      final c = RommCollection.fromJson({
        'id': 1,
        'name': 'X',
        'url_cover': '',
        'path_covers_small': ['/small.png', '/small2.png'],
      }, isVirtual: false);
      expect(c.urlCover, '/small.png');
      expect(c.coverUrls, ['/small.png', '/small2.png']);
    });

    test('falls back to path_covers_large when small is empty', () {
      final c = RommCollection.fromJson({
        'id': 1,
        'name': 'X',
        'path_covers_small': <String>[],
        'path_covers_large': ['/large.png'],
      }, isVirtual: false);
      expect(c.urlCover, '/large.png');
      expect(c.coverUrls, ['/large.png']);
    });

    test('cover is null when no usable cover field present', () {
      final c = RommCollection.fromJson({
        'id': 1,
        'name': 'X',
        'path_covers_small': <String>[],
      }, isVirtual: false);
      expect(c.urlCover, isNull);
      expect(c.coverUrls, isEmpty);
    });
  });

  group('RommAsset.fromJson', () {
    test('parses a save asset and records isState=false', () {
      final a = RommAsset.fromJson({
        'id': 10,
        'file_name': 'Game.srm',
        'file_size_bytes': 8192,
        'content_hash': 'abc',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-02-02T12:00:00.000Z',
        'emulator': 'snes9x',
        'slot': 'autosave',
        'download_path': '/api/raw/assets/x/Game.srm',
      }, isState: false);
      expect(a.id, 10);
      expect(a.fileName, 'Game.srm');
      expect(a.fileSizeBytes, 8192);
      expect(a.contentHash, 'abc');
      expect(a.emulator, 'snes9x');
      // A slot is a *name*, not a number: RomM declares `slot: str | None` and
      // pairs saves on `(rom_id, slot)`. Parsing it as an int turned every
      // named slot into null — indistinguishable from an archival upload.
      expect(a.slot, 'autosave');
      expect(a.downloadPath, '/api/raw/assets/x/Game.srm');
      expect(a.isState, isFalse);
      expect(a.updatedAt, DateTime.parse('2026-02-02T12:00:00.000Z'));
      expect(
        a.updatedAtMs,
        DateTime.parse('2026-02-02T12:00:00.000Z').millisecondsSinceEpoch,
      );
    });

    test('records isState=true for state assets', () {
      final a = RommAsset.fromJson({
        'id': 1,
        'file_name': 's.state',
      }, isState: true);
      expect(a.isState, isTrue);
    });

    test('coerces string-typed numeric fields', () {
      final a = RommAsset.fromJson({
        'id': '11',
        'file_name': 'g.srm',
        'file_size_bytes': '256',
        'slot': 3,
      }, isState: false);
      expect(a.id, 11);
      expect(a.fileSizeBytes, 256);
      // A numerically-named slot is still a name.
      expect(a.slot, '3');
    });

    test('reads a blank slot as no slot at all', () {
      // '' and null both mean "archival, unpaired upload" to RomM; collapsing
      // them here spares every caller from testing for both.
      final a = RommAsset.fromJson({
        'id': 12,
        'file_name': 'g.srm',
        'slot': '',
      }, isState: false);
      expect(a.slot, isNull);
    });

    test('parses an offset-less (naive) timestamp as UTC, not device-local', () {
      // RomM (SQLAlchemy) emits naive UTC timestamps with no zone designator.
      // These must be read as UTC so cross-device newer/older comparisons don't
      // skew by the device's UTC offset and silently drop a newer remote save.
      final a = RommAsset.fromJson({
        'id': 1,
        'file_name': 'g.srm',
        'updated_at': '2026-07-13T10:00:00.123456',
      }, isState: false);
      expect(a.updatedAt!.isUtc, isTrue);
      expect(
        a.updatedAtMs,
        DateTime.utc(2026, 7, 13, 10, 0, 0, 123, 456).millisecondsSinceEpoch,
      );
    });

    test('honours an explicit UTC (Z) offset', () {
      final a = RommAsset.fromJson({
        'id': 1,
        'file_name': 'g.srm',
        'updated_at': '2026-07-13T10:00:00.000Z',
      }, isState: false);
      expect(
        a.updatedAtMs,
        DateTime.utc(2026, 7, 13, 10, 0, 0).millisecondsSinceEpoch,
      );
    });

    test('honours an explicit non-UTC offset', () {
      // +02:00 means the instant is 08:00Z.
      final a = RommAsset.fromJson({
        'id': 1,
        'file_name': 'g.srm',
        'updated_at': '2026-07-13T10:00:00+02:00',
      }, isState: false);
      expect(
        a.updatedAtMs,
        DateTime.utc(2026, 7, 13, 8, 0, 0).millisecondsSinceEpoch,
      );
    });

    test('defaults and null-safe parsing for sparse payloads', () {
      final a = RommAsset.fromJson({}, isState: false);
      expect(a.id, 0);
      expect(a.fileName, '');
      expect(a.fileSizeBytes, 0);
      expect(a.contentHash, isNull);
      expect(a.createdAt, isNull);
      expect(a.updatedAt, isNull);
      expect(a.slot, isNull);
      expect(a.updatedAtMs, 0);
    });
  });
}
