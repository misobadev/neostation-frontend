/// A RomM save or save-state asset, returned by `/api/saves` and `/api/states`.
///
/// Both endpoints share the same schema; [isState] records which router the
/// asset came from so callers can route uploads/downloads correctly.
class RommAsset {
  /// RomM asset id (used for `/api/{saves|states}/{id}/content`).
  final int id;

  /// The owning ROM. Filenames are not identities: different games/platforms
  /// can use the same save filename.
  final int? romId;

  /// The emulator's filename for this save/state (e.g. "Game.srm").
  final String fileName;

  /// Size in bytes.
  final int fileSizeBytes;

  /// Server-side content hash, when provided (used for change detection).
  final String? contentHash;

  /// When the asset was first uploaded.
  final DateTime? createdAt;

  /// When the asset was last updated (primary timestamp for conflict checks).
  final DateTime? updatedAt;

  /// Emulator label the asset is associated with, if any.
  final String? emulator;

  /// Sync slot the asset belongs to, when the uploading client sent one.
  ///
  /// A **name**, not a number: RomM declares `slot: str | None` and suggests a
  /// stable label such as `autosave`. Saves are paired server-side on
  /// `(rom_id, slot)`, and a slotted upload is renamed to
  /// `<name> [YYYY-MM-DD_HH-MM-SS].<ext>` — `RomMSyncProvider.localNameForAsset`
  /// undoes that when choosing where to write the file locally.
  /// Null means an archival, manual upload (RomM excludes those from pairing).
  /// States never carry a slot; `/api/states` has no such parameter.
  final String? slot;

  /// Server-relative URL to fetch the raw bytes
  /// (`/api/raw/assets/{file_path}/{file_name}?timestamp=...`). This is the
  /// canonical download for BOTH saves and states — the `/api/saves/{id}/content`
  /// convenience route exists only for saves, so states must use this.
  final String? downloadPath;

  /// True if this came from `/api/states`, false for `/api/saves`.
  final bool isState;

  const RommAsset({
    required this.id,
    required this.fileName,
    required this.fileSizeBytes,
    required this.isState,
    this.romId,
    this.contentHash,
    this.createdAt,
    this.updatedAt,
    this.emulator,
    this.slot,
    this.downloadPath,
  });

  factory RommAsset.fromJson(
    Map<String, dynamic> json, {
    required bool isState,
  }) {
    return RommAsset(
      id: int.tryParse((json['id'] ?? 0).toString()) ?? 0,
      romId: int.tryParse((json['rom_id'] ?? '').toString()),
      fileName: (json['file_name'] ?? '').toString(),
      fileSizeBytes:
          int.tryParse((json['file_size_bytes'] ?? '0').toString()) ?? 0,
      contentHash: json['content_hash']?.toString(),
      createdAt: _parseTimestamp(json['created_at']),
      updatedAt: _parseTimestamp(json['updated_at']),
      emulator: json['emulator']?.toString(),
      slot: _nonEmpty(json['slot']),
      downloadPath: json['download_path']?.toString(),
      isState: isState,
    );
  }

  /// Milliseconds-since-epoch of [updatedAt], or 0 when unknown.
  int get updatedAtMs => updatedAt?.millisecondsSinceEpoch ?? 0;

  /// A trimmed string, or null when the field is absent or blank.
  ///
  /// `""` and `null` mean the same thing for a slot — no slot — and collapsing
  /// them here keeps every caller from having to test for both.
  static String? _nonEmpty(dynamic raw) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  /// Parses a RomM ISO-8601 timestamp, treating an offset-less string as UTC.
  ///
  /// RomM's backend (SQLAlchemy `DateTime` columns) emits naive UTC timestamps
  /// with no zone designator (e.g. `2026-07-13T10:00:00.123456`).
  /// [DateTime.tryParse] interprets those as device-**local** time, which skews
  /// [updatedAtMs] by the device's UTC offset — enough for the sync provider's
  /// newer/older comparison to keep a genuinely-older local save and silently
  /// skip pulling the newer remote one. When the string carries no offset
  /// (no `Z` and no `±HH:MM`), we reinterpret the parsed wall-clock as UTC.
  static DateTime? _parseTimestamp(dynamic raw) {
    final s = (raw ?? '').toString();
    if (s.isEmpty) return null;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return null;
    if (parsed.isUtc) return parsed; // already had a 'Z' / explicit UTC offset
    final hasOffset = RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
    if (hasOffset) return parsed; // explicit non-UTC offset: honour it
    // Naive string → reinterpret the wall-clock components as UTC.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }
}
