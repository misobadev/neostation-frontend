import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm_service.dart';

/// What to tell the user when connecting to RomM, or with [browsing] loading
/// from a server already connected, failed, in the app language: [text] looks
/// up an [AppLocale] key (callers pass `(key) => key.getString(context)`).
/// Free of widget imports so the choice is testable on its own.
///
/// While browsing, the server has already been confirmed as RomM, so nothing
/// tells the user to check its URL: an unreadable answer or an odd status is
/// the server's, and a rejected credential means signing in again.
///
/// The exception's own [RommException.message] is English and meant for the
/// log, and the server's answer is never shown; only the system's reason a
/// server couldn't be reached and a status code are filled in.
String rommFailureMessage(
  RommException e,
  String Function(String key) text, {
  bool browsing = false,
}) {
  // Without a detail, drop the placeholder and the colon before it rather than
  // leave "…: " dangling.
  String withError(String key, String? error) => error == null || error.isEmpty
      ? text(key).replaceFirst(RegExp(r'\s*[:：]\s*\{error\}'), '')
      : text(key).replaceFirst('{error}', error);
  return switch (e.kind) {
    RommFailure.tls => text(AppLocale.rommErrorTls),
    RommFailure.unreachable => withError(
      AppLocale.rommErrorUnreachable,
      e.detail,
    ),
    RommFailure.timeout => text(AppLocale.rommErrorTimeout),
    RommFailure.invalidCredentials || RommFailure.invalidApiKey when browsing =>
      text(AppLocale.rommErrorSignInRejected),
    RommFailure.invalidCredentials => text(AppLocale.invalidCredentials),
    RommFailure.invalidApiKey => text(AppLocale.rommErrorInvalidApiKey),
    RommFailure.unexpectedStatus when !browsing => withError(
      AppLocale.rommErrorUnexpectedStatus,
      e.statusCode?.toString(),
    ),
    RommFailure.notRomm => text(
      browsing ? AppLocale.rommErrorUnreadable : AppLocale.rommErrorNotRomm,
    ),
    RommFailure.unexpectedStatus || RommFailure.serverError => withError(
      AppLocale.rommErrorServerStatus,
      e.statusCode?.toString(),
    ),
    RommFailure.other => text(
      browsing ? AppLocale.rommErrorLoadFailed : AppLocale.rommConnectionFailed,
    ),
  };
}
