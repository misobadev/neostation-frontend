final RegExp _raDateZonePattern = RegExp(r'[+-]\d\d:\d\d$');

/// Parses RetroAchievements timestamps, treating zone-less values as UTC.
DateTime? parseRetroAchievementsDateUtc(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var normalized = raw.trim().replaceFirst(' ', 'T');
  // The API sometimes returns award dates without a time component. Treat
  // those as midnight UTC instead of passing an invalid `YYYY-MM-DDZ` value
  // to DateTime.tryParse.
  if (RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(normalized)) {
    normalized = '${normalized}T00:00:00';
  }
  final hasExplicitZone =
      normalized.endsWith('Z') || _raDateZonePattern.hasMatch(normalized);
  return DateTime.tryParse(
    hasExplicitZone ? normalized : '${normalized}Z',
  )?.toUtc();
}
