part of 'main.dart';

/// Одна запись в очереди: файл, его состояние и то, что из него вышло.
class Job {
  Job(this.file, {this.imported = false});
  final File file;

  /// Расшифровку открыли из файла — распознавать в ней нечего.
  final bool imported;

  JobState state = JobState.queued;

  /// Уточнение к состоянию: «Русский · 42 фрагмента». Пусто — показываем
  /// само состояние.
  String? detail;

  double progress = 0;
  final List<Segment> live = [];
  Transcript? transcript;
  String? raw;

  /// Свои настройки записи. null — берутся общие.
  RunOptions? overrides;

  DateTime? startedAt;
  Duration? took;

  String get name => file.path.split('/').last;
  bool get active =>
      state == JobState.converting || state == JobState.transcribing;
  bool get done => transcript != null || raw != null;
  List<Segment> get segments => transcript?.segments ?? live;

  /// Сколько ещё осталось, если считать, что дальше пойдёт с той же скоростью.
  Duration? get eta {
    final started = startedAt;
    if (started == null || progress < 0.05) return null;
    final spent = DateTime.now().difference(started);
    return spent * ((1 - progress) / progress);
  }

  void reset() {
    transcript = null;
    raw = null;
    live.clear();
    progress = 0;
    detail = null;
    took = null;
    startedAt = null;
    state = JobState.queued;
  }
}
