import 'dart:io';

import '../core/app_locale.dart';
import 'os.dart';

/// macOS: как здесь устроено всё, что описано в `os.dart`.
///
/// Ничего, кроме этого файла, про `ps`, `pgrep`, `lsof`, `afconvert`,
/// `open` и `~/Library` знать не должно.
class MacOs implements Os {
  @override
  String get home => Platform.environment['HOME'] ?? '/';

  @override
  String get supportDir => join(home, 'Library/Application Support', bundleId);

  @override
  String get defaultLibraryPath => join(home, 'Documents', appName);

  @override
  String get documentsDir => join(home, 'Documents');

  /// Общесистемный кеш whisper.cpp: туда модели кладут его собственные
  /// скрипты, и человек мог скачать модель мимо нас.
  @override
  List<String> get sharedModelDirs => [join(home, '.cache/whisper')];

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  String join(String a, [String? b, String? c]) => [a, ?b, ?c].join('/');

  @override
  String basename(String path) {
    final at = path.lastIndexOf('/');
    return at < 0 ? path : path.substring(at + 1);
  }

  @override
  String dirname(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? path : path.substring(0, at);
  }

  // ── чем считать ───────────────────────────────────────────────────────────

  /// Homebrew на Apple Silicon и на Intel кладёт бинарники в разные места,
  /// а собранный вручную whisper.cpp — куда угодно. Поэтому сначала PATH:
  /// раньше проверялись только два жёстко записанных пути, и у человека
  /// со своей сборкой приложение говорило «whisper-cli не найден».
  @override
  String? findExecutable(String name) {
    for (final dir in [
      ...?Platform.environment['PATH']?.split(':'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
    ]) {
      if (dir.isEmpty) continue;
      final path = join(dir, name);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  String get whisperInstallHint => currentL10n().whisperInstallHint;

  // ── как система называет свои вещи ────────────────────────────────────────

  @override
  String get fileManagerName => 'Finder';

  static const _modSymbols = {
    'fn': 'fn',
    'ctrl': '⌃',
    'opt': '⌥',
    'shift': '⇧',
    'cmd': '⌘',
  };

  /// Порядок значков в macOS закреплён: ⌃⌥⇧⌘, и никак иначе.
  static const _modOrder = ['fn', 'ctrl', 'opt', 'shift', 'cmd'];

  @override
  String modifierLabel(String mod) => _modSymbols[mod] ?? mod;

  @override
  String get appIconAreaName => 'Dock';

  @override
  String get menuBarName => currentL10n().menuBarNameLabel;

  @override
  String get settingsShortcut => '⌘,';

  @override
  String get accessibilityName => systemL10n().accessibilityPermissionName;

  @override
  String shortcutLabel(List<String> mods, [List<String> keys = const []]) {
    // Порядок наводим сами: захват сочетания приходит множеством, у него
    // порядка нет вовсе, и подпись могла прочитаться как «⌘ + fn».
    final ordered = [
      ..._modOrder.where(mods.contains),
      ...mods.where((m) => !_modOrder.contains(m)),
    ];
    return [...ordered.map(modifierLabel), ...keys].join(' + ');
  }

  // ── звук ──────────────────────────────────────────────────────────────────

  /// Штатный afconvert, ffmpeg не нужен. whisper-cli сам читает только
  /// wav/mp3/ogg-vorbis/flac и падает на opus, поэтому перекладываем всегда.
  @override
  Future<String> toWav(String src, String dst) async {
    try {
      final r = await Process.run(
          'afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', src, dst]);
      return (r.exitCode == 0 && File(dst).existsSync()) ? dst : src;
    } catch (_) {
      return src;
    }
  }

  // ── процессы ──────────────────────────────────────────────────────────────

  @override
  bool isAlive(int pid) {
    try {
      final r = Process.runSync('ps', ['-o', 'pid=', '-p', '$pid']);
      return (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void signal(int pid, {bool force = false}) {
    try {
      Process.killPid(
          pid, force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
    } catch (_) {}
  }

  static final _listingLine = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$');

  @override
  Future<List<ProcListing>> listProcesses() async {
    try {
      final ps = await Process.run('ps', ['-axo', 'pid=,rss=,args=']);
      final out = <ProcListing>[];
      for (final line in (ps.stdout as String).split('\n')) {
        final m = _listingLine.firstMatch(line);
        if (m == null) continue;
        out.add((
          pid: int.parse(m.group(1)!),
          rssKb: int.parse(m.group(2)!),
          args: m.group(3)!,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// `ps -o rss` занижает всё, что пришло через mmap, а модель приходит
  /// именно так; Мониторинг системы показывает phys_footprint, и в панели
  /// должно стоять то же число.
  @override
  Future<int> footprintMb(int pid) async {
    try {
      final r = await Process.run('footprint', ['-p', '$pid']);
      final m =
          RegExp(r'phys_footprint:\s*(\d+)\s*MB').firstMatch(r.stdout as String);
      if (m != null) return int.parse(m.group(1)!);
    } catch (_) {}
    return 0;
  }

  // ── система ───────────────────────────────────────────────────────────────

  /// Папку открываем, файл — показываем в папке и выделяем. Раньше и то
  /// и другое шло через `open`, и щелчок по файлу запускал его в проигрывателе.
  @override
  Future<bool> reveal(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return false;
      await Process.run(
          'open', type == FileSystemEntityType.directory ? [path] : ['-R', path]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void onTerminate(void Function() onSignal) {
    ProcessSignal.sigterm.watch().listen((_) => onSignal());
    ProcessSignal.sigint.watch().listen((_) => onSignal());
  }
}

/// «69:20.60», «1:02:03.4», «2-03:04:05» → секунды.
///
/// Формат поля TIME в выводе `ps` — то есть вещь юниксовая, и живёт она
/// здесь, а не в общем коде.
double? cpuSeconds(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  var days = 0;
  final dash = text.indexOf('-');
  if (dash > 0) {
    days = int.tryParse(text.substring(0, dash)) ?? 0;
    text = text.substring(dash + 1);
  }
  final parts = text.split(':');
  var total = double.tryParse(parts.last);
  if (total == null) return null;
  if (parts.length > 1) total += (int.tryParse(parts[parts.length - 2]) ?? 0) * 60;
  if (parts.length > 2) total += (int.tryParse(parts[parts.length - 3]) ?? 0) * 3600;
  return total + days * 86400;
}
