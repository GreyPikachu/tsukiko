import 'dart:io';

import '../core/app_locale.dart';
import 'os.dart';

/// Windows: как здесь устроено всё, что описано в `os.dart`.
///
/// Ничего, кроме этого файла, про пути реестра, `tasklist`, `taskkill`,
/// `explorer` и `ffmpeg` на Windows знать не должно.
class WindowsOs implements Os {
  @override
  String get home =>
      Platform.environment['USERPROFILE'] ??
      (Platform.environment['HOMEDRIVE'] != null &&
              Platform.environment['HOMEPATH'] != null
          ? '${Platform.environment['HOMEDRIVE']}${Platform.environment['HOMEPATH']}'
          : r'C:\');

  @override
  String get supportDir =>
      join(Platform.environment['APPDATA'] ?? home, bundleId);

  @override
  String get defaultLibraryPath => join(home, 'Documents', appName);

  @override
  String get documentsDir => join(home, 'Documents');

  @override
  List<String> get sharedModelDirs => [
        join(home, '.cache', 'whisper'),
        if (Platform.environment['LOCALAPPDATA'] != null)
          join(Platform.environment['LOCALAPPDATA']!, 'whisper'),
      ];

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  String join(String a, [String? b, String? c]) => [a, ?b, ?c].join(r'\');

  @override
  String basename(String path) {
    final norm = path.replaceAll('/', r'\');
    final at = norm.lastIndexOf(r'\');
    return at < 0 ? norm : norm.substring(at + 1);
  }

  @override
  String dirname(String path) {
    final norm = path.replaceAll('/', r'\');
    final at = norm.lastIndexOf(r'\');
    return at <= 0 ? norm : norm.substring(0, at);
  }

  // ── чем считать ───────────────────────────────────────────────────────────

  /// Поиск исполняемого файла на Windows с учётом стандартных расширений (.exe, .cmd, .bat).
  @override
  String? findExecutable(String name) {
    final extensions = name.contains('.') ? [''] : ['', '.exe', '.cmd', '.bat'];
    final dirs = [
      ...?Platform.environment['PATH']?.split(';'),
      if (Platform.environment['LOCALAPPDATA'] != null)
        join(Platform.environment['LOCALAPPDATA']!, 'Programs'),
      if (Platform.environment['ProgramFiles'] != null)
        Platform.environment['ProgramFiles']!,
    ];

    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      for (final ext in extensions) {
        final path = join(dir, '$name$ext');
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  /// Где внутри самого приложения лежит движок whisper.cpp на Windows.
  ///
  /// У Windows это папка Engine рядом с .exe (или сама папка рядом с исполняемым файлом).
  @override
  String get engineDir {
    final appDir = dirname(Platform.resolvedExecutable);
    final sub = join(appDir, 'Engine');
    return Directory(sub).existsSync() ? sub : appDir;
  }

  @override
  String get whisperInstallHint => currentL10n().whisperInstallHint;

  // ── как система называет свои вещи ────────────────────────────────────────

  @override
  String get fileManagerName => 'Проводник';

  static const _modLabels = {
    'fn': 'Fn',
    'ctrl': 'Ctrl',
    'alt': 'Alt',
    'opt': 'Alt',
    'shift': 'Shift',
    'cmd': 'Win',
    'win': 'Win',
  };

  static const _modOrder = ['ctrl', 'alt', 'shift', 'win', 'fn'];

  @override
  String modifierLabel(String mod) => _modLabels[mod.toLowerCase()] ?? mod;

  @override
  String get appIconAreaName => 'панель задач';

  @override
  String get menuBarName => 'область уведомлений';

  @override
  String get settingsShortcut => 'Ctrl+,';

  @override
  String get accessibilityName => 'специальные возможности';

  @override
  String shortcutLabel(List<String> mods, [List<String> keys = const []]) {
    final ordered = [
      ..._modOrder.where(mods.contains),
      ...mods.where((m) => !_modOrder.contains(m)),
    ];
    return [...ordered.map(modifierLabel), ...keys].join(' + ');
  }

  // ── звук ──────────────────────────────────────────────────────────────────

  /// Перекладывание любого звука в 16 кГц моно WAV через ffmpeg.
  ///
  /// Сначала проверяется легковесный встроенный ffmpeg.exe из engineDir,
  /// затем системный ffmpeg из PATH. Если конвертация не удалась или ffmpeg
  /// отсутствует — возвращаем исходный файл, пусть whisper попробует сам.
  @override
  Future<String> toWav(String src, String dst) async {
    final bundledFfmpeg = join(engineDir, 'ffmpeg.exe');
    final ffmpeg = File(bundledFfmpeg).existsSync()
        ? bundledFfmpeg
        : (findExecutable('ffmpeg') ?? 'ffmpeg');

    try {
      final r = await Process.run(ffmpeg, [
        '-y',
        '-i',
        src,
        '-vn',
        '-ar',
        '16000',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        dst,
      ]);
      return (r.exitCode == 0 && File(dst).existsSync()) ? dst : src;
    } catch (_) {
      return src;
    }
  }

  // ── процессы ──────────────────────────────────────────────────────────────

  @override
  bool isAlive(int pid) {
    try {
      final r = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
      final out = (r.stdout as String).trim();
      return out.isNotEmpty &&
          out.contains('$pid') &&
          !out.contains('No tasks') &&
          !out.contains('нет задач');
    } catch (_) {
      return false;
    }
  }

  @override
  void signal(int pid, {bool force = false}) {
    try {
      Process.runSync('taskkill', [if (force) '/F', '/PID', '$pid']);
    } catch (_) {}
  }

  @override
  Future<List<ProcListing>> listProcesses() async {
    try {
      final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      final out = <ProcListing>[];
      for (final line in (r.stdout as String).split('\r\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        // Формат строки CSV: "imagename.exe","pid","session","session#","mem K"
        final cols = trimmed
            .split('","')
            .map((s) => s.replaceAll('"', '').trim())
            .toList();
        if (cols.length < 5) continue;
        final pid = int.tryParse(cols[1]);
        if (pid == null) continue;
        final memStr = cols[4].replaceAll(RegExp(r'[^\d]'), '');
        final memKb = int.tryParse(memStr) ?? 0;
        out.add((
          pid: pid,
          rssKb: memKb,
          args: cols[0],
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<int> footprintMb(int pid) async {
    try {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      final out = (r.stdout as String).trim();
      if (out.isEmpty || !out.contains('$pid')) return 0;
      final cols = out.split('","').map((s) => s.replaceAll('"', '').trim()).toList();
      if (cols.length >= 5) {
        final memStr = cols[4].replaceAll(RegExp(r'[^\d]'), '');
        final memKb = int.tryParse(memStr) ?? 0;
        return (memKb / 1024).round();
      }
    } catch (_) {}
    return 0;
  }

  // ── система ───────────────────────────────────────────────────────────────

  @override
  Future<bool> reveal(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return false;
      if (type == FileSystemEntityType.directory) {
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('explorer.exe', ['/select,', path]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void onTerminate(void Function() onSignal) {
    // ProcessSignal.sigterm на Windows не поддерживается и бросает UnsupportedError.
    // Перехватываем SIGINT (Ctrl+C / закрытие консоли).
    try {
      ProcessSignal.sigint.watch().listen((_) => onSignal());
    } catch (_) {}
  }
}
