import 'dart:io';
import 'dart:convert';
import 'package:neostation/services/logger_service.dart';
import '../services/saf_directory_service.dart';

/// Utility service for extracting Title IDs from `.psvita` files.
///
/// These specialized files contain the game's unique identifier as plain text
/// for use within the NeoStation ecosystem.
class VitaTitleExtractor {
  static final RegExp _plainTitleId = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  static final _log = LoggerService.instance;

  /// Extracts the Title ID string from the specified file.
  ///
  /// Supports standard filesystem paths and Android Storage Access Framework (SAF) URIs.
  static Future<String?> extractTitleId(String path) async {
    try {
      final bool isSaf = path.startsWith('content://');
      String? content;

      if (isSaf) {
        // Read a small segment via SAF; Title IDs typically fit within 1KB.
        final bytes = await SafDirectoryService.readRange(path, 0, 1024);
        if (bytes != null) {
          content = utf8.decode(bytes);
        }
      } else {
        // Direct filesystem read.
        final file = File(path);
        if (await file.exists()) {
          content = await file.readAsString();
        }
      }

      if (content != null && content.trim().isNotEmpty) {
        final titleId = content.trim();
        // The ID is passed to emulators as a launch argument (on Android as
        // an element of a comma-separated list), so accept only a plain ID
        // such as PCSE00000.
        if (!_plainTitleId.hasMatch(titleId)) {
          _log.w('Ignoring Vita Title ID in $path: not a plain ID');
          return null;
        }
        _log.d('Extracted Vita Title ID: $titleId from $path');
        return titleId;
      }
    } catch (e) {
      _log.e('Failed to extract Vita Title ID from $path: $e');
    }
    return null;
  }
}
