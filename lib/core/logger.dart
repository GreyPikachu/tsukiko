import 'dart:io';

import '../platform/os.dart';
import 'library.dart' show revealInFinder, supportDir;

/// Уровни журналирования.
enum LogLevel {
  verbose('VERBOSE'),
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR');

  final String label;
  const LogLevel(this.label);
}

/// Подсистема единого структурированного журнала Tsukiko.
///
/// Записывает события работы приложения в файл `tsukiko.log` в папке данных
/// приложения и дублирует их в `stderr` при работе из терминала.
///
/// Безопасна к сбоям диска: ошибки записи никогда не роняют приложение.
/// При превышении 5 МБ журнал ротируется в `tsukiko.1.log`.
class Log {
  Log._();

  static const int defaultMaxSizeBytes = 5 * 1024 * 1024; // 5 MB
  static int maxSizeBytes = defaultMaxSizeBytes;
  static bool printToStderr = true;
  static bool enabled = true;
  static String? _customLogsDir;

  /// Папка с журналами работы приложения.
  static String get logsDir =>
      _customLogsDir ?? os.join(supportDir, 'logs');

  /// Полный путь к активному файлу журнала.
  static String get logFilePath => os.join(logsDir, 'tsukiko.log');

  /// Активный файл журнала.
  static File get logFile => File(logFilePath);

  /// Архивный ротированный файл журнала.
  static File get rotatedFile => File(os.join(logsDir, 'tsukiko.1.log'));

  /// Открыть папку с журналами в Finder или Проводнике.
  static Future<bool> openLogsFolder() async {
    return revealInFinder(logsDir, createIfMissing: true);
  }

  static void verbose(String tag, String msg) =>
      log(LogLevel.verbose, tag, msg);

  static void debug(String tag, String msg) =>
      log(LogLevel.debug, tag, msg);

  static void info(String tag, String msg) =>
      log(LogLevel.info, tag, msg);

  static void warn(String tag, String msg, [Object? error, StackTrace? stack]) =>
      log(LogLevel.warn, tag, msg, error, stack);

  static void error(String tag, String msg, [Object? error, StackTrace? stack]) =>
      log(LogLevel.error, tag, msg, error, stack);

  static void log(
    LogLevel level,
    String tag,
    String msg, [
    Object? error,
    StackTrace? stack,
    DateTime? now,
  ]) {
    if (!enabled) return;

    final entry = formatRecord(level, tag, msg, error, stack, now);

    if (printToStderr) {
      try {
        stderr.writeln(entry);
      } catch (_) {}
    }

    _writeEntry(entry);
  }

  static String formatRecord(
    LogLevel level,
    String tag,
    String msg, [
    Object? error,
    StackTrace? stack,
    DateTime? now,
  ]) {
    final timestamp = formatTimestamp(now ?? DateTime.now());
    final formattedTag = _formatTag(tag);
    final formattedMsg = _formatMessage(msg, error, stack);
    return '[$timestamp] [${level.label}] $formattedTag $formattedMsg';
  }

  static String _formatTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return '[]';
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) return trimmed;
    return '[$trimmed]';
  }

  static String _formatMessage(String msg, Object? error, StackTrace? stack) {
    final sb = StringBuffer(msg);
    if (error != null) {
      if (sb.isNotEmpty) sb.write(': ');
      sb.write(error);
    }
    if (stack != null) {
      sb.write('\n$stack');
    }
    return sb.toString();
  }

  static String formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$y-$m-$d $h:$min:$s.$ms';
  }

  static void _writeEntry(String entry) {
    try {
      final file = logFile;
      final dir = file.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _checkRotation(file);
      file.writeAsStringSync('$entry\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Запись журнала никогда не должна ронять приложение
    }
  }

  static void _checkRotation(File file) {
    try {
      if (file.existsSync() && file.lengthSync() >= maxSizeBytes) {
        final rot = rotatedFile;
        if (rot.existsSync()) {
          rot.deleteSync();
        }
        file.renameSync(rot.path);
      }
    } catch (_) {}
  }

  /// Сброс параметров для модульных тестов.
  static void resetForTesting({
    String? customLogsDir,
    int? maxBytes,
    bool? stderr,
    bool? enabled,
  }) {
    _customLogsDir = customLogsDir;
    maxSizeBytes = maxBytes ?? defaultMaxSizeBytes;
    if (stderr != null) printToStderr = stderr;
    Log.enabled = enabled ?? true;
  }
}
