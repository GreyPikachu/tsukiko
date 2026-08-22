import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/transcript.dart';
import '../../core/whisper_server.dart';
import '../../platform/bridge.dart';
import 'settings_state.dart';

/// Окно настроек: сочетания клавиш, модели, библиотека и поведение
/// приложения.
///
/// Cubit, а не Bloc: каждое действие здесь — «поставить галку» или
/// «выбрать значение», отбрасывать и переупорядочивать нечего.
///
/// Настройки хранятся в двух файлах. Диктовка — в своём (`dictation.json`),
/// и правит его только это окно. Общие настройки лежат в `settings.json`,
/// который правят и главное окно тоже, — поэтому после каждой записи
/// соседним изолятам говорят перечитать файл. Без этого половина правок
/// доходила бы только до следующего запуска.
class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this.bridge) : super(const SettingsState()) {
    _dictation = DictationSettings.load();
    _subs.add(bridge.settingsReloaded.listen((_) => _readApp()));
    _subs.add(bridge.settingsTab.listen((t) => _emit(state.copyWith(tab: t))));
    _readApp();
    _readDictation();
    // Вкладку окно спрашивает само: сообщение об открытии приходит раньше,
    // чем этот изолят успевает подписаться на канал.
    unawaited(bridge.initialTab().then((t) => _emit(state.copyWith(tab: t))));
    unawaited(checkPermission());
  }

  final NativeBridge bridge;

  late DictationSettings _dictation;
  final _subs = <StreamSubscription<void>>[];
  Timer? _timer;
  Download? _download;

  /// Сколько раз подряд система ответила «разрешения нет».
  int _denied = 0;

  void _emit(SettingsState next) {
    if (!isClosed) emit(next);
  }

  // ── чтение с диска ────────────────────────────────────────────────────────

  void _readApp() {
    final s = Settings.load();
    // Раньше форматы хранились расширениями («.txt») — переводим в имена.
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    _emit(state.copyWith(
      models: findModels(),
      toLibrary: (s['toLibrary'] as bool?) ?? true,
      saveNextToSource: (s['saveNextToSource'] as bool?) ?? false,
      timestamps: (s['timestamps'] as bool?) ?? true,
      yieldBusyModel: (s['yieldBusyModel'] as bool?) ?? true,
      dockIcon: (s['dockIcon'] as bool?) ?? true,
      libraryPath: (s['libraryPath'] as String?) ?? defaultLibraryPath,
      libraryFormats:
          formats != null && formats.isNotEmpty ? formats : state.libraryFormats,
    ));
    // Автозапуск держит система, а не наш файл: его можно выключить
    // и в системных настройках, и галка обязана это показывать.
    unawaited(bridge.loginItem().then((on) => _emit(state.copyWith(loginItem: on))));
  }

  void _readDictation() => _emit(state.copyWith(
        hold: _dictation.hold,
        toggle: _dictation.toggle,
        dictationModel: _dictation.model,
        threads: _dictation.threads,
        punctuate: _dictation.punctuate,
        prompt: _dictation.prompt,
        idleSeconds: _dictation.idleSeconds,
        insert: _dictation.insert,
        hud: _dictation.hud,
      ));

  // ── запись на диск ────────────────────────────────────────────────────────

  /// Записи дожидаемся: соседи по «перечитать» тут же читают файл, и
  /// сказать им об этом раньше, чем правка на диске, значит послать их
  /// за старым значением.
  Future<void> _saveApp(Map<String, dynamic> data) async {
    await Settings.save(data);
    await bridge.settingsChanged();
  }

  void _saveDictation(void Function(DictationSettings) change) {
    change(_dictation);
    _dictation.save();
    _readDictation();
    unawaited(bridge.settingsChanged());
  }

  // ── разрешения ────────────────────────────────────────────────────────────

  /// Окно настроек закрывается, а не размонтируется — движок живёт дальше
  /// (см. SettingsWindow.swift). Поэтому опрос заводится и глушится по
  /// видимости: иначе он тикал бы до выхода из приложения.
  void setVisible(bool visible) {
    if (visible == (_timer != null)) return;
    if (!visible) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    // Разрешение выдают в другом приложении и возвращаются к этому окну:
    // спрашивать надо самим, уведомления об этом нет.
    unawaited(checkPermission());
    _timer =
        Timer.periodic(const Duration(seconds: 1), (_) => checkPermission());
  }

  /// Тот же счёт отказов, что и в панели: сразу после запуска система
  /// отвечает «нет» и тем, у кого разрешение выдано, — верить одному
  /// ответу нельзя, иначе предупреждение мигает на ровном месте.
  @visibleForTesting
  Future<void> checkPermission() async {
    final now = await bridge.permission();
    if (now) {
      _denied = 0;
      return _emit(state.copyWith(allowed: true));
    }
    if (++_denied < 3) return;
    _emit(state.copyWith(allowed: false));
  }

  Future<void> requestPermission() => bridge.requestPermission();

  Future<void> openPermissionSettings() => bridge.openPermissionSettings();

  // ── диктовка ──────────────────────────────────────────────────────────────

  void setTab(String tab) => _emit(state.copyWith(tab: tab));

  /// Назначение сочетания: следующая нажатая комбинация становится новой.
  Future<void> reassign(String id) async {
    final hk = await bridge.capture();
    if (hk == null) return;
    _saveDictation((d) => id == 'hold' ? d.hold = hk : d.toggle = hk);
  }

  void setDictationModel(String path) =>
      _saveDictation((d) => d.model = path);

  void setThreads(int n) => _saveDictation((d) => d.threads = n);

  void setPunctuate(bool v) => _saveDictation((d) => d.punctuate = v);

  void setPrompt(String v) => _saveDictation((d) => d.prompt = v);

  void setIdleSeconds(int v) => _saveDictation((d) => d.idleSeconds = v);

  void setInsert(bool v) => _saveDictation((d) => d.insert = v);

  void setHud(bool v) => _saveDictation((d) => d.hud = v);

  // ── модели ────────────────────────────────────────────────────────────────

  /// Выбранный руками файл проверяем: «.bin» бывает чем угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры.
  void pickModel(String path) {
    final problem = modelFileProblem(path);
    if (problem != null) return _emit(state.copyWith(problem: problem));
    _emit(state.copyWith(
      clearProblem: true,
      models: state.models.contains(path)
          ? state.models
          : [...state.models, path],
    ));
    setDictationModel(path);
  }

  /// Одна загрузка на окно: два полуторагиговых файла разом только мешают
  /// друг другу.
  Future<void> download(ModelOffer m) async {
    if (_download != null) return;
    final d = Download(m.url, m.path, title: m.title);
    _download = d;
    _emit(state.copyWith(
      downloadTitle: d.title,
      downloadProgress: d.progressLabel,
      downloadPercent: d.percent,
    ));
    final path = await d.run(onProgress: () {
      _emit(state.copyWith(
          downloadProgress: d.progressLabel, downloadPercent: d.percent));
    });
    _download = null;
    _emit(state.copyWith(
      clearDownload: true,
      models: path != null ? findModels() : null,
    ));
    // Список моделей стал другим — соседним окнам надо его перечитать.
    if (path != null) unawaited(bridge.settingsChanged());
  }

  void cancelDownload() => _download?.cancel();

  // ── библиотека и поведение ────────────────────────────────────────────────

  void setToLibrary(bool v) {
    _emit(state.copyWith(toLibrary: v));
    unawaited(_saveApp({'toLibrary': v}));
  }

  void setSaveNextToSource(bool v) {
    _emit(state.copyWith(saveNextToSource: v));
    unawaited(_saveApp({'saveNextToSource': v}));
  }

  void setTimestamps(bool v) {
    _emit(state.copyWith(timestamps: v));
    unawaited(_saveApp({'timestamps': v}));
  }

  void setYieldBusyModel(bool v) {
    _emit(state.copyWith(yieldBusyModel: v));
    unawaited(_saveApp({'yieldBusyModel': v}));
  }

  void setDockIcon(bool v) {
    _emit(state.copyWith(dockIcon: v));
    unawaited(_saveApp({'dockIcon': v}));
    unawaited(bridge.setDockIcon(v));
  }

  /// Ответ берём у системы, а не у себя: она могла и отказать.
  Future<void> setLoginItem(bool v) async {
    final on = await bridge.loginItem(v);
    _emit(state.copyWith(loginItem: on));
  }

  void setLibraryPath(String dir) {
    _emit(state.copyWith(libraryPath: dir));
    unawaited(_saveApp({'libraryPath': dir}));
  }

  /// Пустой набор при включённом сохранении означал бы тишину, поэтому
  /// последний формат снять нельзя.
  void toggleFormat(String id, bool on) {
    final next = [...state.libraryFormats];
    on ? next.add(id) : next.remove(id);
    final formats = next.isEmpty ? [id] : next;
    _emit(state.copyWith(libraryFormats: formats));
    unawaited(_saveApp({'libraryFormats': formats}));
  }

  Future<void> reveal(String path) => revealInFinder(path);

  @override
  Future<void> close() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    return super.close();
  }
}
