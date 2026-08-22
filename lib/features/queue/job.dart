import 'dart:io';

import 'package:equatable/equatable.dart';

import '../../core/transcript.dart';
import '../../core/whisper.dart';
import '../../platform/os.dart';

/// Одна запись в очереди: файл, его состояние и то, что из него вышло.
///
/// Неизменяемая: Bloc решает, перерисовывать ли, сравнением состояний,
/// а правка на месте такому сравнению невидима — очередь молча замирала бы
/// на устаревшем виде. Каждая перемена делает новую запись через [copyWith].
class Job extends Equatable {
  const Job(
    this.file, {
    this.imported = false,
    this.state = JobState.queued,
    this.detail,
    this.progress = 0,
    this.live = const [],
    this.transcript,
    this.raw,
    this.overrides,
    this.besideSource,
    this.startedAt,
    this.took,
  });

  final File file;

  /// Расшифровку открыли из файла — распознавать в ней нечего.
  final bool imported;

  final JobState state;

  /// Уточнение к состоянию: «Русский · 42 фрагмента». Пусто — показываем
  /// само состояние.
  final String? detail;

  final double progress;

  /// Фрагменты, которые модель уже выдала, пока идёт распознавание.
  ///
  /// Список заменяется целиком на каждый фрагмент: добавление в общий
  /// прошло бы мимо сравнения состояний. Цена невелика — фрагмент приходит
  /// раз в пару секунд, а не в каждом кадре. В сравнение при этом входит
  /// только длина (см. [props]): список растёт и никогда не переписывается,
  /// а сверять тысячи фрагментов поэлементно на каждой перерисовке незачем.
  final List<Segment> live;

  final Transcript? transcript;
  final String? raw;

  /// Свои настройки записи. null — берутся общие.
  final RunOptions? overrides;

  /// Куда легла копия текста рядом с исходной записью. Запоминается, чтобы
  /// повторное распознавание обновило свой же файл, а не наплодило
  /// «запись 2.txt», «запись 3.txt».
  final String? besideSource;

  final DateTime? startedAt;
  final Duration? took;

  String get path => file.path;
  String get name => os.basename(file.path);
  bool get active =>
      state == JobState.converting || state == JobState.transcribing;
  bool get done => transcript != null || raw != null;
  List<Segment> get segments => transcript?.segments ?? live;

  /// Сколько ещё осталось, если считать, что дальше пойдёт с той же скоростью.
  ///
  /// Считается от текущего времени, поэтому в сравнение состояний не входит:
  /// иначе очередь перерисовывалась бы просто оттого, что время идёт.
  Duration? get eta {
    final started = startedAt;
    if (started == null || progress < 0.05) return null;
    final spent = DateTime.now().difference(started);
    return spent * ((1 - progress) / progress);
  }

  Job copyWith({
    JobState? state,
    String? detail,
    double? progress,
    List<Segment>? live,
    Transcript? transcript,
    String? raw,
    RunOptions? overrides,
    String? besideSource,
    DateTime? startedAt,
    Duration? took,
    // Обнулять поля иначе нечем: `null` в именованном параметре
    // не отличить от «не передали».
    bool clearDetail = false,
    bool clearOverrides = false,
  }) =>
      Job(
        file,
        imported: imported,
        state: state ?? this.state,
        detail: clearDetail ? null : (detail ?? this.detail),
        progress: progress ?? this.progress,
        live: live ?? this.live,
        transcript: transcript ?? this.transcript,
        raw: raw ?? this.raw,
        overrides: clearOverrides ? null : (overrides ?? this.overrides),
        besideSource: besideSource ?? this.besideSource,
        startedAt: startedAt ?? this.startedAt,
        took: took ?? this.took,
      );

  /// Записать ещё один распознанный фрагмент.
  Job withSegment(Segment s) => copyWith(live: [...live, s]);

  /// Забыть результат и встать обратно в очередь — «распознать заново».
  Job get reset => Job(file, imported: imported, overrides: overrides);

  /// Файл — то, чем запись отличается от соседки: в очереди он уникален.
  /// Остальное входит в сравнение, чтобы перерисовка замечала перемены.
  @override
  List<Object?> get props => [
        file.path,
        imported,
        state,
        detail,
        progress,
        live.length,
        transcript,
        raw,
        overrides,
        besideSource,
        startedAt,
        took,
      ];
}
