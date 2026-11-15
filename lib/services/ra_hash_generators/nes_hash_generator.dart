import 'dart:io';

import 'package:crypto/crypto.dart';

/// MD5 hash generator for NES ROMs based on the RetroAchievements technical specification.
///
/// Per the official RetroAchievements documentation:
/// - If the ROM contains an 'iNES' header (starting with "NES\x1a"), the first 16 bytes
///   are excluded from the hash calculation to ensure consistency across different header versions.
/// - If no 'iNES' header is detected, the entire file is hashed.
class NesHashGenerator {
  /// Computes the MD5 hash of an NES ROM using the RetroAchievements-compatible algorithm.
  static Future<String> computeHash(String romPath) async {
    final file = File(romPath);
    final bytes = await file.readAsBytes();

    // Verify presence of the iNES header (Magic numbers: 0x4E 0x45 0x53 0x1A).
    if (bytes.length >= 4 &&
        bytes[0] == 0x4E && // 'N'
        bytes[1] == 0x45 && // 'E'
        bytes[2] == 0x53 && // 'S'
        bytes[3] == 0x1A) {
      // '\x1a' (End of Transmission / Substitution)

      // iNES header detected: exclude the 16-byte header and hash the PRG/CHR data.
      final dataWithoutHeader = bytes.sublist(16);
      final digest = md5.convert(dataWithoutHeader);
      return digest.toString();
    } else {
      // No iNES header detected: perform a full-file MD5 digest.
      final digest = md5.convert(bytes);
      return digest.toString();
    }
  }
}
