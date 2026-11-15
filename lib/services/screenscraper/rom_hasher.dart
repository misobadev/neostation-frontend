import 'package:neostation/services/logger_service.dart';

import '../../repositories/system_repository.dart';

/// ROM name helpers for ScreenScraper lookups.
///
/// Strips system-specific extensions from a ROM filename before a name-based
/// search. Hashing moved to [RomFingerprintService], which produces the
/// crc32/md5/size ScreenScraper actually indexes — of the ROM inside an
/// archive, not of the archive. Stateless — holds only the shared logger.
class ScreenscraperRomHasher {
  ScreenscraperRomHasher._();

  static final _log = LoggerService.instance;

  /// Sanitizes a ROM filename by removing system-specific extensions.
  static Future<String> getCleanRomName(
    String romName,
    String? appSystemId,
  ) async {
    if (appSystemId != null) {
      try {
        final extensions = await SystemRepository.getExtensionsForSystem(
          appSystemId,
        );
        for (final ext in extensions) {
          final dotExt = '.$ext';
          if (romName.toLowerCase().endsWith(dotExt.toLowerCase())) {
            return romName.substring(0, romName.length - dotExt.length);
          }
        }
      } catch (e) {
        _log.w('Error getting extensions for app system $appSystemId: $e');
      }
    }

    final lastDot = romName.lastIndexOf('.');
    if (lastDot != -1) {
      final ext = romName.substring(lastDot + 1);
      if (!ext.contains(' ') && ext.length <= 10) {
        return romName.substring(0, lastDot);
      }
    }

    return romName;
  }
}
