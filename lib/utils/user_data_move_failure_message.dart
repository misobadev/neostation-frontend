import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/user_data_location_service.dart';

/// What to tell the user when moving the user data failed, in the app
/// language: [text] looks up an [AppLocale] key (callers pass
/// `(key) => key.getString(context)`). Free of widget imports so the choice is
/// testable on its own.
///
/// [UserDataMoveFailure.detail] is English and names files and system errors,
/// so it goes to the log only.
///
/// [suggestAllFilesAccess] adds, to a folder that can't be written, how to
/// allow All files access (Android without it); see
/// [userDataFolderNotWritableMessage].
String userDataMoveFailureMessage(
  UserDataMoveFailureKind kind,
  String Function(String key) text, {
  bool suggestAllFilesAccess = false,
}) => switch (kind) {
  UserDataMoveFailureKind.notWritable => userDataFolderNotWritableMessage(
    text,
    suggestAllFilesAccess: suggestAllFilesAccess,
  ),
  UserDataMoveFailureKind.busy => text(AppLocale.userDataMoveBusy),
  UserDataMoveFailureKind.noSpace => text(AppLocale.userDataMoveNoSpace),
  UserDataMoveFailureKind.blocked => text(AppLocale.userDataMoveBlocked),
  UserDataMoveFailureKind.overlapping => text(
    AppLocale.userDataMoveOverlapping,
  ),
  UserDataMoveFailureKind.other => text(AppLocale.userDataMoveFailed),
};

/// What Settings tells the user when NeoStation can't write to the folder
/// picked for its user data. With [suggestAllFilesAccess] (Android without All
/// files access, which a folder outside the app's own storage needs), it adds
/// where to allow that, as the setup wizard does.
String userDataFolderNotWritableMessage(
  String Function(String key) text, {
  required bool suggestAllFilesAccess,
}) {
  final message = text(AppLocale.userDataFolderCantWrite);
  if (!suggestAllFilesAccess) return message;
  return '$message\n${text(AppLocale.userDataFolderGrantAllFiles)}';
}
