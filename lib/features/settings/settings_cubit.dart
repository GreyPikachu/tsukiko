import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/app_locale.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/transcript.dart';
import '../../core/whisper_server.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'settings_state.dart';

/// Окно настроек: расшифровщик, диктовка, склад моделей и приложение.
///
/// Вкладки разложены по хозяину настройки, и кубит повторяет ту же
/// раскладку: одна половина его значений принадлежит диктовке и лежит
/// в `dictation.json`, другая — расшифровщику и приложению и лежит
/// в `settings.json`. Модель расшифровщика кубит только читает: правит
/// её главное окно, и вторая рука на том же ключе стирала бы правки.
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
      models: scanModels(),
      vad: findVadModel(),
      clearVadModel: findVadModel() == null,
      // Модель расшифровщика окно только показывает: правит её главное
      // окно, и переписать её здесь значило бы драться с ним за один ключ.
      queueModel: (s['model'] as String?) ?? '',
      toLibrary: (s['toLibrary'] as bool?) ?? true,
      saveNextToSource: (s['saveNextToSource'] as bool?) ?? false,
      timestamps: (s['timestamps'] as bool?) ?? true,
      yieldBusyModel: (s['yieldBusyModel'] as bool?) ?? true,
      dockIcon: (s['dockIcon'] as bool?) ?? true,
      libraryPath: (s['libraryPath'] as String?) ?? defaultLibraryPath,
      locale: (s[localeSetting] as String?) ?? '',
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
  ///
  /// Одно и то же сочетание на оба действия назначить нельзя: «держать
  /// и говорить» и «нажать, ещё раз — остановить» тогда сработали бы
  /// вместе, и что из этого получится, не знает никто.
  Future<void> reassign(String id) async {
    final hk = await bridge.capture();
    if (hk == null) return;
    final other = id == 'hold' ? _dictation.toggle : _dictation.hold;
    if (hk.sameAs(other)) {
      return _emit(state.copyWith(
        problem: currentL10n().hotkeyTakenProblem(hk.label),
      ));
    }
    _emit(state.copyWith(clearProblem: true));
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

  /// Взять своим файлом модель диктовки.
  ///
  /// Именно диктовки: у расшифровщика такой же выбор есть в инспекторе
  /// главного окна, и кнопка на эту сторону стоит рядом с моделью
  /// диктовки, а не в общем списке моделей — там было непонятно, кому
  /// достаётся выбранный файл.
  ///
  /// Выбранный руками файл проверяем: «.bin» бывает чем угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры.
  void pickModel(String path) {
    final problem = modelFileProblem(path);
    if (problem != null) return _emit(state.copyWith(problem: problem));
    // Файл мог лежать за пределами обеих наших папок — тогда обход его
    // не найдёт, и в списке он появится только так.
    final known = state.models.any((m) => m.path == path);
    _emit(state.copyWith(
      clearProblem: true,
      models: known
          ? state.models
          : [
              ...state.models,
              InstalledModel(
                path: path,
                sizeBytes: File(path).existsSync() ? File(path).lengthSync() : 0,
                problem: null,
                ours: false,
              ),
            ],
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
      models: path != null ? scanModels() : null,
      vad: findVadModel(),
      clearVadModel: findVadModel() == null,
    ));
    // Список моделей стал другим — соседним окнам надо его перечитать.
    if (path != null) unawaited(bridge.settingsChanged());
  }

  void cancelDownload() => _download?.cancel();

  // ── расшифровщик и приложение ─────────────────────────────────────────────

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

  /// Язык интерфейса. Своё окно перерисовываем сразу, соседние узнают
  /// из общего файла: [refreshLocale] вызывается у всех на «reload».
  void setLocale(String v) {
    _emit(state.copyWith(locale: v));
    appLocale.value = v.isEmpty ? null : Locale(v);
    unawaited(_saveApp({localeSetting: v}));
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

  /// Убрать модель в Корзину.
  ///
  /// Не `unlink`: полтора гигабайта, стёртые по промаху, качать заново.
  /// Из Корзины файл возвращается средствами самой системы.
  ///
  /// Спрашивать здесь нечего — вопрос задаёт окно, кубит получает уже
  /// принятое решение.
  Future<void> deleteModel(String path) async {
    final gone = await bridge.trash(path);
    if (!gone) {
      return _emit(state.copyWith(
          problem: currentL10n().modelTrashFailed(path)));
    }
    // Выбранной эта модель быть больше не может.
    if (_dictation.model == path) {
      _saveDictation((d) => d.model = '');
    }
    _emit(state.copyWith(
      clearProblem: true,
      models: scanModels(),
      vad: findVadModel(),
      clearVadModel: findVadModel() == null,
    ));
    // Список моделей стал другим — соседним окнам надо его перечитать.
    unawaited(bridge.settingsChanged());
  }

  /// Показать папку моделей в проводнике: где они лежат, из интерфейса
  /// иначе не узнать. Папки может ещё не быть — заводим.
  Future<void> revealModelsFolder() =>
      revealInFinder(os.modelsDir, createIfMissing: true);

  /// Папку библиотеки человек мог ещё ни разу не наполнить.
  Future<void> revealLibrary(String path) =>
      revealInFinder(path, createIfMissing: true);

  /// Показать файл модели. Файл мог исчезнуть мимо приложения — тогда
  /// говорим об этом и обновляем список, а не открываем пустоту.
  Future<void> revealModel(String path) async {
    if (await revealInFinder(path)) return;
    _emit(state.copyWith(
      problem: currentL10n().modelFileGone(os.basename(path)),
      models: scanModels(),
      vad: findVadModel(),
      clearVadModel: findVadModel() == null,
    ));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    return super.close();
  }
}
