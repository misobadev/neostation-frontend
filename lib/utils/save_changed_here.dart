/// Whether a save changed on this device since its last sync, from what that
/// sync recorded: its file time ([savedTime]) and content hash ([savedHash]).
///
/// The file time has to have moved, with a tolerance of 2 seconds for
/// FAT32/exFAT resolution, and, when the last sync recorded a hash, the
/// content has to differ from it. The time also moves when an emulator
/// rewrites the same save, which would make an unchanged save look changed;
/// the hash alone isn't enough either, since a download records the cloud
/// list's checksum, which can be an older version's than the bytes it wrote.
/// Without a record ([savedTime] null) nothing can be ruled out: changed.
bool saveChangedHere({
  required int localTime,
  required String localHash,
  required int? savedTime,
  required String? savedHash,
}) {
  if (savedTime == null) return true;
  return (localTime - savedTime).abs() > 2000 &&
      (savedHash == null || savedHash.isEmpty || localHash != savedHash);
}
