/// Formats the [time] for the header clock, honoring the user's
/// 12/24-hour clock preference.
///
/// When [use12Hour] is false (default), returns 24-hour format (e.g. `14:09`).
/// When true, returns 12-hour format with an AM/PM suffix (e.g. `2:09 PM`),
/// mapping midnight to `12:00 AM` and noon to `12:00 PM`.
String formatClockTime(DateTime time, {required bool use12Hour}) {
  final minute = time.minute.toString().padLeft(2, '0');
  if (!use12Hour) {
    return '${time.hour}:$minute';
  }
  final period = time.hour < 12 ? 'AM' : 'PM';
  int hour12 = time.hour % 12;
  if (hour12 == 0) hour12 = 12;
  return '$hour12:$minute $period';
}
