import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os.dart';

/// Подменить папки приложения временными на время теста.
///
/// Настройки, модели и pid-файл живут в настоящей папке пользователя,
/// и тесты писали прямо туда. Это плохо дважды: у человека затирались
/// его собственные настройки, а два тестовых файла, работая
/// одновременно, снимали и возвращали один и тот же файл, стирая снимки
/// друг друга, — отчего проверки падали через раз.
///
/// Пути после подмены берутся у самой `os`: `os.home`, `os.supportDir`,
/// `os.modelsDir`.
void useTempSupportDir([String prefix = 'tsukiko-test']) {
  late Directory root;
  late Os real;

  setUp(() {
    real = os;
    root = Directory.systemTemp.createTempSync(prefix);
    os = _TempOs(real, root.path);
    Directory(os.modelsDir).createSync(recursive: true);
  });

  tearDown(() {
    os = real;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });
}

/// Всё как в настоящей системе, но папки — во временной.
class _TempOs implements Os {
  _TempOs(this._real, this._root);
  final Os _real;
  final String _root;

  @override
  String get home => _root;

  @override
  String get supportDir => join(_root, 'Support');

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  String get defaultLibraryPath => join(_root, 'Documents', appName);

  @override
  String get documentsDir => join(_root, 'Documents');

  @override
  List<String> get sharedModelDirs => [join(_root, '.cache/whisper')];

  @override
  String join(String a, [String? b, String? c]) => _real.join(a, b, c);

  @override
  String basename(String p) => _real.basename(p);

  @override
  String dirname(String p) => _real.dirname(p);

  @override
  String? findExecutable(String name) => _real.findExecutable(name);

  @override
  String get whisperInstallHint => _real.whisperInstallHint;

  @override
  String get fileManagerName => _real.fileManagerName;

  @override
  String get appIconAreaName => _real.appIconAreaName;

  @override
  String get menuBarName => _real.menuBarName;

  @override
  String get settingsShortcut => _real.settingsShortcut;

  @override
  String get accessibilityName => _real.accessibilityName;

  @override
  String modifierLabel(String mod) => _real.modifierLabel(mod);

  @override
  String shortcutLabel(List<String> mods, [List<String> keys = const []]) =>
      _real.shortcutLabel(mods, keys);

  @override
  Future<String> toWav(String src, String dst) => _real.toWav(src, dst);

  @override
  bool isAlive(int pid) => _real.isAlive(pid);

  @override
  void signal(int pid, {bool force = false}) =>
      _real.signal(pid, force: force);

  @override
  Future<List<int>> holdersOf(List<String> paths) => _real.holdersOf(paths);

  @override
  Future<List<int>> pidsMatching(String pattern) => _real.pidsMatching(pattern);

  @override
  Future<List<int>> pidsNamed(String name) => _real.pidsNamed(name);

  @override
  Future<List<ProcSample>> sample(Iterable<int> pids) => _real.sample(pids);

  @override
  Future<List<ProcListing>> listProcesses() => _real.listProcesses();

  @override
  Future<int> footprintMb(int pid) => _real.footprintMb(pid);

  @override
  Future<bool> reveal(String path) async => false;

  @override
  String? appOwnerOf(String path) => _real.appOwnerOf(path);

  @override
  void onTerminate(void Function() onSignal) {}
}
