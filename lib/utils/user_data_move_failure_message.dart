import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/user_data_location_service.dart';

/// What to tell the user when moving the user data failed, in the app
/// language: [text] looks up an [AppLocale] key (callers pass
/// `(key) => key.getString(context)`). Free of widget imports so the choice is
/// testable on its own.
///
/// [UserDataMoveFailure.detail] is English and names files and system errors,
/// so it goes to the log only.
String userDataMoveFailureMessage(
  UserDataMoveFailureKind kind,
  String Function(String key) text,
) => text(switch (kind) {
  UserDataMoveFailureKind.busy => AppLocale.userDataMoveBusy,
  UserDataMoveFailureKind.noSpace => AppLocale.userDataMoveNoSpace,
  UserDataMoveFailureKind.blocked => AppLocale.userDataMoveBlocked,
  UserDataMoveFailureKind.overlapping => AppLocale.userDataMoveOverlapping,
  UserDataMoveFailureKind.notWritable => AppLocale.userDataFolderNotWritable,
  UserDataMoveFailureKind.other => AppLocale.userDataMoveFailed,
});
