import '../data/datasources/sqlite_service.dart';
import '../models/discovery_models.dart';

/// Repository for the weekly Discovery board's data access.
///
/// Thin by design, in the [GameRepository] style: it owns no SQL, it only keeps
/// the service layer off the datasource. Every statement lives in
/// [SqliteService].
class DiscoveryRepository {
  /// Returns every game the board can pick from, as raw rows.
  ///
  /// Rows stay untyped here because they serve two consumers with different
  /// shapes — see [SqliteService.getDiscoveryCandidates].
  static Future<List<Map<String, Object?>>> getCandidates() =>
      SqliteService.getDiscoveryCandidates();

  /// Returns this week's persisted picks, keyed by slot id.
  static Future<Map<String, DiscoveryPick>> getPicks(String weekKey) async {
    final rows = await SqliteService.getDiscoveryPicks(weekKey);
    final picks = <String, DiscoveryPick>{};
    for (final row in rows) {
      final pick = DiscoveryPick.fromRow(row);
      if (pick.slotId.isNotEmpty) picks[pick.slotId] = pick;
    }
    return picks;
  }

  /// Returns the ROM paths picked in any week from [sinceWeekKey] on.
  static Future<Set<String>> getPickPathsSince(String sinceWeekKey) async {
    final paths = await SqliteService.getDiscoveryPickPathsSince(sinceWeekKey);
    return paths.toSet();
  }

  /// Persists [pick], replacing whatever held its slot.
  static Future<void> upsertPick(DiscoveryPick pick) =>
      SqliteService.upsertDiscoveryPick(
        weekKey: pick.weekKey,
        slotId: pick.slotId,
        section: pick.section.name,
        romPath: pick.romPath,
        genreBucket: pick.genre?.name,
        slotOrder: pick.slotOrder,
        rerollCount: pick.rerollCount,
      );

  /// Persists several picks. A bulk board fill is committed in one
  /// transaction rather than one row at a time.
  static Future<void> upsertPicks(Iterable<DiscoveryPick> picks) {
    return SqliteService.upsertDiscoveryPicks([
      for (final pick in picks)
        (
          weekKey: pick.weekKey,
          slotId: pick.slotId,
          section: pick.section.name,
          genreBucket: pick.genre?.name,
          slotOrder: pick.slotOrder,
          romPath: pick.romPath,
          rerollCount: pick.rerollCount,
        ),
    ]);
  }

  /// Drops the pick held by [slotId] in [weekKey].
  static Future<void> deletePick(String weekKey, String slotId) =>
      SqliteService.deleteDiscoveryPick(weekKey: weekKey, slotId: slotId);

  /// Deletes every pick from before [weekKey].
  static Future<int> pruneBefore(String weekKey) =>
      SqliteService.pruneDiscoveryPicksBefore(weekKey);
}
