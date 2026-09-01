/// Настройки одного распознавания и то, во что они превращаются
/// на командной строке whisper-cli.
library;

import 'app_locale.dart';

/// С таймкодами модель на разговорной речи скатывается в сплошной нижний
/// регистр без знаков препинания. Затравка задаёт стиль — знаки возвращаются,
/// а таймкоды остаются (проверено на этих же записях).
///
/// Формулировка выверена по двум ошибкам, которые давала прежняя.
///
/// Первая: она называла себя «расшифровкой разговорной речи», а whisper
/// принимает подсказку не как указание, а как **предыдущий текст**, который
/// продолжает. В русском прямая речь открывается тире — и модель
/// добросовестно начинала реплику с тире. Слово «тире» в перечислении
/// знаков подсказывало то же самое. Теперь ни того, ни другого: речь идёт
/// о записанном тексте, а не о репликах, и тире в перечне нет.
///
/// Вторая: «расшифровка» и «субтитры» — соседи по обучающим данным, и
/// оттуда же приходили «Продолжение следует…» и «Субтитры сделал…».
/// Подсказка теперь не поминает ни расшифровок, ни субтитров вовсе.
const _punctuationPrimerRu =
    'Записанный текст оформлен по правилам русского языка: с запятыми и '
    'точками, с вопросительными и восклицательными знаками, каждое '
    'предложение начинается с заглавной буквы.';
const _punctuationPrimerEn =
    'The written text below follows standard punctuation: commas and periods, '
    'question and exclamation marks, and a capital letter at the start of '
    'every sentence.';

const _cyrillicLangs = {'auto', 'ru', 'be', 'uk', 'kk'};

String punctuationPrimer(String lang) =>
    _cyrillicLangs.contains(lang) ? _punctuationPrimerRu : _punctuationPrimerEn;

/// Состояние записи в очереди. Раньше это была строка, и проверка «ошибка?»
/// сводилась к сравнению с текстом на экране — стоило переписать надпись,
/// и значок ломался.
enum JobState {
  queued,
  waiting,
  converting,
  transcribing,
  paused,
  done,
  failed,
  cancelled
}

extension JobStateLabel on JobState {
  String get label {
    final l10n = currentL10n();
    return switch (this) {
      JobState.queued => l10n.jobStateQueued,
      JobState.waiting => l10n.jobStateWaiting,
      JobState.converting => l10n.jobStateConverting,
      JobState.transcribing => l10n.jobStateTranscribing,
      JobState.paused => l10n.jobStatePaused,
      JobState.done => l10n.jobStateDone,
      JobState.failed => l10n.jobStateFailed,
      JobState.cancelled => l10n.jobStateCancelled,
    };
  }
}

/// Настройки одного распознавания. Они же — общие настройки приложения:
/// у записи может быть свой набор, и тогда он замещает общий целиком.
class RunOptions {
  final String model, lang, prompt, vadModel;
  final int threads, maxLen;
  final bool vad, punctuate;
  const RunOptions({
    required this.model,
    required this.lang,
    required this.threads,
    this.maxLen = 0,
    this.vad = false,
    this.vadModel = '',
    this.prompt = '',
    this.punctuate = true,
  });

  RunOptions copyWith({
    String? model,
    String? lang,
    int? threads,
    int? maxLen,
    bool? vad,
    String? vadModel,
    String? prompt,
    bool? punctuate,
  }) =>
      RunOptions(
        model: model ?? this.model,
        lang: lang ?? this.lang,
        threads: threads ?? this.threads,
        maxLen: maxLen ?? this.maxLen,
        vad: vad ?? this.vad,
        vadModel: vadModel ?? this.vadModel,
        prompt: prompt ?? this.prompt,
        punctuate: punctuate ?? this.punctuate,
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'lang': lang,
        'threads': threads,
        'maxLen': maxLen,
        'vad': vad,
        'vadModel': vadModel,
        'prompt': prompt,
        'punctuate': punctuate,
      };

  /// Чего в файле настроек нет — берём из [fallback]: так старые файлы
  /// продолжают открываться после добавления новой галки.
  factory RunOptions.fromJson(Map<String, dynamic> j, RunOptions fallback) =>
      RunOptions(
        model: (j['model'] as String?) ?? fallback.model,
        lang: (j['lang'] as String?) ?? fallback.lang,
        threads: (j['threads'] as int?) ?? fallback.threads,
        maxLen: (j['maxLen'] as int?) ?? fallback.maxLen,
        vad: (j['vad'] as bool?) ?? fallback.vad,
        vadModel: (j['vadModel'] as String?) ?? fallback.vadModel,
        prompt: (j['prompt'] as String?) ?? fallback.prompt,
        punctuate: (j['punctuate'] as bool?) ?? fallback.punctuate,
      );

  /// Чем эта запись отличается от общих настроек — списком, для подписи
  /// «изменено: язык, модель».
  List<String> diffAgainst(RunOptions base) {
    final l10n = currentL10n();
    return [
      if (model != base.model) l10n.diffModel,
      if (lang != base.lang) l10n.diffLanguage,
      if (threads != base.threads) l10n.diffThreads,
      if (maxLen != base.maxLen) l10n.diffSegmentLength,
      if (vad != base.vad || vadModel != base.vadModel) 'VAD',
      if (prompt.trim() != base.prompt.trim()) l10n.diffPrompt,
      if (punctuate != base.punctuate) l10n.diffPunctuation,
    ];
  }

  /// Своя подсказка важнее: она уже задаёт модели и стиль, и словарь.
  String get effectivePrompt => prompt.trim().isNotEmpty
      ? prompt.trim()
      : punctuate
          ? punctuationPrimer(lang)
          : '';
}

/// Чем разрывается цепочка повторов: окно не наследует текст предыдущего,
/// а стиль держится затравкой — её подкладывают в каждое окно заново,
/// иначе с потерей контекста ушли бы и знаки препинания.
List<String> noLoopArgs(RunOptions o) => [
      '-mc', '0',
      if (o.effectivePrompt.isNotEmpty) '--carry-initial-prompt',
    ];

/// [from] — с какой миллисекунды считать. Так продолжается запись,
/// остановленная посреди: whisper умеет начать с середины и метки времени
/// отдаёт всё равно от начала файла, так что склеивать ничего не нужно.
List<String> buildArgs(RunOptions o, String wav, String outBase, {int from = 0}) => [
      '-m', o.model,
      '-l', o.lang,
      '-t', '${o.threads}',
      '-pp',
      // Отсюда и брались зацикливания на десятки минут. whisper тащит
      // распознанный текст окна в подсказку следующего: стоит одному
      // тридцатисекундному окну сорваться в повтор, как повтор приходит
      // затравкой в следующее — и модель повторяет его сама себе, пока
      // что-нибудь случайно не собьёт. Без переноса срыв остаётся внутри
      // одного окна, а оттуда его вытаскивает обычный откат по температуре.
      ...noLoopArgs(o),
      '-of', outBase,
      '-oj', // остальные форматы приложение собирает само — из одного источника

      if (from > 0) ...['-ot', '$from'],
      if (o.maxLen > 0) ...['-ml', '${o.maxLen}', '-sow'],
      if (o.vad && o.vadModel.isNotEmpty) ...['--vad', '-vm', o.vadModel],
      if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
      wav,
    ];
