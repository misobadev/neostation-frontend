import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../data/datasources/sqlite_service.dart';

/// Why [DatabaseFileRepository.snapshotTo] couldn't copy the database.
class DatabaseCopyFailure implements Exception {
  const DatabaseCopyFailure(this.detail, {this.diskFull = false});

  /// English, for the log.
  final String detail;

  /// The copy's drive ran out of space.
  final bool diskFull;

  @override
  String toString() => 'DatabaseCopyFailure: $detail';
}

/// Repository for the database file as a whole, rather than its rows: for
/// moving the user data to another folder.
class DatabaseFileRepository {
  // SQLITE_FULL: the drive (or the database's size limit) is full.
  static const int _sqliteFull = 13;

  /// Writes a consistent, checked copy of the open database, which must be
  /// [expectedFile], to [target] (see [SqliteService.snapshotTo]). Returns
  /// the open database's file; throws a [DatabaseCopyFailure] otherwise.
  static Future<String> snapshotTo(
    String target, {
    required String expectedFile,
  }) async {
    try {
      return await SqliteService.snapshotTo(target, expectedFile: expectedFile);
    } on SqliteException catch (e) {
      throw DatabaseCopyFailure('$e', diskFull: e.resultCode == _sqliteFull);
    } catch (e) {
      throw DatabaseCopyFailure('$e');
    }
  }

  /// Closes the database. The next access opens it again from the user-data
  /// folder saved at that point.
  static Future<void> close() => SqliteService.closeDatabase();

  /// Runs [body] while every other database access waits (see
  /// [SqliteService.withAccessHeld]).
  static Future<T> withAccessHeld<T>(Future<T> Function() body) =>
      SqliteService.withAccessHeld(body);
}
