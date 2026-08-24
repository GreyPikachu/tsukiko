/// Настройки одного распознавания и то, во что они превращаются
/// на командной строке whisper-cli.
library;

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
enum JobState { queued, waiting, converting, transcribing, done, failed, cancelled }

extension JobStateLabel on JobState {
  String get label => switch (this) {
        JobState.queued => 'В очереди',
        JobState.waiting => 'Ожидает модель',
        JobState.converting => 'Подготовка звука',
        JobState.transcribing => 'Распознавание',
        JobState.done => 'Готово',
        JobState.failed => 'Не удалось распознать',
        JobState.cancelled => 'Отменено',
      };
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
  List<String> diffAgainst(RunOptions base) => [
        if (model != base.model) 'модель',
        if (lang != base.lang) 'язык',
        if (threads != base.threads) 'потоки',
        if (maxLen != base.maxLen) 'длина фрагмента',
        if (vad != base.vad || vadModel != base.vadModel) 'VAD',
        if (prompt.trim() != base.prompt.trim()) 'подсказка',
        if (punctuate != base.punctuate) 'пунктуация',
      ];

  /// Своя подсказка важнее: она уже задаёт модели и стиль, и словарь.
  String get effectivePrompt => prompt.trim().isNotEmpty
      ? prompt.trim()
      : punctuate
          ? punctuationPrimer(lang)
          : '';
}

List<String> buildArgs(RunOptions o, String wav, String outBase) => [
      '-m', o.model,
      '-l', o.lang,
      '-t', '${o.threads}',
      '-pp',
      '-of', outBase,
      '-oj', // остальные форматы приложение собирает само — из одного источника

      if (o.maxLen > 0) ...['-ml', '${o.maxLen}', '-sow'],
      if (o.vad && o.vadModel.isNotEmpty) ...['--vad', '-vm', o.vadModel],
      if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
      wav,
    ];
