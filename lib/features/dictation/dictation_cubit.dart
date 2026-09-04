import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../platform/bridge.dart';
import '../../core/whisper_server.dart';
import 'dictation_state.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/whisper.dart';
import '../../platform/os.dart';
import '../../core/settings.dart';
import '../../core/app_locale.dart';
import '../../core/labels.dart';

/// Диктовка целиком: перехват клавиш, запись, сервер с моделью, вставка
/// текста и то, что из этого видно в панели.
///
/// Cubit, а не Bloc с событиями: взаимодействия здесь прямые — нажали
/// клавишу, значит начать запись. Заводить под каждое действие класс
/// события было бы церемонией без выгоды. Полный Bloc припасён для
/// очереди распознавания, где события действительно нужны.
///
/// Службы (`WhisperServer`, `NativeBridge`, таймеры) — поля этого класса;
/// наружу уходит только [DictationState], в котором одни значения.
class DictationCubit extends Cubit<DictationState> {
  /// [server] подменяют только тесты: настоящий поднимает whisper-server
  /// и читает в память полтора гигабайта, а проверять надо не это.
  DictationCubit(this.bridge, {WhisperServer? server})
      : super(const DictationState()) {
    _server = server ??
        WhisperServer(idleTimeout: Duration(seconds: _settings.idleSeconds));
    _server.onChanged = _onServerChanged;

    bridge.events.listen(_onHotkey);
    // Кнопки плавающей панели — те же действия, что и клавишами, плюс
    // отмена уже идущего распознавания, которой у клавиш нет.
    bridge.hudActions.listen((a) => switch (a) {
          'cancel' => cancel(),
          'abort' => abortTranscription(),
          _ => stop(),
        });
    bridge.panelShown.listen((_) => _onPanelShown());
    bridge.panelHidden.listen((_) => _onPanelHidden());
    // Очередь спрашивает, можно ли забрать модель. Отвечаем мы: диктовка
    // главнее — она короткая, а очередь подождёт и продолжит сама.
    bridge.onStatusAsked = _statusForQueue;
    bridge.onReleaseAsked = _releaseModel;
    // Те же настройки правит окно настроек — там они и живут.
    bridge.settingsReloaded.listen((_) => _reloadSettings());

    unawaited(_apply());
    unawaited(_ensureVad());
    // Сервер мог пережить падение приложения: полтора гигабайта, которые
    // иначе не вернёт никто. Ищем по метке в аргументах — pid-файла после
    // падения может не быть вовсе. Не синхронно на старте, а фоном: `ps`
    // и добивание процессов задерживали первый кадр панели на полсекунды.
    _sweeping = _sweepOrphans();

    // Подписки и таймер живут ровно столько же, сколько само приложение:
    // движок панели не выгружается никогда, отменять их негде и незачем.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    os.onTerminate(_bye);
  }

  final NativeBridge bridge;

  /// Службы живут дольше одного снимка и отвечают когда угодно: процесс
  /// сервера может умереть уже после того, как кубит закрыли. В приложении
  /// он не закрывается никогда, а в тестах — на каждом шаге.
  void _emit(DictationState next) {
    if (!isClosed) emit(next);
  }

  late final WhisperServer _server;
  DictationSettings _settings = DictationSettings.load();

  Timer? _ticker;
  Timer? _meter;

  /// Поповер на экране. Всё, что считается только для него, — уровень
  /// сигнала и память сервера, — пока он закрыт, не считается вовсе.
  bool _panelVisible = false;

  /// Сколько раз подряд система ответила «разрешения нет».
  int _denied = 0;

  /// Сколько тиков прошло с прошлого замера памяти.
  int _sinceFootprint = 0;

  List<String> _models = findModels();
  Download? _vadDownload;
  String? _wav;
  DateTime? _startedAt;

  /// Распознавание прервали крестиком. Отличать это от неудачи обязательно:
  /// «не получилось» и «я сам передумал» — разные новости.
  bool _aborted = false;

  /// Идущий подбор сирот и идущий подъём сервера под нынешнюю запись.
  Future<void>? _sweeping;
  Future<void>? _bringingUp;

  /// Начало записи в полёте и просьба остановиться, пришедшая раньше,
  /// чем оно закончилось.
  ///
  /// Между «нажали клавишу» и «микрофон пишет» проходит время: система
  /// спрашивает разрешение, `AVAudioRecorder` заводится. Короткое нажатие
  /// успевало отпуститься в этом промежутке — `stop` видел фазу «покой»
  /// и выходил ни с чем, а `start` следом ставил «запись». Панель после
  /// этого писала «Записываю» вечно, хотя микрофон уже молчал.
  Future<void>? _startingRecording;

  /// Чем кончить запись, которую попросили кончить, пока заводился
  /// микрофон: [stop] или [cancel]. Раньше это был один флаг «просили
  /// прекратить», и отмена на нём превращалась в обычную остановку —
  /// фраза уходила распознаваться и ложилась в «не удалось». Успеть
  /// нетрудно: fn+ctrl+opt разом не нажать, и отмена приходит через
  /// миллисекунды после начала.
  Future<void> Function()? _finishAfterStart;

  // ── настройки распознавания ────────────────────────────────────────────────

  /// Настройки диктовки — свои целиком, не общие с очередью: диктуют не то
  /// же, что расшифровывают, и одни значения на две стороны устраивали бы
  /// плохо обе. Из настроек очереди берётся одно — модель, и то лишь пока
  /// своя не выбрана: «как у расшифровщика» это и обещает.
  ///
  /// Язык всегда «авто»: диктуют на разных языках вперемешку, и выбирать
  /// его руками каждый раз некому. VAD включён всегда, независимо от галки
  /// в очереди: фразы короткие, и на секундах тишины whisper сочиняет
  /// «Продолжение следует…».
  RunOptions get _options => RunOptions(
        model: state.chosenModel,
        lang: 'auto',
        threads: _settings.threads,
        prompt: _settings.prompt,
        punctuate: _settings.punctuate,
        vad: _hasVad,
        vadModel: _hasVad ? vadModelPath : '',
      );

  bool _hasVad = false;

  /// Перечитать с диска то, что меняется редко, и отдать в состояние.
  ///
  /// Именно здесь, а не в геттерах: раньше `options` читал settings.json
  /// и проверял файл VAD, а звали его из `build` панели — во время записи
  /// это выходило десять чтений диска в секунду.
  DictationState _withSnapshots(DictationState from) {
    _hasVad = File(vadModelPath).existsSync();
    final queueModel = (Settings.load()['model'] as String?) ?? '';
    return from.copyWith(
      enabled: _settings.enabled,
      holdLabel: _settings.hold.label,
      toggleLabel: _settings.toggle.label,
      ownModel: _settings.model.isNotEmpty,
      chosenModel: _settings.model.isNotEmpty ? _settings.model : queueModel,
      models: _models,
    );
  }

  // ── жизненный цикл ─────────────────────────────────────────────────────────

  Future<Never> _bye() async {
    _ticker?.cancel();
    await _server.shutdown();
    // Свой сервер мы только что погасили; этот проход — на случай, если
    // рядом остался ещё один, о котором мы не знаем.
    await sweepOurServers();
    exit(0);
  }

  Future<void> _sweepOrphans() async {
    final freed = await sweepOurServers();
    if (freed > 0) _emit(state.copyWith(sweptMb: freed));
  }

  Future<void> _apply() async {
    // Родная сторона гасит сирот на выходе из приложения — признаки
    // «наш сервер» она должна брать у нас, а не держать свою копию.
    await bridge.setServerMarks(ourServerMarks);
    // Приложение всегда стартует со значком в Dock: LSUIElement в Info.plist
    // спрятал бы его навсегда, а настройка должна переключаться на лету.
    // Значит спрятать его может только Dart, и как можно раньше.
    await bridge.setDockIcon((Settings.load()['dockIcon'] as bool?) ?? true);
    await bridge.bind(hold: _settings.hold, toggle: _settings.toggle);
    _emit(_withSnapshots(state));
    await _checkPermission();
  }

  Future<void> _reloadSettings() async {
    final was = _settings;
    _settings = DictationSettings.load();
    // Модель в главном окне могли сменить — снимок обязан это увидеть
    // до сравнения ниже, иначе сервер останется на прежней.
    _models = findModels();
    _emit(_withSnapshots(state));
    _server.idleTimeout = Duration(seconds: _settings.idleSeconds);
    // Всё, с чем сервер запускается, он читает один раз — значит новое
    // увидит только с новым запуском. Память отдаём сразу, поднимется
    // он снова на следующей фразе.
    //
    // Модель сравниваем не по своей настройке, а по той, с которой сервер
    // поднят: при «как у расшифровщика» своя настройка пуста и до и после,
    // а модель под ней сменилась в главном окне — и диктовка молча
    // продолжала бы говорить старой.
    if (was.prompt != _settings.prompt ||
        was.punctuate != _settings.punctuate ||
        was.threads != _settings.threads ||
        (_server.up && _server.model != _options.model)) {
      unawaited(_server.shutdown());
    }
    await _apply();
  }

  /// «Разрешения нет» — вывод не с первой попытки. Сразу после запуска
  /// система отвечает «нет» и тем, кто всё давно разрешил: процесс ещё
  /// не осел. Плашка на пустом месте пугает зря, поэтому верим только
  /// нескольким отказам подряд, а любому «да» — сразу.
  @visibleForTesting
  Future<void> checkPermission() => _checkPermission();

  Future<void> _checkPermission() async {
    final now = await bridge.permission();
    if (now) {
      _denied = 0;
      _emit(state.copyWith(allowed: true));
      return;
    }
    if (++_denied < 3) return;
    _emit(state.copyWith(allowed: false));
  }

  Future<void> _onPanelShown() async {
    _panelVisible = true;
    _forgetGoneRecording();
    _models = findModels();
    _emit(_withSnapshots(state));
    _syncMeter();
    await _checkPermission();
  }

  void _onPanelHidden() {
    _panelVisible = false;
    _syncMeter();
  }

  void _onServerChanged() => _emit(state.copyWith(
        serverUp: _server.up,
        memoryMb: _server.up ? state.memoryMb : 0,
        untilUnload: _server.untilUnload,
        clearUnload: _server.untilUnload == null,
      ));

  Future<void> _tick() async {
    // Спрашиваем о разрешении каждую секунду: человек уходит выдавать его
    // в другое приложение и возвращается к открытой панели. Тот же вопрос
    // заново создаёт перехват клавиш — без перезапуска. Стоит это одного
    // обращения к системе, подпроцессов не запускает.
    await _checkPermission();
    if (isClosed) return;

    if (!_server.up) {
      _sinceFootprint = 0;
      return;
    }

    // Обратный отсчёт — простая арифметика, и считать её надо всегда.
    // Раньше он был за тем же гейтом, что и замер памяти: панель открывали
    // и видели «освободится через 2:35», застывшее с прошлого раза, — а во
    // время диктовки модель вообще никуда не освобождается, её держит аренда.
    _emit(state.copyWith(
      untilUnload: _server.untilUnload,
      clearUnload: _server.untilUnload == null,
    ));

    // А вот память сервера считает отдельная утилита, то есть целый процесс
    // на каждый замер. Вот его и придерживаем: число видно только в панели.
    if (!_panelVisible) {
      _sinceFootprint = 0;
      return;
    }

    // Обратный отсчёт до выгрузки идёт на экране и обязан тикать каждую
    // секунду. Раньше он замирал: тик обновлял экран только когда менялось
    // число мегабайт, а память между замерами стоит на месте.
    _emit(state.copyWith(untilUnload: _server.untilUnload));

    // Память сервера считает отдельная утилита, то есть целый процесс
    // на каждый замер. Раз в секунду это была самая дорогая мелочь
    // в простое, поэтому раз в пять и только при открытом поповере.
    if (_sinceFootprint++ % 5 != 0) return;
    final mb = await _server.footprintMb();
    if (!isClosed) _emit(state.copyWith(memoryMb: mb));
  }

  /// Модель тишины весит меньше мегабайта и качается один раз. Не вышло —
  /// диктуем без неё: галлюцинации на тишине хуже, чем ничего, но молчащая
  /// диктовка хуже вдвойне.
  Future<void> _ensureVad() async {
    if (File(vadModelPath).existsSync() || _vadDownload != null) return;
    final d = Download(vadModelUrl, vadModelPath);
    _vadDownload = d;
    _emit(state.copyWith(vadProgress: d.progressLabel, clearVad: true));
    final path = await d.run(
      onProgress: () {
        if (!isClosed) _emit(state.copyWith(vadProgress: d.progressLabel));
      },
    );
    _vadDownload = null;
    _hasVad = path != null;
    if (isClosed) return;
    _emit(state.copyWith(clearVad: true, vadError: path == null ? d.error : null));
  }

  /// Повтор после неудачи. Недокачанное лежит в «.part», так что второй
  /// заход продолжит с того же места, а не начнёт сначала.
  Future<void> retryVad() => _ensureVad();

  // ── запись ─────────────────────────────────────────────────────────────────

  void _onHotkey(HotkeyEvent e) {
    if (!_settings.enabled) return;
    // Поверх сочетания набрали лишнее — значит целили не в диктовку.
    // Начатое выбрасываем, и панель уходит сразу.
    if (e.cancel) {
      cancel();
      return;
    }
    if (e.id == 'hold') {
      e.edge == HotkeyEdge.down ? start() : stop();
      return;
    }
    if (e.edge == HotkeyEdge.down) {
      state.recording ? stop() : start();
    }
  }

  Future<void> start() async {
    if (state.phase != Phase.idle || _startingRecording != null) return;
    _finishAfterStart = null;
    _startingRecording = _beginRecording();
    try {
      await _startingRecording;
    } finally {
      _startingRecording = null;
    }
    // Пока заводился микрофон, клавишу успели отпустить — или набрать
    // поверх лишнюю, и тогда это была не остановка, а отмена.
    final finish = _finishAfterStart;
    _finishAfterStart = null;
    if (finish != null) await finish();
  }

  Future<void> _beginRecording() async {
    _aborted = false;
    _emit(state.copyWith(clearFailure: true));

    // Сервер поднимается параллельно записи: пока человек говорит, модель
    // успевает загрузиться, и после отпускания клавиши ждать уже нечего.
    // Аренда держит его живым всю запись: без неё таймер простоя выгружал
    // модель посреди длинной фразы, и распознавать было уже нечем.
    _server.hold();
    // Подъём держим отдельным фьючером и ждём его перед распознаванием:
    // подметание сирот сдвигает `ensureUp` на своё время, и без этого
    // ожидания короткая фраза успевала кончиться раньше, чем сервер
    // вообще начинал подниматься, — и считалась нераспознанной.
    _bringingUp = () async {
      // Подметание идёт фоном, а наш сервер несёт те же метки: подняться
      // раньше, чем оно кончится, — значит быть убитым им же.
      await _sweeping;
      await _server.ensureUp(_options);
    }();
    unawaited(_bringingUp);

    final path = await bridge.startRecording();
    if (path == null) {
      _server.release();
      return;
    }
    _wav = path;
    _startedAt = DateTime.now();
    _emit(state.copyWith(phase: Phase.recording, elapsed: Duration.zero));
    if (_settings.hud) unawaited(bridge.hud(HudState.recording));
    _syncMeter();
  }

  Future<void> stop() async {
    // Запись ещё только заводится — запомним, что её просили прекратить,
    // и сделаем это, как только будет что прекращать.
    if (_startingRecording != null) {
      _finishAfterStart = stop;
      return;
    }
    if (!state.recording) return;
    _stopMeter();
    _emit(state.copyWith(phase: Phase.transcribing));
    if (_settings.hud) unawaited(bridge.hud(HudState.transcribing));

    final path = await bridge.stopRecording() ?? _wav;
    _wav = null;
    var ok = false;
    String? failure;
    String? failurePath;
    try {
      if (path != null) {
        // Сервер поднимался параллельно записи — дожидаемся, иначе фраза
        // короче подъёма уйдёт в «не удалось» при живой модели.
        await _bringingUp;
        final text = await _server.transcribe(path);
        if (text == null) {
          // Распознать не удалось — или мы сами прервали счёт. Запись
          // в обоих случаях единственный экземпляр сказанного, и удалять
          // её здесь было бы потерей данных.
          final saved = rescueRecording(path);
          failurePath = saved ?? path;
          failure = _aborted
              ? saved == null
                  ? currentL10n().dictationAbortedNoSave(path)
                  : currentL10n().dictationAbortedSaved
              : saved == null
                  ? currentL10n().dictationFailedNoSave(path)
                  : currentL10n().dictationFailedSaved(saved);
        } else {
          _discard(path);
          if (text.isNotEmpty) {
            _emit(state.copyWith(last: text));
            // «Только в буфер» — для тех, кто вставит сам и туда, куда решит.
            if (!_settings.insert) {
              await copyLast();
              ok = true;
            } else {
              ok = await bridge.insert(text);
              if (!ok) {
                // Вставка не состоялась — почти всегда это отозванный
                // «Универсальный доступ». Текст при этом уже распознан,
                // и терять его нельзя: кладём в буфер и говорим вслух.
                await copyLast();
                failure = currentL10n().insertFailed(os.accessibilityName);
              }
            }
          }
        }
      }
    } finally {
      _server.release();
    }

    // Панель уходит с подтверждением, только если было что вставлять:
    // галочка после тишины была бы неправдой. А неудача не должна уходить
    // молча — иначе человек так и не узнает, что записи он лишился.
    // Исходы разные: пропала запись, пропала только вставка, или мы сами
    // прервали счёт, — и говорить о них одним и тем же нельзя.
    await bridge.hud(ok
        ? HudState.done
        : _aborted
            ? HudState.cancelled
            : failurePath != null
                ? HudState.failed
                : failure != null
                    ? HudState.copied
                    : HudState.hidden);
    if (isClosed) return;
    _emit(state.copyWith(
      phase: Phase.idle,
      failure: failure,
      failurePath: failurePath,
      clearFailure: failure == null,
    ));
  }

  /// Передумал. Записанное выбрасываем, ничего не распознаём и не
  /// вставляем — молча, как будто ничего и не начиналось.
  Future<void> cancel() async {
    if (_startingRecording != null) {
      _finishAfterStart = cancel;
      _aborted = false;
      return;
    }
    if (!state.recording) return;
    _stopMeter();
    _emit(state.copyWith(phase: Phase.idle));
    unawaited(bridge.hud(HudState.hidden));
    _discard(await bridge.stopRecording() ?? _wav);
    _wav = null;
    _server.release();
  }

  /// Прервать уже идущее распознавание.
  ///
  /// Оборвать HTTP-запрос мало: whisper-server считает синхронно и о
  /// закрытом сокете узнаёт только когда соберётся писать ответ — то есть
  /// процессор он жечь не перестанет. Единственное, что действительно
  /// останавливает счёт, — погасить сам процесс. Ценой этого модель уходит
  /// из памяти, и следующая фраза платит 0,6–2 с на загрузку; ради того,
  /// чтобы часовая запись не считалась вхолостую, это дёшево.
  ///
  /// Запись при этом не пропадает: [stop] увидит, что текста нет, и уложит
  /// её в «Не распознано», откуда её можно распознать вручную или убрать.
  Future<void> abortTranscription() async {
    if (state.phase != Phase.transcribing || _aborted) return;
    _aborted = true;
    await _server.shutdown();
  }

  /// Уровень сигнала и время записи.
  ///
  /// Считается всю запись, независимо от того, открыт ли поповер. Была
  /// попытка сэкономить и заводить таймер только при открытом — и она
  /// стоила и бегущего времени, и полоски громкости: признак «поповер
  /// на экране» оказался ненадёжным, а десять вызовов канала в секунду
  /// не стоят того, чтобы на них экономить.
  void _syncMeter() {
    final needed = state.recording;
    if (needed == (_meter != null)) return;
    if (!needed) {
      _stopMeter();
      return;
    }
    _meter = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final level = await bridge.level();
      if (isClosed) return;
      _emit(state.copyWith(
        level: level,
        elapsed: DateTime.now().difference(_startedAt ?? DateTime.now()),
      ));
    });
  }

  void _stopMeter() {
    _meter?.cancel();
    _meter = null;
    if (!isClosed) _emit(state.copyWith(level: 0));
  }

  void _discard(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  // ── действия из панели ─────────────────────────────────────────────────────

  void setEnabled(bool v) {
    _settings.enabled = v;
    if (!v && state.recording) cancel();
    _settings.save();
    _emit(_withSnapshots(state));
    unawaited(bridge.settingsChanged());
  }

  void setModel(String path) {
    _settings.model = path;
    _settings.save();
    _emit(_withSnapshots(state));
    unawaited(bridge.settingsChanged());
    // Модель меняется только перезапуском сервера — но не сейчас, а на
    // следующей фразе: сегодняшнюю память отдаём сразу.
    if (_server.up && _server.model != path) unawaited(_server.shutdown());
  }

  Future<void> copyLast() async {
    if (state.last.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: state.last));
  }

  void unload() => unawaited(_server.shutdown());

  void forgetSweep() => _emit(state.copyWith(sweptMb: 0));

  /// Убрать сохранённую запись в Корзину. Не `unlink`: промах по кнопке
  /// после часа речи иначе стоил бы этого часа, а из Корзины файл
  /// возвращается средствами самой системы.
  Future<void> discardFailure() async {
    final path = state.failurePath;
    if (path == null) return;
    final gone = await bridge.trash(path);
    if (isClosed) return;
    _emit(gone
        ? state.copyWith(clearFailure: true)
        : state.copyWith(
            failure: currentL10n().recordingTrashFailed(path),
          ));
  }

  /// Показать спасённую запись в проводнике — оттуда её перетаскивают
  /// в очередь главного окна и распознают вручную.
  ///
  /// Запись могли убрать мимо приложения. Тогда показывать нечего,
  /// и вместо подделки говорим правду.
  Future<void> revealFailure() async {
    final p = state.failurePath;
    if (p == null) return;
    if (await revealInFinder(p)) return;
    _reportGone();
  }

  /// Записи больше нет. Кнопок к ней не остаётся — ни одна ничего не
  /// исправит, — и само сообщение тоже не вечное: сказали и убрали,
  /// иначе панель так и стоит с надписью о том, чего уже не вернуть.
  void _reportGone() {
    _emit(state.copyWith(
      failure: currentL10n().recordingGoneExternally,
      clearFailurePath: true,
    ));
    Future.delayed(const Duration(seconds: 6), () {
      if (isClosed || state.failurePath != null) return;
      if (state.failure == currentL10n().recordingGoneExternally) {
        _emit(state.copyWith(clearFailure: true));
      }
    });
  }

  /// Убедиться, что спасённая запись всё ещё на месте. Панель открывают
  /// спустя время, и предлагать кнопку к исчезнувшему файлу нечестно.
  void _forgetGoneRecording() {
    final p = state.failurePath;
    if (p == null || File(p).existsSync()) return;
    _reportGone();
  }

  /// Чем занята диктовка — для очереди.
  ///
  /// Сама память ничего не решает: важно, идёт ли прямо сейчас запись или
  /// распознавание фразы. Фраза длится секунды, и прерванная пропадает
  /// совсем — переговорить её нельзя, в отличие от записи в очереди.
  String _statusForQueue() {
    if (state.phase != Phase.idle) return 'busy';
    return _server.up ? 'resting' : 'away';
  }

  /// Отдать память. Спрашивают только в покое и только с согласия человека:
  /// держать полтора гигабайта ради возможной следующей фразы дороже,
  /// чем поднять сервер заново за 0,6 с.
  Future<void> _releaseModel() => _server.shutdown();

  /// Высота содержимого панели: окно подгоняется под неё, как системный
  /// поповер, — иначе внизу остаётся пустота на всё, чего сейчас нет.
  Future<void> reportHeight(double height) => bridge.setPanelHeight(height);

  Future<void> openMainWindow() => bridge.openMainWindow();

  /// Настройки диктовки живут в своём окне. Без значка в Dock строки меню
  /// у приложения нет, и эта кнопка — единственная дорога туда.
  Future<void> openSettings([String tab = 'dictation']) =>
      bridge.openSettings(tab);

  Future<void> requestPermission() => bridge.requestPermission();

  Future<void> openPermissionSettings() => bridge.openPermissionSettings();

  Future<void> quit() => bridge.quit();

  @override
  Future<void> close() {
    _ticker?.cancel();
    _meter?.cancel();
    return super.close();
  }
}
