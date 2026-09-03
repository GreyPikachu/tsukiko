import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/app_locale.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/text.dart';
import '../../core/transcript.dart';
import '../../core/whisper.dart';
import '../api/api_server.dart';
import '../dictation/dictation_repository.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'job.dart';
import 'queue_event.dart';
import 'queue_state.dart';
import '../../core/labels.dart';

/// Очередь распознавания: что в списке, что из него выбрано, что сейчас
/// считается и куда ложится результат.
///
/// Полный Bloc, а не Cubit: «Распознать» при уже идущей очереди отбрасывает
/// трансформер, а не проверка внутри обработчика, и по журналу событий
/// видно, что происходило перед сбоем.
///
/// Диалогов здесь нет: блок не знает, что такое окно. Когда нужен ответ
/// человека, он кладёт вопрос в состояние ([QueueState.ask]), а ответ
/// приходит обратно событием.
class QueueBloc extends Bloc<QueueEvent, QueueState> {
  QueueBloc(this.bridge, {DictationRepository? dictation})
      : dictation = dictation ?? DictationRepository(bridge),
        super(_loaded()) {
    on<FilesAdded>(_onFilesAdded);
    on<TranscriptOpened>(_onTranscriptOpened);
    on<SelectedRemoved>(_onSelectedRemoved);
    on<FinishedCleared>(_onFinishedCleared);

    on<JobSelected>((e, emit) => emit(_select(state, e.job)));
    on<JobToggled>(_onToggled);
    on<SelectionExtended>(_onExtended);
    on<SelectionStepped>(_onStepped);
    on<AllSelected>(_onAllSelected);
    on<SelectionCleared>((e, emit) =>
        emit(state.copyWith(selected: const {}, clearLead: true)));

    // Пока очередь идёт, повторное «Распознать» отбрасывается целиком.
    // Раньше это была проверка `if (_running) return` внутри — теперь
    // событие просто не доходит, и в журнале видно, что его отбросили.
    on<RunRequested>(_onRun, transformer: droppable());
    on<RunConfirmed>(_onRunConfirmed);
    on<RetryRequested>(_onRetry);
    on<StopRequested>(_onStop);
    on<PauseRequested>(_onPause);
    on<JobsReordered>(_onReordered);
    on<ResumeRequested>(_onResume, transformer: droppable());
    on<JobAdvanced>(_onJobAdvanced);

    on<OptionsEdited>(_onOptionsEdited);
    on<OverridesReset>(_onOverridesReset);
    on<LeadOptionsMadeDefault>(_onMakeDefault);

    on<ModelChosen>(_onModelChosen);
    on<ModelDownloadRequested>(_onDownload, transformer: droppable());
    on<DownloadCancelled>((e, emit) => _download?.cancel());
    on<DownloadAdvanced>((e, emit) => emit(state.copyWith(
          downloadProgress: e.progress,
          downloadPercent: e.percent,
          status: currentL10n().statusLoadingProgress(e.progress),
        )));
    on<VadRequested>(_onVad, transformer: droppable());
    on<VadModelChosen>(_onVadModelChosen);

    on<DictationPolled>(_onDictationPolled, transformer: droppable());
    on<WindowVisibilityChanged>(_onVisibility);
    on<SettingsReloaded>(_onSettingsReloaded);
    on<TimestampsToggled>(_onTimestampsToggled);
    on<RecentCleared>(_onRecentCleared);

    on<CopyRequested>(_onCopy);
    on<SaveRequested>(_onSave);
    on<ExportRequested>(_onExport);
    on<AskDismissed>((e, emit) => emit(state.copyWith(clearAsk: true)));
    on<StatusReported>((e, emit) => emit(state.copyWith(status: e.text)));

    _settingsSub = bridge.settingsReloaded.listen((_) => add(const SettingsReloaded()));
    _syncPolling();
    // Местное API поднимается здесь и нигде больше: оно кладёт файлы
    // в эту же очередь, а очередь живёт в изоляте главного окна.
    unawaited(api.sync());
  }

  /// Единственный, кто может держать модель занятой, — своя же диктовка.
  final DictationRepository dictation;

  /// Местное API. Само по себе выключено — включается галкой в настройках.
  late final api = ApiServer(this);

  /// Что прочитано с диска к самому первому кадру.
  ///
  /// Именно к первому: когда это делалось событием, окно успевало
  /// нарисоваться на пустом состоянии — и модель в инспекторе показывалась
  /// как «Не выбрана», хотя выбрана была.
  static QueueState _loaded() {
    var threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 16);
    if (threads.isOdd) threads -= 1;

    final s = Settings.load();
    final models = findModels();
    final defaults = RunOptions.fromJson(
      s,
      RunOptions(
        model: models.isNotEmpty ? models.first : '',
        lang: 'auto',
        threads: threads,
      ),
    );
    // Раньше форматы хранились расширениями («.txt») — переводим в имена.
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();

    return QueueState(
      jobs: _unfinished(),
      models: _withOwn(models, defaults.model),
      defaults: defaults,
      whisperFound: findWhisper() != null,
      timestamps: (s['timestamps'] as bool?) ?? true,
      saveNextToSource: (s['saveNextToSource'] as bool?) ?? false,
      toLibrary: (s['toLibrary'] as bool?) ?? true,
      libraryPath: (s['libraryPath'] as String?) ?? defaultLibraryPath,
      libraryFormats:
          formats != null && formats.isNotEmpty ? formats : const ['txt'],
      copyFormat: _knownFormat(s['copyFormat']),
      saveFormat: _knownFormat(s['saveFormat']),
      recent: ((s['recent'] as List?)?.cast<String>() ?? const [])
          .where((p) => File(p).existsSync())
          .toList(),
    );
  }

  /// Файл с недосчитанным. Очередь между запусками не переживает — и не
  /// должна, — но брошенная посреди работа это не «очередь», а начатое
  /// дело: половина часовой записи стоит десятков минут счёта, и терять
  /// её на выходе из приложения нельзя.
  static File get _unfinishedFile => File(os.join(os.supportDir, 'unfinished.json'));

  /// Вернуть недосчитанное с прошлого запуска — если запись всё ещё на
  /// месте. Нет файла — нечего и продолжать.
  static List<Job> _unfinished() {
    try {
      final j = jsonDecode(_unfinishedFile.readAsStringSync()) as Map<String, dynamic>;
      final path = j['path'] as String;
      if (!File(path).existsSync()) return const [];
      final at = (j['resumeFrom'] as num).toInt();
      return [
        Job(
          File(path),
          state: JobState.paused,
          resumeFrom: at,
          progress: (j['progress'] as num?)?.toDouble() ?? 0,
          detail: currentL10n().jobDetailPausedAt(humanDuration(at)),
          live: [
            for (final seg in (j['segments'] as List? ?? const []))
              Segment((seg[0] as num).toInt(), (seg[1] as num).toInt(), seg[2] as String),
          ],
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Записать недосчитанное на диск. Пусто — файл убираем: доделанному
  /// незачем возвращаться при следующем запуске.
  void _persistPaused() {
    final job = state.jobs.where((j) => j.paused).firstOrNull;
    try {
      if (job == null) {
        if (_unfinishedFile.existsSync()) _unfinishedFile.deleteSync();
        return;
      }
      _unfinishedFile.writeAsStringSync(jsonEncode({
        'path': job.path,
        'resumeFrom': job.resumeFrom,
        'progress': job.progress,
        'segments': [
          for (final seg in job.live) [seg.from, seg.to, seg.text],
        ],
      }));
    } catch (e) {
      stderr.writeln('tsukiko: недосчитанное не сохранилось — $e');
    }
  }

  final NativeBridge bridge;

  StreamSubscription<void>? _settingsSub;
  Timer? _pollTimer, _saveTimer;
  bool _windowVisible = true;

  /// Работающий whisper-cli и его временная папка.
  Process? _proc;
  Directory? _tmp;
  bool _stopRequested = false;

  /// Распознавание прервали не насовсем: его продолжат с той же секунды.
  /// [_pauseWanted] ставит человек кнопкой, [_dictationTookOver] — начатая
  /// диктовка. Разница только в том, продолжится ли оно само.
  bool _pauseWanted = false;
  bool _dictationTookOver = false;

  bool get _pausing => _pauseWanted || _dictationTookOver;

  /// Номер следующего запуска: имена временных файлов должны быть новыми
  /// даже после правки очереди.
  int _runSeq = 0;

  Download? _download;


  // ── запуск ────────────────────────────────────────────────────────────────

  static String _knownFormat(Object? id) =>
      exportFormats.any((f) => f.id == id) ? id as String : formatPlainText.id;

  /// Список моделей с диска. Выбранный вручную файл из чужой папки
  /// дописываем — иначе он исчез бы из списка. Пропавший файл не дописываем:
  /// список из одной мёртвой строки выглядит так, будто модель есть.
  static List<String> _withOwn(List<String> found, String own) =>
      own.isEmpty || found.contains(own) || !File(own).existsSync()
          ? found
          : [...found, own];

  // ── очередь ───────────────────────────────────────────────────────────────

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  List<String> _remember(List<String> recent, String path) =>
      [path, ...recent.where((p) => p != path)].take(10).toList();

  Future<void> _onFilesAdded(FilesAdded e, Emitter<QueueState> emit) async {
    var next = state;
    var added = 0, duplicates = 0, skipped = 0;
    Job? last;

    Future<void> take(Iterable<String> paths) async {
      for (final p in paths) {
        if (FileSystemEntity.isDirectorySync(p)) {
          await take(Directory(p)
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((f) => audioExt.contains(_ext(f)))
              .toList()
            ..sort());
          continue;
        }
        // Готовую расшифровку тоже принимаем перетаскиванием.
        if (transcriptExt.contains(_ext(p))) {
          next = await _openTranscript(next, p);
          continue;
        }
        if (!audioExt.contains(_ext(p))) {
          skipped++;
          continue;
        }
        if (next.jobs.any((j) => j.path == p)) {
          duplicates++;
          continue;
        }
        last = Job(File(p));
        next = next.copyWith(
          jobs: [...next.jobs, last!],
          recent: _remember(next.recent, p),
        );
        added++;
      }
    }

    await take(e.paths);

    // Молчаливый отказ — худший вид отказа: файл не появился, и непонятно,
    // почему. Говорим про каждый случай.
    final l10n = currentL10n();
    final status = added > 0
        ? (added == 1 ? l10n.statusFileAdded : l10n.statusFilesAdded(filesLabel(added)))
        : duplicates > 0
            ? (duplicates == 1
                ? l10n.statusFileAlreadyQueued
                : l10n.statusFilesAlreadyQueued)
            : skipped > 0
                ? l10n.statusUnsupportedFiles
                : next.status;
    next = next.copyWith(status: status);
    if (last != null && next.selected.isEmpty) next = _select(next, last!);
    emit(next);
    _persist();
  }

  Future<void> _onTranscriptOpened(
      TranscriptOpened e, Emitter<QueueState> emit) async {
    emit(await _openTranscript(state, e.path));
    _persist();
  }

  /// Открыть готовую расшифровку как запись очереди.
  ///
  /// JSON, субтитры и наш «текст с таймкодами» разбираются в сегменты —
  /// такую расшифровку можно пересохранить в любой другой формат.
  Future<QueueState> _openTranscript(QueueState from, String path) async {
    if (from.jobs.any((j) => j.path == path)) {
      return from.copyWith(status: currentL10n().statusTranscriptAlreadyOpen);
    }
    final String text;
    try {
      text = await File(path).readAsString();
    } catch (err) {
      // Двоичный файл, чужая кодировка, исчез из-под рук.
      stderr.writeln('tsukiko: «$path» не открылся — $err');
      return from.copyWith(
        status: currentL10n().errorNotTextFile(os.basename(path)),
      );
    }

    Transcript? parsed;
    String? raw;
    if (path.endsWith('.json')) {
      try {
        parsed = parseWhisperJson(text);
      } catch (_) {
        raw = text;
      }
    } else {
      parsed = parseSubtitles(text);
      if (parsed == null) raw = text;
    }

    final job = Job(
      File(path),
      imported: true,
      state: JobState.done,
      transcript: parsed,
      raw: raw,
      detail: parsed != null
          ? currentL10n().statusOpenedSegments(segmentsLabel(parsed.segments.length))
          : currentL10n().statusOpenedText,
    );
    return _select(
      from.copyWith(
        jobs: [...from.jobs, job],
        recent: _remember(from.recent, path),
      ),
      job,
    );
  }

  void _onSelectedRemoved(SelectedRemoved e, Emitter<QueueState> emit) {
    final doomed = state.targets.where((j) => !j.active).toSet();
    if (doomed.isEmpty) return;
    final at = state.jobs.indexOf(doomed.first);
    final jobs = state.jobs.where((j) => !doomed.contains(j)).toList();
    final selected = state.selected.where((j) => !doomed.contains(j)).toSet();

    var lead = state.lead;
    if (lead != null && doomed.contains(lead)) {
      lead = jobs.isEmpty ? null : jobs[at.clamp(0, jobs.length - 1)];
    }
    emit(state.copyWith(
      jobs: jobs,
      selected: selected.isEmpty && lead != null ? {lead} : selected,
      lead: lead,
      clearLead: lead == null,
      status: doomed.length == 1
          ? currentL10n().statusRecordingRemoved
          : currentL10n().statusRecordingsRemoved(recordsLabel(doomed.length)),
    ));
  }

  void _onFinishedCleared(FinishedCleared e, Emitter<QueueState> emit) {
    final doomed = state.jobs.where((j) => j.done).toSet();
    if (doomed.isEmpty) return;
    final jobs = state.jobs.where((j) => !doomed.contains(j)).toList();
    final lead = doomed.contains(state.lead)
        ? (jobs.isEmpty ? null : jobs.first)
        : state.lead;
    emit(state.copyWith(
      jobs: jobs,
      selected: state.selected.where((j) => !doomed.contains(j)).toSet(),
      lead: lead,
      clearLead: lead == null,
      status: currentL10n().statusFinishedRemoved,
    ));
  }

  // ── выделение ─────────────────────────────────────────────────────────────

  QueueState _select(QueueState from, Job job) =>
      from.copyWith(selected: {job}, lead: job);

  void _onToggled(JobToggled e, Emitter<QueueState> emit) {
    final selected = {...state.selected};
    if (!selected.remove(e.job)) selected.add(e.job);
    final lead = selected.contains(e.job)
        ? e.job
        : (selected.isEmpty ? null : selected.last);
    emit(state.copyWith(
        selected: selected, lead: lead, clearLead: lead == null));
  }

  void _onExtended(SelectionExtended e, Emitter<QueueState> emit) {
    final lead = state.lead;
    if (lead == null) return emit(_select(state, e.job));
    final a = state.jobs.indexOf(lead), b = state.jobs.indexOf(e.job);
    if (a < 0 || b < 0) return emit(_select(state, e.job));
    emit(state.copyWith(
      selected: {
        ...state.selected,
        ...state.jobs.sublist(a < b ? a : b, (a < b ? b : a) + 1),
      },
      lead: e.job,
    ));
  }

  void _onStepped(SelectionStepped e, Emitter<QueueState> emit) {
    if (state.jobs.isEmpty) return;
    final from = state.lead == null ? -1 : state.jobs.indexOf(state.lead!);
    final next = (from + e.delta).clamp(0, state.jobs.length - 1);
    final job = state.jobs[next];
    if (!e.extend) return emit(_select(state, job));
    _onExtended(SelectionExtended(job), emit);
  }

  void _onAllSelected(AllSelected e, Emitter<QueueState> emit) {
    if (state.jobs.isEmpty) return;
    emit(state.copyWith(
      selected: state.jobs.toSet(),
      lead: state.lead ?? state.jobs.first,
    ));
  }

  // ── настройки распознавания ───────────────────────────────────────────────

  void _onOptionsEdited(OptionsEdited e, Emitter<QueueState> emit) {
    if (state.selected.isEmpty) {
      emit(state.copyWith(defaults: e.change(state.defaults)));
    } else {
      emit(_replaceAll(state.selected,
          (j) => j.copyWith(overrides: e.change(j.overrides ?? state.defaults))));
    }
    _persist();
  }

  void _onOverridesReset(OverridesReset e, Emitter<QueueState> emit) {
    emit(_replaceAll(state.selected, (j) => j.copyWith(clearOverrides: true))
        .copyWith(status: currentL10n().statusOverridesReset));
  }

  void _onMakeDefault(LeadOptionsMadeDefault e, Emitter<QueueState> emit) {
    final own = state.lead?.overrides;
    if (own == null) return;
    emit(state.copyWith(defaults: own, status: currentL10n().statusSettingsMadeDefault));
    _persist();
  }

  /// Заменить записи по правилу, сохранив выделение и ведущую.
  QueueState _replaceAll(Set<Job> which, Job Function(Job) change) {
    final map = <String, Job>{};
    final jobs = [
      for (final j in state.jobs)
        if (which.contains(j)) (map[j.path] = change(j)) else j,
    ];
    Job pick(Job j) => map[j.path] ?? j;
    return state.copyWith(
      jobs: jobs,
      selected: state.selected.map(pick).toSet(),
      lead: state.lead == null ? null : pick(state.lead!),
    );
  }

  /// Заменить одну запись, не трогая остальных.
  QueueState _replace(QueueState from, Job was, Job now) => from.copyWith(
        jobs: [
          for (final j in from.jobs) identical(j, was) || j.path == was.path ? now : j,
        ],
        selected:
            from.selected.map((j) => j.path == was.path ? now : j).toSet(),
        lead: from.lead?.path == was.path ? now : from.lead,
      );

  // ── распознавание ─────────────────────────────────────────────────────────

  Future<void> _onRetry(RetryRequested e, Emitter<QueueState> emit) async {
    final again = state.targets.where((j) => !j.imported).toSet();
    if (again.isEmpty || state.running) return;
    emit(_replaceAll(again, (j) => j.reset).copyWith(
      status: again.length == 1
          ? currentL10n().statusRetrying
          : currentL10n().statusRetryingRecords(recordsLabel(again.length)),
    ));
    await _run(emit);
  }

  Future<void> _onRun(RunRequested e, Emitter<QueueState> emit) async {
    // Сначала «а есть ли что распознавать»: с пустой очередью говорить
    // про модель незачем — человек ещё ничего не просил.
    if (!state.hasPending) return;

    final l10n = currentL10n();
    if (!state.whisperFound) {
      return emit(state.copyWith(
        ask: Ask(l10n.askWhisperNotFoundTitle,
            l10n.askWhisperNotFoundBody(os.whisperInstallHint)),
      ));
    }
    if (state.defaults.model.isEmpty &&
        state.jobs.every((j) => state.optionsFor(j).model.isEmpty)) {
      // Моделей нет вовсе — говорить «выберите модель» некорректно:
      // выбирать не из чего, человека надо вести в загрузчик.
      return emit(state.copyWith(
        ask: Ask(
          state.models.isEmpty ? l10n.askNeedModelTitle : l10n.askModelNotSelectedTitle,
          state.models.isEmpty ? l10n.askNeedModelBody : l10n.askModelNotSelectedBody,
        ),
      ));
    }

    // Диктовка главнее очереди, и спрашиваем о ней здесь, до запуска:
    // посреди работы такой вопрос застал бы человека врасплох.
    if (await dictation.status() == DictationStatus.resting) {
      return emit(state.copyWith(
        ask: Ask(
          l10n.askDictationHoldsModelTitle,
          l10n.askDictationHoldsModelBody,
          confirm: true,
        ),
      ));
    }
    await _run(emit);
  }

  Future<void> _onRunConfirmed(
      RunConfirmed e, Emitter<QueueState> emit) async {
    emit(state.copyWith(clearAsk: true));
    if (!e.yes) return;
    // Согласились — освобождаем память и только потом начинаем: двух
    // копий модели сразу в памяти не бывает.
    if (await dictation.status() == DictationStatus.resting) {
      await dictation.release();
    }
    await _run(emit);
  }

  /// Проход по очереди. Всё, что может пойти не так внутри, оставляет
  /// очередь в состоянии покоя: без этого одно исключение подвешивало её
  /// в «идёт распознавание» до перезапуска.
  Future<void> _run(Emitter<QueueState> emit) async {
    emit(state.copyWith(running: true, clearAsk: true));
    _stopRequested = false;
    _pauseWanted = false;
    _dictationTookOver = false;
    _syncPolling();
    try {
      _tmp ??= await Directory.systemTemp.createTemp(appName);
      // По одной записи за раз, а не обходом по индексу: пока идёт
      // распознавание, файлы и добавляют, и убирают. Список взятого нужен,
      // чтобы неудачная запись не попалась второй раз.
      final attempted = <String>{};
      while (!_stopRequested) {
        Job? next;
        for (final job in state.jobs) {
          if (!job.done && !job.imported && !attempted.contains(job.path)) {
            next = job;
            break;
          }
        }
        if (next == null) break;
        attempted.add(next.path);
        if (!await _runOne(next, emit)) break;
      }
    } finally {
      _proc = null;
      emit(state.copyWith(
        running: false,
        // Приостановленное — не «Готово»: работа не кончилась, она ждёт.
        status: _stopRequested
            ? currentL10n().statusStopped
            : state.hasPaused
                ? currentL10n().statusPaused
                : currentL10n().statusIdle,
      ));
        _syncPolling();
      _releaseTemp();
      _persistNow();
      // Доделанное с диска убирается здесь же: файл недосчитанного живёт
      // ровно столько, сколько есть что досчитывать.
      _persistPaused();
    }
  }

  void _releaseTemp() {
    final dir = _tmp;
    if (dir == null) return;
    _tmp = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Одна запись от начала до конца. false — очередь надо остановить
  /// целиком; неудача самой записи это true: соседние файлы ни при чём.
  Future<bool> _runOne(Job job, Emitter<QueueState> emit) async {
    final opts = state.optionsFor(job);
    var it = job;
    if (opts.model.isEmpty) {
      emit(_replace(state, it, it.copyWith(
        state: JobState.failed,
        detail: currentL10n().jobDetailNoModelSelected,
      )));
      return true;
    }

    if (!await _yieldToDictation(it, emit)) return false;
    it = _find(it) ?? it;

    it = it.copyWith(state: JobState.converting, startedAt: DateTime.now());
    emit(_replace(state, job, it).copyWith(
      lead: it,
      selected: state.selected.length <= 1 ? {it} : null,
    ));

    final base = os.join(_tmp!.path, '${_runSeq++}');
    final jsonFile = File('$base.json');
    try {
      final wav = await os.toWav(it.path, '$base.wav');

      // Подготовка звука занимает секунды — за это время сосед мог начать
      // распознавать заново. Проверяем ещё раз вплотную к запуску.
      if (!await _yieldToDictation(it, emit)) return false;
      it = _find(it) ?? it;

      // Заход за заходом с одного и того же места: остановленное посреди
      // распознавание не начинают заново — whisper продолжает с той
      // миллисекунды, до которой досчитал (`-ot`), а метки времени всё
      // равно отдаёт от начала файла.
      var code = 0;
      while (true) {
        it = _find(it) ?? it;
        it = it.copyWith(state: JobState.transcribing, clearDetail: true);
        emit(_replace(state, job, it).copyWith(status: it.name));

        code = await _runWhisper(it, buildArgs(opts, wav, base, from: it.resumeFrom));
        it = _find(it) ?? it;
        if (!_pausing || _stopRequested) break;

        it = _pause(it, emit);
        // Своя пауза ждёт человека, а вытеснение диктовкой кончается само.
        if (_pauseWanted) return false;
        if (!await _yieldToDictation(it, emit)) return false;
        _dictationTookOver = false;
        // Диктовка кончилась, работа пошла — окошку о ней больше незачем
        // висеть, даже если его не закрыли.
        emit(state.copyWith(clearAsk: true));
        it = _find(it) ?? it;
      }

      if (_stopRequested) {
        emit(_replace(state, it, it.copyWith(state: JobState.cancelled)));
        return false;
      }
      if (code != 0 || !jsonFile.existsSync()) {
        emit(_replace(state, it,
            it.copyWith(
              state: JobState.failed,
              detail: currentL10n().jobDetailWhisperFailed,
            )).copyWith(status: currentL10n().statusRecognitionFailed(it.name)));
        return true;
      }

      var t = parseWhisperJson(await jsonFile.readAsString());
      // Заход после паузы знает только свою половину записи. Начало
      // осталось в том, что уже показали на экране, — оттуда и берём.
      if (it.resumeFrom > 0) {
        t = Transcript(t.lang, [
          ...it.live.where((seg) => seg.from < it.resumeFrom),
          ...t.segments,
        ]);
      }
      final beside = state.saveNextToSource
          ? await _saveBesideSource(it, t)
          : (path: null, problem: null);
      final placed = state.toLibrary ? await _fileToLibrary(it, t) : null;

      emit(_replace(
        state,
        it,
        it.copyWith(
          transcript: t,
          progress: 1,
          state: JobState.done,
          besideSource: beside.path,
          took: it.startedAt == null
              ? null
              : DateTime.now().difference(it.startedAt!),
          detail: currentL10n().jobDetailLangSegments(
              languageName(t.lang), segmentsLabel(t.segments.length)),
        ),
      ).copyWith(status: beside.problem ?? placed ?? state.status));
      return true;
    } catch (err) {
      // Битый JSON от whisper, файл исчез из-под рук, кончилось место.
      stderr.writeln('tsukiko: «${it.name}» не распозналась — $err');
      emit(_replace(state, it,
          it.copyWith(
            state: JobState.failed,
            detail: currentL10n().jobDetailParseFailed,
          )).copyWith(status: currentL10n().statusRecognitionFailed(it.name)));
      return true;
    } finally {
      for (final ext in const ['.wav', '.json']) {
        try {
          final f = File('$base$ext');
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Отметить запись приостановленной на том месте, до которого досчитали.
  ///
  /// Место берём по последнему показанному фрагменту, а не по проценту:
  /// процент — оценка, а метка фрагмента — факт. Досчитанное остаётся
  /// на экране, и второй заход начнётся ровно оттуда.
  Job _pause(Job job, Emitter<QueueState> emit) {
    final at = job.live.isEmpty ? job.resumeFrom : job.live.last.to;
    final paused = job.copyWith(
      state: JobState.paused,
      resumeFrom: at,
      detail: currentL10n().jobDetailPausedAt(humanDuration(at)),
    );
    emit(_replace(state, job, paused).copyWith(
      status: _dictationTookOver
          ? currentL10n().statusPausedDictation
          : currentL10n().statusPaused,
      // Молча отнимать у человека работу нельзя: диктовка вытеснила
      // расшифровку, и об этом надо сказать — вместе с тем, что она
      // продолжится сама.
      ask: _dictationTookOver
          ? Ask(
              currentL10n().askDictationTookOverTitle,
              currentL10n().askDictationTookOverBody(humanDuration(at)),
            )
          : null,
    ));
    _persistPaused();
    return paused;
  }

  /// Приостановить. Процесс гасим целиком, а не усыпляем: усыплённый
  /// держит в памяти полтора гигабайта модели — ровно то, ради чего паузу
  /// и жмут. Считанное при этом не пропадает.
  void _onPause(PauseRequested e, Emitter<QueueState> emit) {
    if (!state.running) return;
    _pauseWanted = true;
    _proc?.kill();
  }

  /// Переставить строку. Место вставки список считает сам — уже с оглядкой
  /// на то, что перетащенную строку из него вынут.
  void _onReordered(JobsReordered e, Emitter<QueueState> emit) {
    final jobs = [...state.jobs];
    if (e.from < 0 || e.from >= jobs.length) return;
    jobs.insert(e.to.clamp(0, jobs.length - 1), jobs.removeAt(e.from));
    emit(state.copyWith(jobs: jobs, status: currentL10n().statusQueueReordered));
  }

  Future<void> _onResume(ResumeRequested e, Emitter<QueueState> emit) async {
    if (state.running) return;
    _pauseWanted = false;
    final at = state.jobs.firstWhere((j) => j.paused, orElse: () => state.jobs.first);
    emit(state.copyWith(
      clearAsk: true,
      status: currentL10n().statusResumedFrom(humanDuration(at.resumeFrom)),
    ));
    await _run(emit);
  }

  /// Нынешний вид записи: пока шёл шаг, состояние могло смениться.
  Job? _find(Job job) {
    for (final j in state.jobs) {
      if (j.path == job.path) return j;
    }
    return null;
  }

  /// Запуск whisper-cli с разбором вывода на лету.
  Future<int> _runWhisper(Job job, List<String> args) async {
    void onLine(String line) {
      final seg = parseSegmentLine(line);
      if (seg != null) return add(JobAdvanced(job, segment: seg));
      final p = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
      if (p != null) {
        return add(JobAdvanced(job, progress: double.parse(p.group(1)!) / 100));
      }
      final l = RegExp(r'auto-detected language:\s*(\w+)').firstMatch(line);
      if (l != null) add(JobAdvanced(job, language: l.group(1)));
    }

    // Под своим именем: иначе в «Мониторинге системы» память числится
    // за безымянным whisper-cli, и чей он — не понять.
    final proc = await Process.start(
        runnableWhisper(findWhisper(), 'tsukiko-recognizer')!, args);
    _proc = proc;
    // Диктовка главнее очереди, и спрашивать её раз в начале мало:
    // часовая запись считается минутами, а диктовать хотят посреди.
    // Заметили — гасим счёт немедленно, память достаётся диктовке
    // целиком, а досчитаем потом с той же секунды.
    var asking = false;
    final watch = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      // Вопрос уходит в чужой изолят и возвращается не мгновенно: без
      // этого сторожа их накопилась бы очередь.
      if (asking || _pausing || _stopRequested) return;
      asking = true;
      try {
        if (await dictation.status() != DictationStatus.busy) return;
        _dictationTookOver = true;
        proc.kill();
      } finally {
        asking = false;
      }
    });
    final out = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    final err = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    try {
      return await proc.exitCode;
    } finally {
      watch.cancel();
      await out.cancel();
      await err.cancel();
      _proc = null;
    }
  }

  void _onJobAdvanced(JobAdvanced e, Emitter<QueueState> emit) {
    final job = _find(e.job);
    if (job == null) return;
    if (e.segment != null) {
      return emit(_replace(state, job, job.withSegment(e.segment!)));
    }
    if (e.progress != null) {
      return emit(_replace(state, job, job.copyWith(progress: e.progress)));
    }
    if (e.language != null) {
      emit(state.copyWith(
          status: '${job.name} · ${languageName(e.language!)}'));
    }
  }

  void _onStop(StopRequested e, Emitter<QueueState> emit) {
    if (!state.running) return;
    _stopRequested = true;
    _proc?.kill();
    emit(state.copyWith(status: currentL10n().statusStopping));
  }

  /// Диктовка главнее очереди: одновременно две копии модели в память
  /// не помещаются, а фраза длится секунды и прерванная пропадает совсем.
  ///
  /// Ждём только настоящую работу — запись или распознавание фразы. Модель,
  /// которая просто лежит в памяти, забираем молча: согласие на это уже
  /// спросили перед запуском очереди.
  Future<bool> _yieldToDictation(Job job, Emitter<QueueState> emit) async {
    var paused = false;
    while (!_stopRequested) {
      final status = await dictation.status();
      if (status == DictationStatus.away) break;
      if (status == DictationStatus.resting) {
        await dictation.release();
        break;
      }
      if (!paused) {
        final now = _find(job);
        if (now != null) {
          emit(_replace(state, now, now.copyWith(state: JobState.waiting))
              .copyWith(status: currentL10n().statusPausedDictation));
        }
        paused = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (paused && !_stopRequested) {
      emit(state.copyWith(status: currentL10n().statusDictationDoneResuming));
    }
    return !_stopRequested;
  }


  // ── куда ложится результат ────────────────────────────────────────────────

  /// Копия текста рядом с исходной записью. Имя выбирается один раз и
  /// запоминается за записью: повторное распознавание обновит свой файл,
  /// а чужой `запись.txt`, лежавший рядом до нас, не тронет.
  Future<({String? path, String? problem})> _saveBesideSource(
      Job job, Transcript t) async {
    try {
      final dir = job.file.parent.path;
      final path = job.besideSource ??
          os.join(dir, '${freeStem(dir, _stem(job.name), '.txt')}.txt');
      await File(path).writeAsString(renderPlain(t.segments, false));
      return (path: path, problem: null);
    } catch (e) {
      stderr.writeln('tsukiko: копия рядом с записью не легла — $e');
      return (path: null, problem: currentL10n().errorCopyBesideFailed);
    }
  }

  /// Раскладка по месяцам; когда форматов больше одного — у записи своя
  /// папка. Возвращает строку для статуса или null.
  Future<String?> _fileToLibrary(Job job, Transcript t) async {
    if (state.libraryFormats.isEmpty) return null;
    try {
      final formats = state.libraryFormats.map(formatById).toList();
      final plan = planPlacement(
        root: state.libraryPath,
        stem: _stem(job.name),
        formatCount: formats.length,
      );
      await Directory(plan.dir).create(recursive: true);
      final stem = formats.length == 1
          ? freeStem(plan.dir, plan.stem, formats.first.suffix)
          : plan.stem;
      for (final f in formats) {
        await File(os.join(plan.dir, f.fileName(stem)))
            .writeAsString(renderFor(f, t, name: job.name));
      }
      return currentL10n().statusSavedInLibrary(
          plan.dir.replaceFirst(state.libraryPath, appName));
    } catch (e) {
      stderr.writeln('tsukiko: библиотека не приняла запись — $e');
      return currentL10n().errorLibrarySaveFailed;
    }
  }

  // ── экспорт ───────────────────────────────────────────────────────────────

  /// Импортированный текст без разметки отдаём как есть, всё остальное —
  /// в запрошенном формате.
  String _render(Job job, ExportFormat f) {
    final t = job.transcript;
    if (t == null) return job.raw ?? renderPlain(job.live, f.id == 'txt-ts');
    return renderFor(f, t, name: job.name);
  }

  Future<void> _onCopy(CopyRequested e, Emitter<QueueState> emit) async {
    final jobs = state.readyTargets;
    if (jobs.isEmpty) return;
    // Несколько записей склеиваются с заголовками — иначе в буфере стена
    // текста, в которой не видно, где кончилась одна запись.
    final text = jobs.length == 1
        ? _render(jobs.first, e.format)
        : jobs.map((j) => '— ${j.name} —\n${_render(j, e.format)}').join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    emit(state.copyWith(
      copyFormat: e.format.id,
      status: jobs.length == 1
          ? currentL10n().statusCopiedFormat(e.format.label.toLowerCase())
          : currentL10n().statusCopiedRecords(jobs.length, e.format.label.toLowerCase()),
    ));
    _persist();
  }

  Future<void> _onSave(SaveRequested e, Emitter<QueueState> emit) async {
    try {
      await File(e.path).writeAsString(_render(e.job, e.format));
      emit(state.copyWith(
        saveFormat: e.format.id,
        status: currentL10n().statusSavedFile(os.basename(e.path)),
      ));
    } catch (err) {
      stderr.writeln('tsukiko: не удалось сохранить — $err');
      emit(state.copyWith(status: currentL10n().errorSaveFileFailed));
    }
    _persist();
  }

  Future<void> _onExport(ExportRequested e, Emitter<QueueState> emit) async {
    if (e.formats.isEmpty) return;
    var written = 0;
    try {
      // Свободное имя ищем сразу под все форматы: иначе экспорт текста
      // и субтитров в папку, где такие имена уже лежат, затрёт их.
      for (final job in e.jobs) {
        final stem = freeStemFor(
            e.dir, _stem(job.name), e.formats.map((f) => f.suffix).toList());
        for (final f in e.formats) {
          await File(os.join(e.dir, f.fileName(stem)))
              .writeAsString(_render(job, f));
          written++;
        }
      }
      emit(state.copyWith(status: currentL10n().statusExported(filesLabel(written))));
    } catch (err) {
      stderr.writeln('tsukiko: экспорт оборвался — $err');
      emit(state.copyWith(status: currentL10n().errorExportFailed));
    }
  }

  // ── модели ────────────────────────────────────────────────────────────────

  void _onModelChosen(ModelChosen e, Emitter<QueueState> emit) {
    emit(state.copyWith(
      models: state.models.contains(e.path)
          ? state.models
          : [...state.models, e.path],
    ));
    add(OptionsEdited((o) => o.copyWith(model: e.path)));
  }

  Future<void> _onDownload(
      ModelDownloadRequested e, Emitter<QueueState> emit) async {
    if (_download != null) return;
    final wasEmpty = state.shown.model.isEmpty ||
        !File(state.shown.model).existsSync();
    final path = await _fetch(
        e.offer, Download(e.offer.url, e.offer.path, title: e.offer.title), emit);
    if (path != null && wasEmpty) {
      add(OptionsEdited((o) => o.copyWith(model: path)));
    }
  }

  Future<void> _onVad(VadRequested e, Emitter<QueueState> emit) async {
    if (!e.on) {
      add(OptionsEdited((o) => o.copyWith(vad: false)));
      return;
    }
    if (File(vadModelPath).existsSync()) {
      add(OptionsEdited((o) => o.copyWith(vadModel: vadModelPath, vad: true)));
      return;
    }
    // Диктовка качает модель тишины в ту же папку — если она уже это
    // сделала, спрашивать нечего. Не вышло — остаётся выбрать файл руками.
    final path = await _fetch(
        null,
        Download(vadModelUrl, vadModelPath, title: currentL10n().vadDownloadTitle),
        emit);
    if (path != null) {
      add(OptionsEdited((o) => o.copyWith(vadModel: path, vad: true)));
    } else {
      emit(state.copyWith(status: currentL10n().statusPickVadManually));
    }
  }

  void _onVadModelChosen(VadModelChosen e, Emitter<QueueState> emit) {
    add(e.path == null
        ? OptionsEdited((o) => o.copyWith(vad: false))
        : OptionsEdited((o) => o.copyWith(vadModel: e.path, vad: true)));
  }

  /// Одна загрузка на всё окно: сеть общая, а два полуторагиговых файла
  /// разом просто мешают друг другу.
  Future<String?> _fetch(
      ModelOffer? offer, Download d, Emitter<QueueState> emit) async {
    _download = d;
    emit(state.copyWith(
      download: offer,
      downloadProgress: d.progressLabel,
      downloadPercent: d.percent,
      status: currentL10n().statusDownloadingTitle(d.title),
    ));
    final path = await d.run(onProgress: () {
      if (!isClosed) add(DownloadAdvanced(d.progressLabel, d.percent));
    });
    _download = null;
    emit(state.copyWith(
      clearDownload: true,
      models: path != null ? _withOwn(findModels(), state.defaults.model) : null,
      status: path != null
          ? currentL10n().statusDownloadedTitle(d.title)
          : d.cancelled
              ? currentL10n().statusDownloadCancelled
              : currentL10n().statusDownloadFailedTitle(d.title),
    ));
    return path;
  }

  // ── что делает диктовка ───────────────────────────────────────────────────

  /// Значок в строке состояния — единственное, ради чего идёт опрос.
  /// Свёрнутому окну он не нужен; идущей очереди — нужен всегда, она сама
  /// смотрит на тот же ответ, когда уступает.
  void _syncPolling() {
    final needed = state.running || _windowVisible;
    if (needed == (_pollTimer != null)) return;
    if (!needed) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    add(const DictationPolled());
    // Полторы секунды: это подпись на значке, а не управление. Прежний
    // опрос ходил дважды в секунду, и каждый заход стоил трёх процессов.
    _pollTimer = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => add(const DictationPolled()));
  }

  void _onVisibility(WindowVisibilityChanged e, Emitter<QueueState> emit) {
    _windowVisible = e.visible;
    _syncPolling();
  }

  Future<void> _onDictationPolled(
      DictationPolled e, Emitter<QueueState> emit) async {
    // Снимок берём после ответа, а не до: пока идёт вопрос, состояние
    // успевает измениться, и старый снимок затёр бы чужую правку.
    final status = await dictation.status();
    emit(state.copyWith(dictation: status));
  }

  // ── настройки приложения ──────────────────────────────────────────────────

  void _onTimestampsToggled(TimestampsToggled e, Emitter<QueueState> emit) {
    emit(state.copyWith(timestamps: !state.timestamps));
    _persist();
  }

  void _onRecentCleared(RecentCleared e, Emitter<QueueState> emit) {
    emit(state.copyWith(recent: const []));
    _persist();
  }

  /// Настройки поменяли в другом окне. Перечитываем то, чем это окно
  /// пользуется, но чего больше не правит.
  void _onSettingsReloaded(SettingsReloaded e, Emitter<QueueState> emit) {
    final s = Settings.load();
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    emit(state.copyWith(
      timestamps: (s['timestamps'] as bool?) ?? state.timestamps,
      saveNextToSource:
          (s['saveNextToSource'] as bool?) ?? state.saveNextToSource,
      toLibrary: (s['toLibrary'] as bool?) ?? state.toLibrary,
      libraryPath: (s['libraryPath'] as String?) ?? state.libraryPath,
      libraryFormats:
          formats != null && formats.isNotEmpty ? formats : state.libraryFormats,
      // Модель могли скачать в окне настроек — список файлов уже другой.
      models: _withOwn(findModels(), state.defaults.model),
    ));
    // Галку API правит окно настроек, а сервер живёт здесь — узнать
    // о перемене можно только отсюда.
    unawaited(api.sync());
  }

  /// Раньше настройки писались только при выходе, и ⌘Q мимо dispose стирал
  /// все правки за сеанс. Теперь пишем сразу, но не чаще раза в полсекунды —
  /// иначе каждая буква в подсказке уходила бы на диск.
  void _persist() {
    _pollTimer?.cancel();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  /// Пишем только своё: библиотеку и поведение приложения правит окно
  /// настроек, и его ключи Settings.save оставляет в файле нетронутыми.
  void _persistNow() {
    unawaited(Settings.save({
      ...state.defaults.toJson(),
      'timestamps': state.timestamps,
      'copyFormat': state.copyFormat,
      'saveFormat': state.saveFormat,
      'recent': state.recent,
    }));
  }

  @visibleForTesting
  Future<void> flushSettings() async => _persistNow();

  @override
  Future<void> close() {
    _saveTimer?.cancel();
    // Опрос диктовки идёт по таймеру и кончается событием в этот же блок.
    // Не погасить его — значит после закрытия получить «событие в
    // закрытый блок»: в приложении это видно только на выходе, а в
    // тестах роняет соседей, которые уже прошли.
    _pollTimer?.cancel();
    _settingsSub?.cancel();
    unawaited(api.stop());
    _proc?.kill();
    _releaseTemp();
    _persistNow();
    return super.close();
  }
}
