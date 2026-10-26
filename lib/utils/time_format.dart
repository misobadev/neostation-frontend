import '../l10n/app_locale.dart';

/// Formats the [time] for the header clock, honouring the user's
/// 12/24-hour clock preference.
///
/// When [use12Hour] is false (default), returns 24-hour format (e.g. `14:09`).
/// When true, returns 12-hour format with the period (e.g. `2:09 PM`),
/// mapping midnight to `12:00 AM` and noon to `12:00 PM`.
///
/// [text] looks up an [AppLocale] key in the app language (callers pass
/// `(key) => key.getString(context)`): the period's words and whether it comes
/// before the time (ja, ko, zh) or after it. Without it, the English form.
String formatClockTime(
  DateTime time, {
  required bool use12Hour,
  String Function(String key)? text,
}) {
  final minute = time.minute.toString().padLeft(2, '0');
  if (!use12Hour) {
    return '${time.hour}:$minute';
  }
  int hour12 = time.hour % 12;
  if (hour12 == 0) hour12 = 12;
  return _with12HourPeriod('$hour12:$minute', pm: time.hour >= 12, text: text);
}

String _with12HourPeriod(
  String time, {
  required bool pm,
  String Function(String key)? text,
}) {
  final period = pm
      ? (text?.call(AppLocale.clockPm) ?? 'PM')
      : (text?.call(AppLocale.clockAm) ?? 'AM');
  return (text?.call(AppLocale.clockTime12h) ?? '{time} {period}')
      .replaceFirst('{time}', time)
      .replaceFirst('{period}', period);
}

/// The widest string [formatClockTime] can return for this setting.
///
/// Header geometry is sized off this rather than the current time, so the
/// layout cannot shift as the clock ticks: 24-hour hours are not zero-padded,
/// so a two-digit hour is the widest, and the 12-hour form adds the period,
/// whichever of the language's two is longer in characters (the period after
/// noon on a tie, as before).
String widestClockText({
  required bool use12Hour,
  String Function(String key)? text,
}) {
  if (!use12Hour) return '23:59';
  final am = _with12HourPeriod('12:59', pm: false, text: text);
  final pm = _with12HourPeriod('12:59', pm: true, text: text);
  return am.length > pm.length ? am : pm;
}
