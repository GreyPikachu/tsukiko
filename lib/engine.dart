import 'dart:convert';
import 'dart:io';

/// Всё, что не про интерфейс: пути, запуск whisper-cli, форматы,
/// раскладка библиотеки и надзор за занятостью модели.

const whisperCandidates = [
  '/opt/homebrew/bin/whisper-cli',
  '/usr/local/bin/whisper-cli',
];


const audioExt = {
  '.ogg', '.oga', '.opus', '.mp3', '.m4a', '.aac', '.wav', '.aiff', '.aif',
  '.caf', '.flac', '.mp4', '.mov', '.m4b', '.wma',
};

/// Расшифровки, которые приложение умеет открывать — и через диалог,
/// и перетаскиванием.
const transcriptExt = {'.txt', '.srt', '.vtt', '.json', '.md'};

const languages = [
  'auto', 'ru', 'be', 'uk', 'en', 'pl', 'de', 'fr', 'es', 'it', 'pt', 'tr',
  'kk', 'he', 'ar', 'zh', 'ja',
];

/// Языки называются так, как их называют их носители, — как в системных
/// настройках macOS. Код в интерфейсе не показываем никогда.
const _languageNames = {
  'auto': 'Определять автоматически',
  'ru': 'Русский',
  'be': 'Беларуская',
  'uk': 'Українська',
  'en': 'English',
  'pl': 'Polski',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'tr': 'Türkçe',
  'kk': 'Қазақша',
  'he': 'עברית',
  'ar': 'العربية',
  'zh': '中文',
  'ja': '日本語',
};

String languageName(String code) =>
    _languageNames[code.toLowerCase()] ?? code.toUpperCase();

const appName = 'tsukiko';

// ── маленькие правила языка и чисел ─────────────────────────────────────────

/// «1 фрагмент · 2 фрагмента · 5 фрагментов». Без этого интерфейс на русском
/// сразу выдаёт, что его переводили наспех.
String plural(int n, String one, String few, String many) {
  final h = n.abs() % 100, t = n.abs() % 10;
  if (h >= 11 && h <= 14) return many;
  if (t == 1) return one;
  if (t >= 2 && t <= 4) return few;
  return many;
}

String segmentsLabel(int n) => '$n ${plural(n, 'фрагмент', 'фрагмента', 'фрагментов')}';

String wordsLabel(int n) => '$n ${plural(n, 'слово', 'слова', 'слов')}';

String filesLabel(int n) => '$n ${plural(n, 'файл', 'файла', 'файлов')}';

String recordsLabel(int n) => '$n ${plural(n, 'запись', 'записи', 'записей')}';

int wordCount(String text) =>
    RegExp(r'[^\s]+').allMatches(text).length;

/// Длительность для человека: «4:07», «1:12:30». Часы появляются только когда
/// они есть — лишние нули читаются как шум.
String humanDuration(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String get home => Platform.environment['HOME']!;

String get supportDir => '$home/Library/Application Support/app.yuko.tsukiko';

/// Библиотека расшифровок — обычная папка, которую видно в Finder.
String get defaultLibraryPath => '$home/Documents/$appName';

String monthFolder(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

/// Куда и под каким именем лечь файлам одной записи.
class Placement {
  const Placement(this.dir, this.stem);
  final String dir, stem;

  String pathFor(String ext) => '$dir/$stem$ext';
}

String _free(String path, bool Function(String) taken) {
  if (!taken(path)) return path;
  final slash = path.lastIndexOf('/');
  final dotAt = path.lastIndexOf('.');
  final hasExt = dotAt > slash;
  final head = hasExt ? path.substring(0, dotAt) : path;
  final ext = hasExt ? path.substring(dotAt) : '';
  for (var n = 2; n < 1000; n++) {
    final candidate = '$head $n$ext';
    if (!taken(candidate)) return candidate;
  }
  return '$head ${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// Один формат — файл лежит прямо в папке месяца. Форматов несколько —
/// у записи появляется своя папка, иначе месяц превращается в свалку.
Placement planPlacement({
  required String root,
  required String stem,
  required int formatCount,
  DateTime? now,
}) {
  final month = '$root/${monthFolder(now ?? DateTime.now())}';
  if (formatCount > 1) {
    final dir = _free('$month/$stem', (p) => Directory(p).existsSync());
    return Placement(dir, stem);
  }
  return Placement(month, stem);
}

/// Свободное имя внутри папки: «Запись 2.txt», если «Запись.txt» уже занято.
String freeStem(String dir, String stem, String ext) {
  final name = _free('$dir/$stem$ext', (p) => File(p).existsSync()).split('/').last;
  return name.substring(0, name.length - ext.length);
}

/// Папку открываем, файл — показываем в папке и выделяем. Раньше и то и другое
/// шло через `open`, и щелчок по файлу запускал его в проигрывателе.
Future<void> revealInFinder(String path) async {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.notFound) {
    Directory(path).createSync(recursive: true);
    await Process.run('open', [path]);
    return;
  }
  await Process.run(
      'open', type == FileSystemEntityType.directory ? [path] : ['-R', path]);
}

String? findWhisper() {
  for (final p in whisperCandidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Файл модели распознавания. Имя VAD-модели устроено так же
/// (ggml-silero-….bin), но речь она не распознаёт — в списке моделей ей
/// не место, иначе её можно выбрать и получить пустую расшифровку.
bool looksLikeSpeechModel(String name) =>
    name.startsWith('ggml-') && name.endsWith('.bin') && !name.contains('silero');

List<String> findModels() {
  final dirs = [
    '$home/Library/Application Support/app.dictara/models',
    '$home/.cache/whisper',
    '$supportDir/models',
  ];
  final out = <String>[];
  for (final d in dirs) {
    final dir = Directory(d);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File && looksLikeSpeechModel(f.path.split('/').last)) out.add(f.path);
    }
  }
  out.sort();
  return out;
}

// ── откуда берутся модели ───────────────────────────────────────────────────
//
// Без файла модели приложение бесполезно, а взять его новому человеку
// неоткуда. Поэтому качаем сами — в свою папку, которую findModels() уже
// просматривает.

const _modelRepo = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

/// VAD лежит в другом репозитории: в ggerganov/whisper.cpp этого файла нет,
/// оттуда приходит 404.
const vadModelFile = 'ggml-silero-v5.1.2.bin';
const vadModelUrl =
    'https://huggingface.co/ggml-org/whisper-vad/resolve/main/$vadModelFile';

String modelPathFor(String file) => '$supportDir/models/$file';

String get vadModelPath => modelPathFor(vadModelFile);

String sizeLabelMb(int mb) => mb >= 1024
    ? '${(mb / 1024).toStringAsFixed(1).replaceAll('.', ',')} ГБ'
    : '$mb МБ';

/// Имя модели, одно на всё приложение: загрузчик, панель, переключатель,
/// инспектор и диалоги называют «ggml-large-v3-turbo.bin» одинаково —
/// «Large v3 Turbo». Модель может быть и не из каталога (свой файл, папка
/// Dictara), поэтому имя разбирается из имени файла, а не ищется в списке:
/// слова из букв — с заглавной, версии и квантование — как есть.
String modelDisplayName(String path) {
  final file = path.split('/').last;
  final stem = file
      .replaceFirst(RegExp(r'^ggml-'), '')
      .replaceFirst(RegExp(r'\.bin$'), '')
      .trim();
  if (stem.isEmpty) return file;
  return stem
      .split(RegExp(r'[-\s.]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => RegExp(r'^[a-zA-Zа-яА-Я]+$').hasMatch(w)
          ? w[0].toUpperCase() + w.substring(1).toLowerCase()
          : w)
      .join(' ');
}

/// Годится ли выбранный файл в модель распознавания. Возвращает null,
/// если годится, иначе — фразу для человека.
///
/// Расширения «.bin» мало: под ним лежит что угодно, а whisper-cli
/// на чужом файле падает с английской руганью про тензоры. Настоящая
/// модель ggml начинается с числа «ggml» (на диске это байты «lmgg»),
/// а следом идёт размер словаря — у модели речи он десятки тысяч слов,
/// у модели тишины десять. По этим двум числам речевая модель отличается
/// и от мусора, и от VAD.
String? modelFileProblem(String path) {
  final file = File(path);
  final name = path.split('/').last;
  if (!file.existsSync()) return 'Файла «$name» больше нет на диске.';

  final size = file.lengthSync();
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final head = raf.readSync(8);
    if (head.length < 8 || String.fromCharCodes(head.sublist(0, 4)) != 'lmgg') {
      return '«$name» — не модель распознавания речи: у файлов ggml '
          'в начале стоит своя метка, а здесь её нет.';
    }
    // Little-endian uint32 сразу за меткой.
    final vocab = head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24);
    if (vocab < 1000) {
      return '«$name» — модель ggml, но не речевая: в ней $vocab '
          'слов словаря. Так выглядит модель распознавания тишины (VAD), '
          'речь она не расшифровывает.';
    }
  } catch (_) {
    return 'Файл «$name» не удалось прочитать.';
  } finally {
    raf?.closeSync();
  }

  // Самая маленькая речевая модель — tiny, 74 МБ; квантованная чуть меньше.
  if (size < 20 * 1024 * 1024) {
    return '«$name» слишком мал для модели распознавания: '
        '${sizeLabelMb(size ~/ (1024 * 1024))}, а самая маленькая весит 74 МБ.';
  }
  return null;
}

/// Модель, которую приложение умеет достать само. Размер записан здесь,
/// а не спрашивается у сервера: выбирать надо до загрузки, а не после.
class ModelOffer {
  const ModelOffer(this.file, this.mb, this.about);
  final String file, about;
  final int mb;

  /// Имя общее со всем приложением: отдельное поле разошлось бы с ним.
  String get title => modelDisplayName(file);
  String get url => '$_modelRepo/$file';
  String get path => modelPathFor(file);
  bool get present => File(path).existsSync();
  String get size => sizeLabelMb(mb);
}

const modelCatalog = [
  ModelOffer('ggml-tiny.bin', 74, 'Попробовать, что всё работает'),
  ModelOffer('ggml-base.bin', 141, 'Быстрая, но путает слова'),
  ModelOffer('ggml-small.bin', 465, 'Разумный минимум для русского'),
  ModelOffer('ggml-medium.bin', 1463, 'Точнее Small, заметно медленнее'),
  ModelOffer('ggml-large-v3-turbo.bin', 1549, 'Лучшая и при этом быстрая'),
];

/// Загрузка файла с докачкой. Пишем в «.part» рядом и переименовываем только
/// в конце: обрыв на полутора гигабайтах не должен оставить огрызок, который
/// findModels() покажет как готовую модель.
class Download {
  Download(this.url, this.dest, {this.title = ''});

  final String url, dest, title;

  /// Байты: сколько уже есть и сколько всего. Ноль в [total] — сервер
  /// не сказал длину, тогда процент показывать не из чего.
  int got = 0, total = 0;
  bool cancelled = false;

  /// Почему не вышло — человеческими словами, для показа на экране.
  /// Пусто, пока всё идёт хорошо или пока загрузку отменили сами.
  String? error;

  int get percent => total > 0 ? (got * 100 ~/ total).clamp(0, 100) : 0;

  String get progressLabel {
    const mb = 1024 * 1024;
    final done = (got / mb).round();
    return total > 0 ? '$percent % · $done из ${(total / mb).round()} МБ'
                     : '$done МБ';
  }

  void cancel() => cancelled = true;

  /// Возвращает путь к готовому файлу или null: отменили, оборвалось,
  /// сервер ответил не тем. Недокачанное остаётся в «.part» — следующий
  /// заход продолжит с того же места.
  Future<String?> run({void Function()? onProgress}) async {
    if (File(dest).existsSync()) return dest;
    error = null;
    final uri = Uri.parse(url);
    final part = File('$dest.part');
    try {
      part.parent.createSync(recursive: true);
    } catch (_) {
      error = 'некуда положить файл: папка ${part.parent.path} недоступна';
      return null;
    }
    var have = part.existsSync() ? part.lengthSync() : 0;

    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        error = '${uri.host} ответил ${res.statusCode}';
        return null;
      }
      // Докачку не поняли — начинаем сначала, это дороже, но верно.
      if (res.statusCode == HttpStatus.ok) have = 0;
      got = have;
      total = res.contentLength > 0 ? have + res.contentLength : 0;

      final sink = part.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
      var shown = -1;
      try {
        await for (final chunk in res) {
          if (cancelled) return null;
          sink.writeFromSync(chunk);
          got += chunk.length;
          // Кусок приходит десятками килобайт: на полутора гигабайтах это
          // двадцать тысяч перерисовок. Дёргаем экран только на новом проценте.
          if (percent != shown) {
            shown = percent;
            onProgress?.call();
          }
        }
      } finally {
        sink.closeSync();
      }
      if (total > 0 && got < total) {
        error = 'связь оборвалась на $percent %';
        return null;
      }
      part.renameSync(dest);
      return dest;
    } catch (e) {
      // Текст исключения показывать нельзя: он английский и про сокеты.
      // Человеку важно другое — сеть или сервер, и что делать дальше.
      error = e is SocketException
          ? 'нет связи с ${uri.host}'
          : 'не удалось скачать с ${uri.host}';
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

// ── занятость модели ────────────────────────────────────────────────────────
//
// В macOS нет замка «модель занята», поэтому судим по косвенным признакам.
// Первая версия смотрела только на память: кто держит больше половины веса
// модели, тот её и загрузил. На whisper-cli это работает (large-v3-turbo —
// около 1,8 ГБ резидентной памяти), но на Dictara не работало вовсе:
// замер во время диктовки дал пик 139 МБ при модели в 1,6 ГБ и ни одного
// открытого дескриптора — модель у неё не лежит в резидентной памяти.
//
// Единственный признак, который не может отсутствовать у того, кто прямо
// сейчас распознаёт речь, — это потраченное процессорное время. Поэтому
// главный сигнал теперь такой: сколько CPU-секунд процесс сжёг между двумя
// опросами. Фоновая Dictara в простое тратит около 0,2 % ядра, работающая —
// на порядки больше, так что порог различает их с огромным запасом.

enum ModelState { free, loading, busy }

/// Насколько ядра должен потратить процесс между опросами, чтобы считаться
/// работающим. Замер фоновой Dictara в простое — 0,002 ядра, так что запас
/// стократный; выше поднимать нельзя — часть работы может уходить на ANE.
const _busyCpuShare = 0.20;

/// На сколько должна вырасти резидентная память между опросами, чтобы это
/// значило «читают модель». Второй признак нужен затем, что он не зависит
/// от порога по процессору: у Dictara во время диктовки память идёт
/// с 42 МБ до 139 МБ, и такой скачок виден, даже если считает не процессор.
const _loadingGrowthKb = 40 * 1024;

/// Снимок кандидатов на момент опроса. Сам по себе он ни о чём не говорит —
/// важна разница между двумя замерами.
class CpuSample {
  const CpuSample(this.at, this.byPid);
  const CpuSample.empty() : at = null, byPid = const {};

  final DateTime? at;

  /// pid → накопленное процессорное время в секундах и резидентная память в КБ.
  final Map<int, ({double cpu, int rssKb})> byPid;
}

class ModelUse {
  const ModelUse(
    this.state, {
    this.by = '',
    this.pid = 0,
    this.rssKb = 0,
    this.share = 0,
    this.learned = const {},
    this.cpu = const CpuSample.empty(),
  });

  final ModelState state;
  final String by;

  /// Кто именно занял модель. Имя процесса для этого не годится: у соседа
  /// может работать свой whisper-server, а гасить нам можно только свой.
  final int pid;

  final int rssKb;

  /// Сколько ядер процесс занимал между двумя последними опросами.
  final double share;

  final Set<String> learned;
  final CpuSample cpu;

  bool get busy => state != ModelState.free;

  String get label => switch (state) {
        ModelState.free => 'Модель свободна',
        ModelState.loading => 'Модель загружается · $by',
        ModelState.busy => 'Модель занята · $by',
      };

  /// Подробности для подсказки: по чему именно видно, что процесс работает.
  String get detail => switch (state) {
        ModelState.free => 'Никто не распознаёт речь прямо сейчас.',
        ModelState.loading => '$by читает файл модели в память.',
        ModelState.busy => share >= _busyCpuShare
            ? '$by занимает ${(share * 100).round()} % процессора.'
            : '$by держит ${(rssKb / 1024).round()} МБ в памяти.',
      };
}

/// «69:20.60», «1:02:03.4», «2-03:04:05» → секунды.
double? cpuSeconds(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  var days = 0;
  final dash = text.indexOf('-');
  if (dash > 0) {
    days = int.tryParse(text.substring(0, dash)) ?? 0;
    text = text.substring(dash + 1);
  }
  final parts = text.split(':');
  var total = double.tryParse(parts.last);
  if (total == null) return null;
  if (parts.length > 1) total += (int.tryParse(parts[parts.length - 2]) ?? 0) * 60;
  if (parts.length > 2) total += (int.tryParse(parts[parts.length - 3]) ?? 0) * 3600;
  return total + days * 86400;
}

/// Приложение обычно хранит модель у себя в Application Support — по пути
/// к файлу можно догадаться, кто её хозяин, ещё до первой встречи.
String? ownerFromModelPath(String modelPath) {
  final m = RegExp(r'/Application Support/([^/]+)/').firstMatch(modelPath);
  if (m == null) return null;
  final parts = m.group(1)!.split('.');
  final name = parts.last.toLowerCase();
  return name.isEmpty ? null : name;
}

Future<List<int>> _pids(String cmd, List<String> args) async {
  try {
    final r = await Process.run(cmd, args);
    return (r.stdout as String)
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Кто сейчас распознаёт речь на этой машине.
///
/// [modelPath] — выбранная модель, по её весу считается порог по памяти.
/// [others] — остальные известные модели: чужое приложение может держать
/// свою, а не нашу, и раньше мы такого соседа не видели вовсе.
/// [previous] — замер CPU с прошлого опроса, без него признак работы
/// посчитать не из чего.
/// [probeHolders] — запускать ли lsof (самая дорогая часть опроса, около
/// 150 мс); он нужен только чтобы поймать короткий момент загрузки.
Future<ModelUse> modelUsage({
  required String modelPath,
  List<String> others = const [],
  Set<String> learned = const {},
  int? ignorePid,
  CpuSample previous = const CpuSample.empty(),
  bool probeHolders = true,
}) async {
  final paths = <String>{if (modelPath.isNotEmpty) modelPath, ...others}
      .where((p) => File(p).existsSync())
      .toList();
  if (paths.isEmpty) {
    return ModelUse(ModelState.free, learned: learned, cpu: previous);
  }
  try {
    // Порог по памяти — от размера выбранной модели: половину её веса
    // случайный процесс в памяти не держит. Признак сильный, но не
    // обязательный: кто-то грузит модель целиком, кто-то читает её кусками.
    final selected = File(paths.contains(modelPath) ? modelPath : paths.first);
    final thresholdKb = selected.lengthSync() ~/ 2048;

    final names = {...learned};
    for (final p in paths) {
      final owner = ownerFromModelPath(p);
      // Скачанные модели лежат в нашей же папке, и владельцем по пути
      // угадываемся мы сами. Себя в соседи записывать нельзя: вторая копия
      // и так не запускается, а первая — это мы.
      if (owner != null && owner != appName) names.add(owner);
    }

    final holders = probeHolders ? await _pids('lsof', ['-t', ...paths]) : const <int>[];
    final candidates = <int>{...holders};
    candidates.addAll(await _pids('pgrep', ['-f', 'whisper']));
    for (final n in names) {
      candidates.addAll(await _pids('pgrep', ['-x', n]));
    }
    candidates.remove(pid);
    if (ignorePid != null) candidates.remove(ignorePid);
    if (candidates.isEmpty) {
      return ModelUse(ModelState.free, learned: learned, cpu: const CpuSample.empty());
    }

    final now = DateTime.now();
    final ps = await Process.run(
        'ps', ['-o', 'pid=,rss=,time=,comm=', '-p', candidates.join(',')]);

    final sampled = <int, ({double cpu, int rssKb})>{};
    final seen = <String>{...learned};
    final gap = previous.at == null
        ? 0.0
        : now.difference(previous.at!).inMilliseconds / 1000;

    var best = const ModelUse(ModelState.free);
    var bestScore = 0.0;

    for (final line in (ps.stdout as String).split('\n')) {
      final m =
          RegExp(r'^\s*(\d+)\s+(\d+)\s+([\d:.\-]+)\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      final procPid = int.parse(m.group(1)!);
      final rss = int.parse(m.group(2)!);
      final cpu = cpuSeconds(m.group(3)!) ?? 0;
      final name = m.group(4)!.trim().split('/').last;
      if (holders.contains(procPid)) seen.add(name.toLowerCase());
      sampled[procPid] = (cpu: cpu, rssKb: rss);

      // Сколько ядер процесс занимал с прошлого опроса. Слишком короткий
      // промежуток не измеряем — там сплошная погрешность округления ps.
      final was = previous.byPid[procPid];
      final measurable = was != null && gap >= 0.25;
      final share = measurable ? ((cpu - was.cpu) / gap).clamp(0.0, 64.0) : 0.0;
      final growthKb = measurable ? rss - was.rssKb : 0;

      // Три независимых признака. Память целиком ловит whisper-cli и всё,
      // что разворачивает модель классически; процессор и резкий рост
      // памяти — тех, кто читает её кусками, как Dictara.
      final byMemory = rss > thresholdKb;
      final byCpu = share >= _busyCpuShare;
      final byGrowth = growthKb >= _loadingGrowthKb;

      if (byMemory || byCpu || byGrowth) {
        final score = byMemory ? rss / thresholdKb : (byCpu ? share : 1.0);
        if (score > bestScore) {
          bestScore = score;
          best = ModelUse(ModelState.busy,
              by: name, pid: procPid, rssKb: rss, share: share, learned: seen);
        }
        continue;
      }

      // Файл открыт прямо сейчас, а работы ещё не видно — читают модель.
      if (holders.contains(procPid) && bestScore <= 0) {
        best = ModelUse(ModelState.loading,
            by: name, pid: procPid, rssKb: rss, learned: seen);
      }
    }

    final cpu = CpuSample(now, sampled);
    return ModelUse(best.state,
        by: best.by,
        pid: best.pid,
        rssKb: best.rssKb,
        share: best.share,
        learned: seen,
        cpu: cpu);
  } catch (_) {
    return ModelUse(ModelState.free, learned: learned, cpu: previous);
  }
}

/// ogg/opus, m4a, mp3… → 16 кГц моно WAV штатным afconvert (ffmpeg не нужен).
/// whisper-cli сам читает только wav/mp3/ogg-vorbis/flac и падает на opus,
/// поэтому конвертируем всегда; не осилил — отдаём исходник как есть.
Future<String> toWav(String src, String dst) async {
  final r = await Process.run(
      'afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', src, dst]);
  return (r.exitCode == 0 && File(dst).existsSync()) ? dst : src;
}

/// С таймкодами модель на разговорной речи скатывается в сплошной нижний
/// регистр без знаков препинания. Затравка задаёт стиль — знаки возвращаются,
/// а таймкоды остаются (проверено на этих же записях).
const _punctuationPrimerRu =
    'Ниже — расшифровка разговорной речи с полной пунктуацией: запятые, точки, '
    'тире, вопросительные и восклицательные знаки, заглавные буквы в начале '
    'предложений.';
const _punctuationPrimerEn =
    'The following is a transcript of conversational speech with full '
    'punctuation: commas, periods, dashes, question and exclamation marks, and '
    'capitalized sentence beginnings.';

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

class Segment {
  final int from, to;
  final String text;
  const Segment(this.from, this.to, this.text);
}

class Transcript {
  final String lang;
  final List<Segment> segments;
  const Transcript(this.lang, this.segments);
}

final _segmentLine = RegExp(
    r'^\[(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)\]\s*(.*)$');

/// whisper-cli печатает готовые сегменты по ходу работы — ловим их сразу,
/// чтобы текст появлялся во время распознавания, а не только в конце.
Segment? parseSegmentLine(String line) {
  final m = _segmentLine.firstMatch(line.trim());
  if (m == null) return null;
  int at(int i) => int.parse(m.group(i)!);
  final from = at(1) * 3600000 + at(2) * 60000 + at(3) * 1000 + at(4);
  final to = at(5) * 3600000 + at(6) * 60000 + at(7) * 1000 + at(8);
  final text = m.group(9)!.trim();
  return text.isEmpty ? null : Segment(from, to, text);
}

final _cue = RegExp(
    r'(\d+):(\d{2}):(\d{2})[.,](\d{3})\s*(?:-->|→)\s*(\d+):(\d{2}):(\d{2})[.,](\d{3})');

/// SRT, VTT и наш собственный «текст с таймкодами» — один разбор на всех:
/// у всех трёх пара времён в строке, а текст идёт следом. Разобранная
/// расшифровка ведёт себя как распознанная — её можно пересохранить
/// в любой другой формат.
Transcript? parseSubtitles(String text) {
  final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n'));
  final segs = <Segment>[];
  for (var i = 0; i < lines.length; i++) {
    final m = _cue.firstMatch(lines[i]);
    if (m == null) continue;
    int at(int g) => int.parse(m.group(g)!);
    final from = at(1) * 3600000 + at(2) * 60000 + at(3) * 1000 + at(4);
    final to = at(5) * 3600000 + at(6) * 60000 + at(7) * 1000 + at(8);

    // Текст либо идёт после метки в той же строке («[00:00 → 00:01]  раз»),
    // либо со следующей и до пустой строки — как в SRT.
    final buf = <String>[];
    final tail = lines[i].substring(m.end).replaceFirst(RegExp(r'^\s*\]?\s*'), '');
    if (tail.trim().isNotEmpty) {
      buf.add(tail.trim());
    } else {
      var j = i + 1;
      while (j < lines.length &&
          lines[j].trim().isNotEmpty &&
          !_cue.hasMatch(lines[j])) {
        buf.add(lines[j].trim());
        j++;
      }
      i = j - 1;
    }
    final body = buf.join(' ').trim();
    if (body.isNotEmpty) segs.add(Segment(from, to, body));
  }
  return segs.isEmpty ? null : Transcript('?', segs);
}

Transcript parseWhisperJson(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final lang = (data['result']?['language'] ?? '?').toString();
  final segs = <Segment>[];
  for (final t in (data['transcription'] as List? ?? [])) {
    segs.add(Segment(
      (t['offsets']['from'] as num).toInt(),
      (t['offsets']['to'] as num).toInt(),
      (t['text'] as String).trim(),
    ));
  }
  return Transcript(lang, segs);
}

String fmtTs(int ms, {String msSep = '.'}) {
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final r = ms % 1000;
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(h)}:${p(m)}:${p(s)}$msSep${p(r, 3)}';
}

String renderPlain(List<Segment> segs, bool timestamps) => timestamps
    ? segs.map((s) => '[${fmtTs(s.from)} → ${fmtTs(s.to)}]  ${s.text}').join('\n')
    : segs.map((s) => s.text).join('\n');

String renderSrt(List<Segment> segs) {
  final b = StringBuffer();
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    b.writeln('${i + 1}');
    b.writeln('${fmtTs(s.from, msSep: ',')} --> ${fmtTs(s.to, msSep: ',')}');
    b.writeln(s.text);
    b.writeln();
  }
  return b.toString();
}

String renderVtt(List<Segment> segs) {
  final b = StringBuffer('WEBVTT\n\n');
  for (final s in segs) {
    b.writeln('${fmtTs(s.from)} --> ${fmtTs(s.to)}');
    b.writeln(s.text);
    b.writeln();
  }
  return b.toString();
}

String renderJson(Transcript t) => const JsonEncoder.withIndent('  ').convert({
      'language': t.lang,
      'segments': [
        for (final s in t.segments) {'from': s.from, 'to': s.to, 'text': s.text},
      ],
    });

String renderMarkdown(String name, Transcript t) {
  final b = StringBuffer('# $name\n\nЯзык: ${t.lang} · сегментов: ${t.segments.length}\n\n');
  for (final s in t.segments) {
    b.writeln('**[${fmtTs(s.from)}]** ${s.text}\n');
  }
  return b.toString();
}

/// Формат экспорта — именованный, с собственным окончанием имени файла.
/// Раньше содержимое .txt зависело от галки «показывать метки времени»,
/// то есть настройка вида молча меняла файл. Теперь это разные форматы.
class ExportFormat {
  const ExportFormat(this.id, this.label, this.suffix);
  final String id, label, suffix;

  String fileName(String stem) => '$stem$suffix';
  String get ext => suffix.substring(suffix.lastIndexOf('.'));
}

const formatPlainText = ExportFormat('txt', 'Текст без таймкодов', '.txt');
const formatTimedText =
    ExportFormat('txt-ts', 'Текст с таймкодами', ' (таймкоды).txt');
const formatSrt = ExportFormat('srt', 'Субтитры SRT', '.srt');
const formatVtt = ExportFormat('vtt', 'Субтитры VTT', '.vtt');
const formatMarkdown = ExportFormat('md', 'Markdown', '.md');
const formatJson = ExportFormat('json', 'JSON с миллисекундами', '.json');

const exportFormats = [
  formatPlainText,
  formatTimedText,
  formatSrt,
  formatVtt,
  formatMarkdown,
  formatJson,
];

ExportFormat formatById(String id) =>
    exportFormats.firstWhere((f) => f.id == id, orElse: () => formatPlainText);

String renderAs(ExportFormat f, Transcript t, {String name = ''}) => switch (f.id) {
      'txt' => renderPlain(t.segments, false),
      'txt-ts' => renderPlain(t.segments, true),
      'srt' => renderSrt(t.segments),
      'vtt' => renderVtt(t.segments),
      'md' => renderMarkdown(name, t),
      'json' => renderJson(t),
      _ => renderPlain(t.segments, false),
    };

/// Настройки: обычный JSON в Application Support, без лишних пакетов.
class Settings {
  static File get _file => File('$supportDir/settings.json');

  static Map<String, dynamic> load() {
    try {
      return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Дописываем, а не переписываем: файл правят два окна на разных
  /// изолятах, и каждое знает только свои ключи. Целиком записанный файл
  /// затирал бы чужие правки прошлой минуты.
  static void save(Map<String, dynamic> data) {
    try {
      Directory(supportDir).createSync(recursive: true);
      _file.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({...load(), ...data}));
    } catch (_) {}
  }
}

/// Вторая копия не должна поднимать вторую модель в память.
RandomAccessFile? acquireSingleInstanceLock() {
  try {
    Directory(supportDir).createSync(recursive: true);
    final raf = File('$supportDir/app.lock').openSync(mode: FileMode.write);
    raf.lockSync(FileLock.exclusive);
    return raf;
  } catch (_) {
    return null;
  }
}
