import 'dart:convert';
import 'dart:io';

import 'os.dart';

/// Windows: как здесь устроено всё, что описано в `os.dart`.
///
/// Ничего, кроме этого файла, про пути реестра, `tasklist`, `taskkill`,
/// `explorer` и `ffmpeg` на Windows знать не должно.
class WindowsOs implements Os {
  @override
  String get platformId => 'windows';

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

  /// Fn на Windows программам не видна: её разбирает прошивка
  /// клавиатуры. Берём то, что видно и не занято системой: Ctrl+Alt
  /// держать, Ctrl+Alt+Пробел переключать. Win+H занят своей диктовкой
  /// Windows, Ctrl+Shift — раскладкой.
  @override
  ({List<String> mods, List<String> keys}) get defaultHold =>
      (mods: const ['ctrl', 'alt'], keys: const []);

  @override
  ({List<String> mods, List<String> keys}) get defaultToggle =>
      (mods: const ['ctrl', 'alt'], keys: const ['space']);

  /// Vulkan-сборку можно запускать, только если в системе есть загрузчик
  /// Vulkan.
  ///
  /// Это не придирка, а условие запуска: ggml зовёт `vkGetInstanceProcAddr`
  /// напрямую и линкуется с `vulkan-1.dll` неявно, поэтому без неё Windows
  /// убивает процесс ещё до первой строки кода — до всякого «а поищу-ка я
  /// видеокарту». Своей обработки ошибок движку тут не достанется.
  ///
  /// Обратное неверно: загрузчик есть, а видеокарты подходящей нет — это
  /// уже не беда. Тогда ggml не находит устройство, ловит своё исключение
  /// и считает на процессоре тем же самым бинарником.
  ///
  /// Загрузчик кладут драйверы — и NVIDIA, и AMD, и Intel. Нет его там,
  /// где нет и драйвера: чистая установка на базовом видеоадаптере,
  /// виртуальные машины, серверные сборки Windows.
  ///
  /// проверка по файлу, а не запуском. Сломанный драйвер при
  /// живой библиотеке она пропустит; если такое всплывёт — пробовать
  /// запуском (`--version`) и запоминать ответ на весь сеанс.
  late final bool _vulkanUsable = File(join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'vulkan-1.dll'))
      .existsSync();

  /// Сборок движка две, и выбор между ними — не вкус, а совместимость.
  ///
  /// Vulkan берётся первым: он ускоряет на любой видеокарте — NVIDIA, AMD,
  /// Intel, — и при этом ничего не тянет за собой. CUDA дала бы то же
  /// самое только на NVIDIA и ценой сотен мегабайт своих библиотек
  /// (официальная сборка whisper.cpp с CUDA 12.4 весит 640 МБ против 8 МБ
  /// процессорной).
  ///
  /// Имя без суффикса — последнее в списке: так подхватится и сборка,
  /// сделанная руками, и та, что осталась от прежних версий.
  @override
  List<String> engineNames(String base) => [
        if (_vulkanUsable) '$base-vulkan.exe',
        '$base-cpu.exe',
        '$base.exe',
        base,
      ];

  // ── чем система рисует и что она спрашивает ───────────────────────────────

  @override
  bool get hasWindowMaterial => false;

  @override
  bool get hasSystemMenuBar => false;

  @override
  bool get needsAccessibilityPermission => false;

  // ── как система называет свои вещи ────────────────────────────────────────

  @override
  Future<void> openUrl(String url) async {
    // Через проводник, а не `start`: `start` — команда оболочки, и ей
    // нужен cmd со своими правилами разбора кавычек.
    await Process.run('explorer.exe', [url]);
  }

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
  String get settingsShortcut => 'Ctrl+,';

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

  /// Перечень процессов — вместе с их командными строками.
  ///
  /// Именно с ними, и это здесь главное. `tasklist` отдаёт только имя
  /// образа, а по имени свой сервер от чужого не отличить: у двух копий
  /// одной программы оно одинаковое. Свой узнаётся по метке в аргументах
  /// (см. `ourServersIn`), и без аргументов забытый сервер диктовки
  /// не нашёлся бы никогда — полтора гигабайта висели бы в памяти
  /// до перезагрузки.
  ///
  /// Поэтому PowerShell и CIM, а не `tasklist`. И не `wmic`: его из
  /// Windows 11 убрали. Зовётся это редко — при запуске и при подметании,
  /// — так что цена запуска PowerShell тут не в счёт.
  @override
  Future<List<ProcListing>> listProcesses() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        // Своё разделение полей: в командной строке бывают и запятые,
        // и кавычки, и CSV пришлось бы разбирать по-настоящему.
        r'Get-CimInstance Win32_Process | ForEach-Object { '
            r'"$($_.ProcessId)|$([int]($_.WorkingSetSize/1024))|$($_.CommandLine)" }',
      ]);
      final out = <ProcListing>[];
      for (final line in const LineSplitter().convert(r.stdout as String)) {
        final at = line.indexOf('|');
        if (at < 0) continue;
        final rest = line.indexOf('|', at + 1);
        if (rest < 0) continue;
        final pid = int.tryParse(line.substring(0, at).trim());
        if (pid == null) continue;
        out.add((
          pid: pid,
          rssKb: int.tryParse(line.substring(at + 1, rest).trim()) ?? 0,
          args: line.substring(rest + 1).trim(),
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
        // Именно одним доводом: `/select,` и путь — это части одного
        // ключа. Разными доводами проводник открывает «Документы»
        // и никого не выделяет.
        await Process.run('explorer.exe', ['/select,$path']);
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
