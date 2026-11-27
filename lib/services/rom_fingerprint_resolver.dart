import '../models/rom_fingerprint.dart';
import '../repositories/game_library_repository.dart';
import 'logger_service.dart';
import 'retroachievements_hash_service.dart';
import 'rom_fingerprint_service.dart';

/// Resolves a ROM's dump identity (crc32/md5/size) for metadata lookups,
/// shared by every metadata provider (ScreenScraper, NeoAssets): the
/// fingerprint is cached per ROM, so whichever provider scrapes first pays
/// for the read and the other reuses it.
class RomFingerprintResolver {
  RomFingerprintResolver._();

  static final _log = LoggerService.instance;

  /// Returns the cached dump identity for [romPath], computing and caching it
  /// on first use.
  ///
  /// [effort] decides whether a ROM that is not already fingerprinted is worth
  /// reading. Under [FingerprintEffort.cheapOnly] only a cached value or a
  /// zip's stored crc32 comes back, and a null result means "not worth it yet",
  /// not "cannot be done" — so nothing is parked.
  ///
  /// Never throws: a ROM that genuinely cannot be fingerprinted is parked with
  /// its reason and the scrape carries on by name, which is what it did before
  /// hashing existed.
  static Future<RomFingerprint?> resolve(
    String romPath,
    String? systemFolder, {
    required FingerprintEffort effort,
  }) async {
    try {
      final cached = await GameLibraryRepository.getRomFingerprint(romPath);
      if (cached != null) return cached;

      // A ROM parked for a reason that cannot fix itself (disc, oversize, a
      // corrupt archive) stays parked — re-attempting it every scrape is
      // exactly what the marker exists to stop, and for extract_failed each
      // retry is a full extraction. Transient reasons (missing, error) are
      // allowed through: a re-scrape is the natural retry point, and a fresh
      // fingerprint clears the marker.
      final parked = await GameLibraryRepository.getRomFingerprintSkipReason(
        romPath,
      );
      if (parked != null &&
          RomFingerprintService.permanentSkipReasons.contains(parked)) {
        return null;
      }

      // Arcade sets are identified by their archive, and which systems those
      // are is declared per system in assets/systems/<sys>.json. Resolved here
      // (cached per system) rather than inside the fingerprinter, which stays
      // free of database reads.
      final policy = await RetroAchievementsHashService.policyForSystem(
        systemFolder,
      );

      // The cheap path reads a few hundred bytes, so an isolate hop would cost
      // more than the work. Only the full read is worth handing off.
      final attempt = effort == FingerprintEffort.cheapOnly
          ? await RomFingerprintService.fingerprint(
              romPath,
              systemFolder,
              keepsArchivesPacked: policy.keepsArchivesPacked,
              effort: FingerprintEffort.cheapOnly,
            )
          : await RomFingerprintService.computeInBackground(
              romPath,
              systemFolder,
              keepsArchivesPacked: policy.keepsArchivesPacked,
            );

      final fingerprint = attempt.fingerprint;
      if (fingerprint == null) {
        // Deferring is not a failure — parking the ROM here would hide it from
        // the full pass that runs a moment later.
        if (attempt.skipReason != RomFingerprintService.deferredCostly) {
          await GameLibraryRepository.markRomFingerprintSkipped(
            romPath,
            attempt.skipReason ?? RomFingerprintService.skipError,
          );
        }
        return null;
      }

      await GameLibraryRepository.updateRomFingerprint(romPath, fingerprint);
      return fingerprint;
    } catch (e) {
      _log.w('Could not fingerprint $romPath, scraping by name: $e');
      return null;
    }
  }
}
