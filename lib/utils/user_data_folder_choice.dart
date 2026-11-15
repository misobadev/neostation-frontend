import 'package:path/path.dart' as p;

/// What Settings does with a folder picked for NeoStation's user data; see
/// [chooseUserDataFolder].
sealed class UserDataFolderChoice {
  const UserDataFolderChoice();
}

/// The folder picked is where the data already is: nothing to move.
final class SameUserDataFolder extends UserDataFolderChoice {
  const SameUserDataFolder();
}

/// Move the data to the folder picked.
final class PickedUserDataFolder extends UserDataFolderChoice {
  const PickedUserDataFolder(this.path);
  final String path;
}

/// NeoStation can't write the folder picked on an SD card, but can write its
/// own folder on that card, [path]: offered instead, and the move dialogue
/// says so.
final class CardUserDataFolder extends UserDataFolderChoice {
  const CardUserDataFolder(this.path);
  final String path;
}

/// NeoStation can write neither the folder picked nor, for a folder on an SD
/// card, its own folder on that card.
final class UnwritableUserDataFolder extends UserDataFolderChoice {
  const UnwritableUserDataFolder();
}

/// Decides what to do with [picked], the folder picked for user data, when
/// the data is in [current].
///
/// The folder picked is used when NeoStation can write it ([canUse]). On an
/// SD card it may not be able to without All files access (or, on Android 10
/// and older, at all), but its own folder on that card can always be
/// written; that one is offered instead ([userDataFolderOnSameCard]).
/// [appDirs] lists NeoStation's storage folders, and is only read when the
/// folder picked was refused. Folders are compared as normalised paths, so
/// a trailing separator doesn't make the same folder look like another.
Future<UserDataFolderChoice> chooseUserDataFolder({
  required String picked,
  required String current,
  required Future<bool> Function(String folder) canUse,
  required Future<Iterable<String>> Function() appDirs,
}) async {
  if (_samePath(picked, current)) return const SameUserDataFolder();
  if (await canUse(picked)) return PickedUserDataFolder(picked);
  final cardFolder = userDataFolderOnSameCard(picked, await appDirs());
  if (cardFolder == null ||
      _samePath(cardFolder, current) ||
      !await canUse(cardFolder)) {
    return const UnwritableUserDataFolder();
  }
  return CardUserDataFolder(cardFolder);
}

/// The same folder as the move sees it (`migrateData` compares canonical
/// paths): a trailing separator, or letter case on Windows, doesn't make it
/// another.
bool _samePath(String a, String b) => p.equals(a, b);

/// NeoStation's own folder for its user data on the SD card [pickedPath] is
/// on: `<card>/Android/data/<package>/files/user-data`, from [appDirs],
/// NeoStation's external storage folders (one per volume, as
/// `getExternalStorageDirectories` lists them). Android deletes it when
/// NeoStation is uninstalled.
///
/// Only the card the folder was picked on counts: null for internal storage
/// (`/storage/emulated/…`), for anything outside `/storage`, and for a card
/// with no folder in [appDirs]. Android paths, so POSIX whatever the host.
String? userDataFolderOnSameCard(String pickedPath, Iterable<String> appDirs) {
  final volume = _cardOf(pickedPath);
  if (volume == null) return null;
  for (final dir in appDirs) {
    // `/storage/<volume>/Android/data/<package>/files`: the volume is matched
    // as a whole path segment, so one card's id never matches part of
    // another's, and a card's root is never taken for its app folder.
    final parts = p.posix.split(p.posix.normalize(dir));
    if (parts.length > 3 && _cardOf(dir) == volume) {
      return p.posix.join(dir, 'user-data');
    }
  }
  return null;
}

/// The SD card (or other removable volume) [path] is on, from
/// `/storage/<volume>/…`; null for internal storage and anything else.
String? _cardOf(String path) {
  final parts = p.posix.split(p.posix.normalize(path));
  if (parts.length < 3 || parts[0] != '/' || parts[1] != 'storage') {
    return null;
  }
  final volume = parts[2];
  return volume == 'emulated' || volume == 'self' ? null : volume;
}
