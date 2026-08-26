import 'package:equatable/equatable.dart';

import '../../core/models.dart';
import '../../core/transcript.dart';
import '../../core/whisper.dart';
import 'job.dart';

/// Что случилось с очередью.
///
/// Полный Bloc, а не Cubit: здесь события нужны по делу. «Распознать» при
/// уже идущей очереди отбрасывается трансформером, а не проверкой внутри
/// обработчика; порядок и содержание событий видны в журнале, и по нему
/// читается, что происходило перед сбоем.
sealed class QueueEvent extends Equatable {
  const QueueEvent();

  @override
  List<Object?> get props => const [];
}

// ── очередь ─────────────────────────────────────────────────────────────────

/// Добавить файлы. Папки разворачиваются, готовые расшифровки открываются,
/// чужие расширения отбрасываются с объяснением.
class FilesAdded extends QueueEvent {
  const FilesAdded(this.paths);
  final Iterable<String> paths;

  @override
  List<Object?> get props => [paths];
}

/// Открыть готовую расшифровку как запись очереди.
class TranscriptOpened extends QueueEvent {
  const TranscriptOpened(this.path);
  final String path;

  @override
  List<Object?> get props => [path];
}

class SelectedRemoved extends QueueEvent {
  const SelectedRemoved();
}

class FinishedCleared extends QueueEvent {
  const FinishedCleared();
}

// ── выделение ───────────────────────────────────────────────────────────────

class JobSelected extends QueueEvent {
  const JobSelected(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class JobToggled extends QueueEvent {
  const JobToggled(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class SelectionExtended extends QueueEvent {
  const SelectionExtended(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class SelectionStepped extends QueueEvent {
  const SelectionStepped(this.delta, {this.extend = false});
  final int delta;
  final bool extend;

  @override
  List<Object?> get props => [delta, extend];
}

class AllSelected extends QueueEvent {
  const AllSelected();
}

class SelectionCleared extends QueueEvent {
  const SelectionCleared();
}

// ── распознавание ───────────────────────────────────────────────────────────

/// Запустить очередь. Отбрасывается, пока она уже идёт.
class RunRequested extends QueueEvent {
  const RunRequested();
}

/// Ответ на вопрос «модель занята, продолжить?».
class RunConfirmed extends QueueEvent {
  const RunConfirmed(this.yes);
  final bool yes;

  @override
  List<Object?> get props => [yes];
}

/// Распознать выбранное заново, забыв прежний результат.
class RetryRequested extends QueueEvent {
  const RetryRequested();
}

class StopRequested extends QueueEvent {
  const StopRequested();
}

/// Внутреннее: whisper-cli выдал очередной фрагмент, процент или язык.
class JobAdvanced extends QueueEvent {
  const JobAdvanced(this.job, {this.segment, this.progress, this.language});
  final Job job;
  final Segment? segment;
  final double? progress;
  final String? language;

  @override
  List<Object?> get props => [job.path, segment, progress, language];
}

// ── настройки распознавания ─────────────────────────────────────────────────

/// Правка уходит туда, куда смотрит инспектор: в общие настройки или
/// во все выбранные записи сразу.
class OptionsEdited extends QueueEvent {
  const OptionsEdited(this.change);
  final RunOptions Function(RunOptions) change;

  @override
  List<Object?> get props => [change];
}

class OverridesReset extends QueueEvent {
  const OverridesReset();
}

class LeadOptionsMadeDefault extends QueueEvent {
  const LeadOptionsMadeDefault();
}

// ── модели ──────────────────────────────────────────────────────────────────

class ModelChosen extends QueueEvent {
  const ModelChosen(this.path);
  final String path;

  @override
  List<Object?> get props => [path];
}

class ModelDownloadRequested extends QueueEvent {
  const ModelDownloadRequested(this.offer);
  final ModelOffer offer;

  @override
  List<Object?> get props => [offer.file];
}

class DownloadCancelled extends QueueEvent {
  const DownloadCancelled();
}

/// Внутреннее: у идущей загрузки сдвинулся процент.
class DownloadAdvanced extends QueueEvent {
  const DownloadAdvanced(this.progress, this.percent);
  final String progress;
  final int percent;

  @override
  List<Object?> get props => [progress, percent];
}

class VadRequested extends QueueEvent {
  const VadRequested(this.on);
  final bool on;

  @override
  List<Object?> get props => [on];
}

class VadModelChosen extends QueueEvent {
  const VadModelChosen(this.path);
  final String? path;

  @override
  List<Object?> get props => [path];
}

// ── прочее ──────────────────────────────────────────────────────────────────

/// Спросить у диктовки, чем она занята.
///
/// Раньше на это место приходил опрос чужих процессов: `pgrep`, `ps`
/// и `lsof` дважды в секунду — приложение искало, не держит ли модель
/// кто-то посторонний. Посторонних больше нет, диктовка своя, и весь
/// ответ — один вызов через родную сторону.
class DictationPolled extends QueueEvent {
  const DictationPolled();
}

/// Окно на виду или свёрнуто: невидимому окну значок не нужен.
class WindowVisibilityChanged extends QueueEvent {
  const WindowVisibilityChanged(this.visible);
  final bool visible;

  @override
  List<Object?> get props => [visible];
}

class SettingsReloaded extends QueueEvent {
  const SettingsReloaded();
}

class TimestampsToggled extends QueueEvent {
  const TimestampsToggled();
}


class RecentCleared extends QueueEvent {
  const RecentCleared();
}

/// Записать готовые расшифровки в буфер обмена.
class CopyRequested extends QueueEvent {
  const CopyRequested(this.format);
  final ExportFormat format;

  @override
  List<Object?> get props => [format.id];
}

/// Записать готовую расшифровку в указанный файл.
class SaveRequested extends QueueEvent {
  const SaveRequested(this.job, this.path, this.format);
  final Job job;
  final String path;
  final ExportFormat format;

  @override
  List<Object?> get props => [job.path, path, format.id];
}

/// Разложить готовые расшифровки по указанной папке.
class ExportRequested extends QueueEvent {
  const ExportRequested(this.jobs, this.dir, this.formats);
  final List<Job> jobs;
  final String dir;
  final List<ExportFormat> formats;

  @override
  List<Object?> get props => [jobs.length, dir, formats.length];
}

/// Сообщение прочитано — убрать его с экрана.
class AskDismissed extends QueueEvent {
  const AskDismissed();
}

/// Сказать что-нибудь в строке состояния. Нужно окну: часть действий
/// (копирование фрагмента, показ в проводнике) целиком его дело.
class StatusReported extends QueueEvent {
  const StatusReported(this.text);
  final String text;

  @override
  List<Object?> get props => [text];
}
