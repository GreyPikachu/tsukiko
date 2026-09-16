import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/logger.dart';

void main() {
  group('Log formatting', () {
    test('formats log entry with timestamp, level, tag, and message', () {
      final date = DateTime(2026, 9, 16, 17, 35, 12, 123);
      final formatted = Log.formatRecord(
        LogLevel.info,
        'Engine',
        'nemo-speech serve started with pid 1234 on port 54321',
        null,
        null,
        date,
      );
      expect(
        formatted,
        '[2026-09-16 17:35:12.123] [INFO] [Engine] nemo-speech serve started with pid 1234 on port 54321',
      );
    });

    test('normalizes tags with and without brackets', () {
      final date = DateTime(2026, 1, 2, 3, 4, 5, 6);
      expect(
        Log.formatRecord(LogLevel.debug, 'App', 'test', null, null, date),
        '[2026-01-02 03:04:05.006] [DEBUG] [App] test',
      );
      expect(
        Log.formatRecord(LogLevel.warn, '[App]', 'test', null, null, date),
        '[2026-01-02 03:04:05.006] [WARN] [App] test',
      );
      expect(
        Log.formatRecord(LogLevel.verbose, '', 'test', null, null, date),
        '[2026-01-02 03:04:05.006] [VERBOSE] [] test',
      );
    });

    test('includes error and stack trace when provided', () {
      final date = DateTime(2026, 9, 16, 12, 0, 0, 0);
      final stack = StackTrace.fromString('line 1\nline 2');
      final formatted = Log.formatRecord(
        LogLevel.error,
        'Queue',
        'Task failed',
        'ProcessException: failed to start',
        stack,
        date,
      );
      expect(
        formatted,
        '[2026-09-16 12:00:00.000] [ERROR] [Queue] Task failed: ProcessException: failed to start\nline 1\nline 2',
      );
    });
  });

  group('Log file operations and rotation', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('tsukiko-logger-test');
      Log.resetForTesting(
        customLogsDir: tmpDir.path,
        maxBytes: Log.defaultMaxSizeBytes,
        stderr: false,
      );
    });

    tearDown(() {
      Log.resetForTesting();
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('creates log directory and file on first write', () {
      expect(Log.logFile.existsSync(), isFalse);

      Log.info('App', 'Application started');

      expect(Log.logFile.existsSync(), isTrue);
      final lines = Log.logFile.readAsLinesSync();
      expect(lines.length, 1);
      expect(lines.first, contains('[INFO] [App] Application started'));
    });

    test('appends multiple log entries across different levels', () {
      Log.verbose('Engine', 'verbose trace');
      Log.debug('Engine', 'debug trace');
      Log.info('Engine', 'server ready');
      Log.warn('Engine', 'slow startup');
      Log.error('Engine', 'crash occurred', 'ExitCode: 1');

      final lines = Log.logFile.readAsLinesSync();
      expect(lines.length, 5);
      expect(lines[0], contains('[VERBOSE] [Engine] verbose trace'));
      expect(lines[1], contains('[DEBUG] [Engine] debug trace'));
      expect(lines[2], contains('[INFO] [Engine] server ready'));
      expect(lines[3], contains('[WARN] [Engine] slow startup'));
      expect(lines[4], contains('[ERROR] [Engine] crash occurred: ExitCode: 1'));
    });

    test('rotates to tsukiko.1.log when exceeding maxSizeBytes', () {
      Log.resetForTesting(
        customLogsDir: tmpDir.path,
        maxBytes: 120, // low threshold for testing rotation
        stderr: false,
      );

      Log.info('App', 'Initial entry 1');
      expect(Log.logFile.existsSync(), isTrue);
      expect(Log.rotatedFile.existsSync(), isFalse);

      Log.info('App', 'Initial entry 2 to exceed 120 bytes limit threshold');
      expect(Log.logFile.lengthSync(), greaterThanOrEqualTo(120));

      // The next entry should trigger rotation
      Log.info('App', 'Rotated entry 3');

      expect(Log.rotatedFile.existsSync(), isTrue);
      final rotatedContent = Log.rotatedFile.readAsStringSync();
      expect(rotatedContent, contains('Initial entry 1'));
      expect(rotatedContent, contains('Initial entry 2'));

      final currentContent = Log.logFile.readAsStringSync();
      expect(currentContent, contains('Rotated entry 3'));
      expect(currentContent, isNot(contains('Initial entry 1')));
    });

    test('replaces previous tsukiko.1.log upon second rotation', () {
      Log.resetForTesting(
        customLogsDir: tmpDir.path,
        maxBytes: 80,
        stderr: false,
      );

      Log.info('Test', 'Batch 1 - message one');
      Log.info('Test', 'Batch 1 - message two'); // exceeds 80

      Log.info('Test', 'Batch 2 - message one'); // triggers rotation #1
      expect(Log.rotatedFile.existsSync(), isTrue);
      expect(Log.rotatedFile.readAsStringSync(), contains('Batch 1'));

      Log.info('Test', 'Batch 2 - message two'); // exceeds 80 again
      Log.info('Test', 'Batch 3 - message one'); // triggers rotation #2

      expect(Log.rotatedFile.existsSync(), isTrue);
      expect(Log.rotatedFile.readAsStringSync(), contains('Batch 2'));
      expect(Log.rotatedFile.readAsStringSync(), isNot(contains('Batch 1')));
      expect(Log.logFile.readAsStringSync(), contains('Batch 3'));
    });

    test('never throws on write failures', () {
      // Point logs dir to an invalid or unwritable file path
      final dummyFile = File('${tmpDir.path}/not_a_dir');
      dummyFile.writeAsStringSync('block');

      Log.resetForTesting(
        customLogsDir: '${dummyFile.path}/logs',
        stderr: false,
      );

      // Must not throw
      expect(() => Log.info('Test', 'Safe failure'), returnsNormally);
    });
  });
}
