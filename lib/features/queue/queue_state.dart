import 'package:equatable/equatable.dart';

import '../dictation/dictation_repository.dart';
import '../../core/models.dart';
import '../../core/whisper.dart';
import 'job.dart';

/// Вопрос, на который очередь ждёт ответа, прежде чем идти дальше.
///
/// Блок диалогов не показывает — их показывает окно. Здесь только то,
/// о чём спросить; ответ приходит обратно событием.
class Ask extends Equatable {
  const Ask(this.title, this.message, {this.confirm = false});
  final String title, message;

  /// true — нужен ответ «да/нет», false — просто сообщение.
  final bool confirm;

  @override
  List<Object?> get props => [title, message, confirm];
}

/// Всё, что знает очередь распознавания.
class QueueState extends Equatable {
  const QueueState({
    this.jobs = const [],
    this.selected = const {},
    this.lead,
    this.running = false,
    this.status = 'Готово',
    this.defaults = const RunOptions(model: '', lang: 'auto', threads: 4),
    this.models = const [],
    this.whisperFound = false,
    this.dictation = DictationStatus.away,
    this.download,
    this.downloadProgress,
    this.downloadPercent = 0,
    this.timestamps = true,
    this.saveNextToSource = false,
    this.toLibrary = true,
    this.libraryPath = '',
    this.libraryFormats = const ['txt'],
    this.copyFormat = 'txt',
    this.saveFormat = 'txt',
    this.recent = const [],
    this.ask,
  });

  final List<Job> jobs;

  /// Что выбрано и какая запись ведущая — её настройки показывает инспектор.
  final Set<Job> selected;
  final Job? lead;

  final bool running;
  final String status;

  /// Общие настройки распознавания. У записи может быть свой набор,
  /// и тогда он замещает общий целиком.
  final RunOptions defaults;

  final List<String> models;

  /// Найден ли whisper-cli. Без него распознавать нечем, и говорить об этом
  /// надо до запуска, а не после.
  final bool whisperFound;

  /// Чем занята диктовка. Её и только её: посторонних распознавателей
  /// приложение больше не ищет — их и не бывает.
  final DictationStatus dictation;

  /// Идущая загрузка модели и её ход строкой. Сам объект в сравнение
  /// не входит — он меняется внутри себя, и заметить это можно только
  /// по строке.
  final ModelOffer? download;
  final String? downloadProgress;
  final int downloadPercent;

  // Настройки приложения: правит их окно настроек, здесь ими пользуются.
  final bool timestamps, saveNextToSource, toLibrary;
  final String libraryPath;
  final List<String> libraryFormats;

  /// Приложение помнит, чем пользуются: кнопка повторяет прошлый выбор.
  final String copyFormat, saveFormat;
  final List<String> recent;

  /// Вопрос к человеку, если очередь на него наткнулась.
  final Ask? ask;

  // ── что из этого следует ──────────────────────────────────────────────────

  /// К чему применится команда: к выбранному, а если не выбрано ничего —
  /// к ведущей записи. Так меню и кнопки одинаково понимают «применить к».
  List<Job> get targets =>
      selected.isNotEmpty ? jobs.where(selected.contains).toList() : [?lead];

  List<Job> get readyTargets => targets.where((j) => j.done).toList();

  bool get hasPending => jobs.any((j) => !j.done && !j.imported);

  bool get canRetry => targets.any((j) => !j.imported);

  /// Есть недосчитанное: остановленное посреди работы ждёт продолжения.
  bool get hasPaused => jobs.any((j) => j.paused);

  /// Очередь запущена, но стоит и уступает диктовке.
  bool get waitingForModel =>
      running && jobs.any((j) => j.state == JobState.waiting);

  bool get transcribing =>
      running && jobs.any((j) => j.state == JobState.transcribing);

  /// Настройки, которые показывает инспектор: общие, если ничего не выбрано,
  /// иначе — настройки ведущей записи.
  RunOptions get shown =>
      selected.isEmpty ? defaults : (lead?.overrides ?? defaults);

  RunOptions optionsFor(Job job) => job.overrides ?? defaults;

  /// Запись, чью расшифровку показывает окно.
  Job? get current => lead;

  QueueState copyWith({
    List<Job>? jobs,
    Set<Job>? selected,
    Job? lead,
    bool? running,
    String? status,
    RunOptions? defaults,
    List<String>? models,
    bool? whisperFound,
    DictationStatus? dictation,
    ModelOffer? download,
    String? downloadProgress,
    int? downloadPercent,
    bool? timestamps,
    bool? saveNextToSource,
    bool? toLibrary,
    String? libraryPath,
    List<String>? libraryFormats,
    String? copyFormat,
    String? saveFormat,
    List<String>? recent,
    Ask? ask,
    bool clearLead = false,
    bool clearDownload = false,
    bool clearAsk = false,
  }) =>
      QueueState(
        jobs: jobs ?? this.jobs,
        selected: selected ?? this.selected,
        lead: clearLead ? null : (lead ?? this.lead),
        running: running ?? this.running,
        status: status ?? this.status,
        defaults: defaults ?? this.defaults,
        models: models ?? this.models,
        whisperFound: whisperFound ?? this.whisperFound,
        dictation: dictation ?? this.dictation,
        download: clearDownload ? null : (download ?? this.download),
        downloadProgress:
            clearDownload ? null : (downloadProgress ?? this.downloadProgress),
        downloadPercent: clearDownload ? 0 : (downloadPercent ?? this.downloadPercent),
        timestamps: timestamps ?? this.timestamps,
        saveNextToSource: saveNextToSource ?? this.saveNextToSource,
        toLibrary: toLibrary ?? this.toLibrary,
        libraryPath: libraryPath ?? this.libraryPath,
        libraryFormats: libraryFormats ?? this.libraryFormats,
        copyFormat: copyFormat ?? this.copyFormat,
        saveFormat: saveFormat ?? this.saveFormat,
        recent: recent ?? this.recent,
        ask: clearAsk ? null : (ask ?? this.ask),
      );

  @override
  List<Object?> get props => [
        jobs,
        selected,
        lead,
        running,
        status,
        defaults,
        models,
        whisperFound,
        dictation,
        download,
        downloadProgress,
        downloadPercent,
        timestamps,
        saveNextToSource,
        toLibrary,
        libraryPath,
        libraryFormats,
        copyFormat,
        saveFormat,
        recent,
        ask,
      ];
}
