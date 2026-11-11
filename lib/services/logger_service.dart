import 'dart:io';
import 'package:logger/logger.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/utils/log_redaction.dart';

/// Supported log severity levels.
enum LogLevel { info, warning, error, debug }

/// Service responsible for application-wide logging with support for console
/// and file-based output.
///
/// Handles log rotation to prevent excessive disk usage and ensures that logs
/// are persisted across sessions for debugging purposes.
class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  static LoggerService get instance => _instance;

  Logger _logger;
  bool _initialized = false;

  /// Lines logged in this isolate since [startCapture], or null when nothing
  /// is collecting.
  List<String>? _captured;

  /// The most lines one capture holds. A capture exists to explain a single
  /// failure, and an unbounded list in a background isolate is a memory leak
  /// waiting for a pathological image.
  static const int _captureLimit = 64;

  /// Whether [init] has run and log output is reaching the file as well as the
  /// console.
  ///
  /// False in the secondary display's engine: it is a separate isolate with its
  /// own copy of this singleton, and its entry point ([subDisplay] in main.dart)
  /// deliberately does not call [init] — two isolates holding a FileOutput on
  /// the same path would interleave writes and race the rotation rename. Code
  /// that must not lose a line in that isolate should check this and fall back
  /// to `debugPrint`.
  bool get isFileBacked => _initialized;

  LoggerService._internal()
    : _logger = Logger(
        printer: RedactingPrinter(SimplePrinter(colors: true)),
        filter: ProductionFilter(),
        output: MultiOutput([ConsoleOutput()]),
      );

  /// Initializes the logger, sets up file output, and performs log rotation.
  ///
  /// Rotates the log file if it exceeds 5MB, keeping one historical copy (`.old`).
  Future<void> init() async {
    if (_initialized) return;

    try {
      final logFilePath = await ConfigService.getLogFilePath();
      final logFile = File(logFilePath);

      final logDir = logFile.parent;
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      if (await logFile.exists()) {
        final size = await logFile.length();
        if (size > 5 * 1024 * 1024) {
          final oldLogFile = File('$logFilePath.old');
          if (await oldLogFile.exists()) {
            await oldLogFile.delete();
          }
          await logFile.rename(oldLogFile.path);
        }
      }

      // FileOutput opens the file in the background (`openWrite`) and nothing
      // waits for it, so without this the file appeared some time after init
      // returned: a log export straight after a user-data move could find no
      // `app.log` in the new folder. Creating an existing file is a no-op, so
      // appending to it is unaffected.
      try {
        await logFile.create();
      } on FileSystemException catch (_) {
        // Best effort: a folder that refuses the file keeps the behaviour it
        // had before, where init still succeeds and only the background open
        // fails. [reinitialize] relies on that to move the log out of an
        // unwritable folder once the setup wizard resets away from it.
      }

      _logger = Logger(
        level: Level.info,
        printer: RedactingPrinter(SimplePrinter(colors: true)),
        filter: CustomProductionFilter(),
        output: MultiOutput([
          ConsoleOutput(),
          FileOutput(file: File(logFilePath)),
        ]),
      );

      _initialized = true;
      i('Logger initialized with file output: $logFilePath');
    } catch (e) {
      // ignore: avoid_print
      print('Error initializing file logger: $e');
    }
  }

  /// Starts collecting everything this isolate logs, on top of its normal
  /// output.
  ///
  /// For work handed to a background isolate. [init] runs in the main isolate
  /// only — a spawned one gets its own copy of this singleton with no file
  /// output, and two isolates holding a [FileOutput] on the same path would
  /// interleave writes and race the rotation rename, so it cannot simply open
  /// the file too. Capturing lets it hand its diagnostics back instead: the
  /// isolate calls this, returns [takeCapture] with its result, and the main
  /// isolate feeds that to [replayCaptured].
  void startCapture() => _captured = <String>[];

  /// Everything captured since [startCapture], and stops collecting.
  ///
  /// Each line carries a one-character level prefix so [replayCaptured] can
  /// restore the severity; the encoding is deliberately primitive because the
  /// list crosses an isolate boundary.
  List<String> takeCapture() {
    final captured = _captured ?? const <String>[];
    _captured = null;
    return captured;
  }

  /// Re-logs lines a background isolate captured, so they reach the log file.
  ///
  /// Anything already collecting here keeps collecting: replaying goes through
  /// [log] like any other line.
  void replayCaptured(Iterable<String> lines) {
    for (final line in lines) {
      if (line.length < 2 || line[1] != _captureSeparator) continue;
      log(line.substring(2), level: _levelForTag(line[0]));
    }
  }

  /// Separates a captured line's level tag from its message.
  static const String _captureSeparator = '|';

  static String _tagForLevel(LogLevel level) => switch (level) {
    LogLevel.info => 'i',
    LogLevel.warning => 'w',
    LogLevel.error => 'e',
    LogLevel.debug => 'd',
  };

  static LogLevel _levelForTag(String tag) => switch (tag) {
    'w' => LogLevel.warning,
    'e' => LogLevel.error,
    'd' => LogLevel.debug,
    _ => LogLevel.info,
  };

  /// Logs a message at the specified [LogLevel].
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final captured = _captured;
    if (captured != null && captured.length < _captureLimit) {
      final suffix = error == null ? '' : ' $error';
      captured.add('${_tagForLevel(level)}$_captureSeparator$message$suffix');
    }

    switch (level) {
      case LogLevel.info:
        _logger.i(message, error: error, stackTrace: stackTrace);
        break;
      case LogLevel.warning:
        _logger.w(message, error: error, stackTrace: stackTrace);
        break;
      case LogLevel.error:
        _logger.e(message, error: error, stackTrace: stackTrace);
        break;
      case LogLevel.debug:
        _logger.d(message, error: error, stackTrace: stackTrace);
        break;
    }
  }

  /// Logs a debug-level message.
  void d(String message) => log(message, level: LogLevel.debug);

  /// Logs an info-level message.
  void i(String message) => log(message, level: LogLevel.info);

  /// Logs a warning-level message.
  void w(String message) => log(message, level: LogLevel.warning);

  /// Logs an error-level message with optional error object and stack trace.
  void e(String message, {Object? error, StackTrace? stackTrace}) =>
      log(message, level: LogLevel.error, error: error, stackTrace: stackTrace);
}

/// Strips credentials from every formatted log line before it reaches an
/// output.
///
/// This wraps the printer rather than the log call sites on purpose: the worst
/// leaks come from error objects we never format ourselves — an HTTP client
/// exception carries the full request URI, query string included — so
/// redaction has to happen after the event is rendered and before it is
/// written to the console or the log file.
class RedactingPrinter extends LogPrinter {
  RedactingPrinter(this._inner);

  final LogPrinter _inner;

  @override
  List<String> log(LogEvent event) =>
      _inner.log(event).map(redactSecrets).toList();
}

/// Custom log filter that permits INFO level logs even in production/release environments.
class CustomProductionFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return event.level.index >= level!.index;
  }
}
