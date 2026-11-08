/// Where the cloud copy of the save at [savePath] is kept when the save
/// changed both on this device and in the cloud since the last sync: beside
/// it, as `<save>.cloud-<time>.neosync.bak`.
///
/// The `.neosync.bak` ending matters: NeoSync's save listing skips such
/// files, so the copy is never uploaded or taken for one of the game's saves.
/// The time is the cloud copy's modified time ([modifiedAt], milliseconds
/// since the epoch) in UTC, to the second, so trying again for the same cloud
/// copy writes the same file rather than another one. Without a usable time
/// (none, 0, or out of range) the first 12 letters and digits of [checksum]
/// stand in, and without either the name is just `<save>.cloud.neosync.bak`.
String cloudCopyBackupPath(
  String savePath, {
  required int? modifiedAt,
  String? checksum,
}) {
  // The latest time a DateTime can hold, in milliseconds since the epoch.
  const latest = 8640000000000000;
  final String tag;
  if (modifiedAt != null && modifiedAt > 0 && modifiedAt <= latest) {
    final t = DateTime.fromMillisecondsSinceEpoch(modifiedAt, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    tag =
        '-${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  } else {
    // A checksum comes from the server: keep only letters and digits, so it
    // can't add a folder to the path.
    final safe = (checksum ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    tag = safe.isEmpty
        ? ''
        : '-${safe.substring(0, safe.length < 12 ? safe.length : 12)}';
  }
  return '$savePath.cloud$tag.neosync.bak';
}
