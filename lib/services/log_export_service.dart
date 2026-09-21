import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/log_redaction.dart';

/// Outcome of [LogExportService.export].
enum LogExportResult {
  /// Android: the share sheet was opened with the zip attached.
  shared,

  /// Desktop: the zip was written where the user chose.
  saved,

  /// Desktop: the user dismissed the save dialog.
  cancelled,

  /// Nothing to export, or building/handing off the zip failed.
  failed,
}

/// Packages the app logs into a zip a user can attach to a bug report.
///
/// The zip holds `app.log`, the rotated `app.log.old` (rotation happens at
/// launch, so a user who restarts to report a crash has pushed it there) and a
/// `diagnostics.txt` with the version and device details we would otherwise
/// have to ask for. Log text is re-run through [redactSecrets] on the way out
/// so lines written before a redaction rule existed do not leak.
///
/// Android hands the zip to the system share sheet — app storage is not
/// browsable from most file managers, so "save it and go find it" does not
/// work there. Desktop shows a save dialog instead.
class LogExportService {
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  static final _log = LoggerService.instance;

  /// Builds the zip and shares or saves it. On a desktop [LogExportResult.saved]
  /// the saved file's path is returned alongside.
  static Future<(LogExportResult, String?)> export({
    required String dialogTitle,
    String? systemsVersion,
  }) async {
    try {
      final logPath = await ConfigService.getLogFilePath();
      final diagnostics = await _diagnostics(systemsVersion, logPath);
      final bytes = await Isolate.run(
        () => buildZip(logPath: logPath, diagnostics: diagnostics),
      );
      if (bytes == null) return (LogExportResult.failed, null);

      final fileName = 'neostation-logs-${_timestamp(DateTime.now())}.zip';

      if (Platform.isAndroid) {
        final tempDir = await getTemporaryDirectory();
        final zipFile = File(path.join(tempDir.path, fileName));
        await zipFile.writeAsBytes(bytes, flush: true);
        final ok = await _channel.invokeMethod<bool>('shareFile', {
          'filePath': zipFile.path,
          'mimeType': 'application/zip',
          'title': dialogTitle,
        });
        return (
          ok == true ? LogExportResult.shared : LogExportResult.failed,
          null,
        );
      }

      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: dialogTitle,
        initialDirectory: await _downloadsPath(),
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (uri == null) return (LogExportResult.cancelled, null);
      return (LogExportResult.saved, uri.toFilePath());
    } catch (e, st) {
      _log.e('Log export failed', error: e, stackTrace: st);
      return (LogExportResult.failed, null);
    }
  }

  /// Zips the log files at [logPath] (and its `.old` sibling) plus
  /// [diagnostics]. Returns null when there is no log to export.
  ///
  /// Top-level-safe so it can run in [Isolate.run]: two logs can total well
  /// over 10 MB, and redacting that on the UI isolate would stall a frame.
  static Uint8List? buildZip({
    required String logPath,
    required String diagnostics,
  }) {
    final archive = Archive();
    for (final p in [logPath, '$logPath.old']) {
      final file = File(p);
      if (!file.existsSync()) continue;
      final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
      archive.addFile(
        ArchiveFile.string(path.basename(p), redactSecrets(text)),
      );
    }
    if (archive.isEmpty) return null;
    archive.addFile(ArchiveFile.string('diagnostics.txt', diagnostics));
    return ZipEncoder().encodeBytes(archive);
  }

  static Future<String> _diagnostics(
    String? systemsVersion,
    String logPath,
  ) async {
    final lines = <String>[
      'NeoStation log export',
      'Exported: ${DateTime.now().toUtc().toIso8601String()}',
    ];
    try {
      final info = await PackageInfo.fromPlatform();
      lines.add(
        'App: ${info.version}+${info.buildNumber} (${info.packageName})',
      );
    } catch (_) {}
    if (systemsVersion != null && systemsVersion.isNotEmpty) {
      lines.add('Systems: $systemsVersion');
    }
    lines.add(
      'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        lines.add(
          'Device: ${a.manufacturer} ${a.model} (${a.device}), '
          'Android ${a.version.release} / SDK ${a.version.sdkInt}, '
          'RAM ${a.physicalRamSize} MB',
        );
      } else if (Platform.isWindows) {
        final w = await plugin.windowsInfo;
        lines.add(
          'Device: ${w.productName} build ${w.buildNumber}, '
          'RAM ${w.systemMemoryInMegabytes} MB',
        );
      } else if (Platform.isMacOS) {
        final m = await plugin.macOsInfo;
        lines.add('Device: ${m.model} (${m.arch}), macOS ${m.osRelease}');
      } else if (Platform.isLinux) {
        final l = await plugin.linuxInfo;
        lines.add('Device: ${l.prettyName}');
      }
    } catch (_) {}
    lines.add('Log file: $logPath');
    return '${redactSecrets(lines.join('\n'))}\n';
  }

  static Future<String?> _downloadsPath() async {
    try {
      return (await getDownloadsDirectory())?.path;
    } catch (_) {
      return null;
    }
  }

  static String _timestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
