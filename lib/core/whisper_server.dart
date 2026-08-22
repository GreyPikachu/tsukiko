import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../core/library.dart';
import '../core/whisper.dart';
import '../platform/os.dart';
import '../core/settings.dart';

/// Фоновая диктовка: долгоживущий whisper-server, который держит модель
/// в памяти между фразами, и состояние самой диктовки.
///
/// Ядро замысла — время. Холодный whisper-cli тратит на короткую фразу
/// секунды: почти всё уходит на чтение модели с диска. Сервер читает её
/// один раз, поэтому распознавание фразы занимает около полусекунды.
/// Сервер поднимается в тот момент, когда пользователь начал говорить,
/// и успевает загрузиться, пока фраза не кончилась.

String? findWhisperServer() => os.findExecutable('whisper-server');

/// Модель весит гигабайты, поэтому осиротевший сервер — это не «лишний
/// процесс», а полтора гигабайта, которые никто не вернёт. Pid пишется
/// на диск, и следующий запуск добивает того, кто пережил падение.
File get _pidFile => File(os.join(supportDir, 'whisper-server.pid'));

/// Метка своего сервера в аргументах процесса. Нужна затем, что pid-файл
/// теряется: приложение падает, его убивают сигналом, файл стирают — и
/// сервер с полутора гигабайтами становится невидимым навсегда.
/// Аргументы процесса не теряются никогда, поэтому метка живёт в них.
///
/// `--tmp-dir` сервер читает только вместе с `--convert`, которого мы
/// не просим: на поведение метка не влияет, а в списке процессов видна.
///
/// Путь внутри своих же данных, а не `/tmp/…`: на Windows такой папки нет
/// вовсе, а значение должно оставаться похожим на путь — вдруг когда-нибудь
/// сервер начнёт его проверять.
String get serverMark => os.join(supportDir, 'whisper-server-mark');

/// Метка прежних сборок. Только для узнавания: сирота, поднятая старой
/// версией, тоже наша, и оставлять её с полутора гигабайтами нельзя.
const legacyServerMark = '/tmp/tsukiko-whisper';

/// По чему сервер узнаётся нашим. Второй признак — для серверов, поднятых
/// совсем старыми сборками, когда метки ещё не было: путь к нашей модели
/// тишины они передают почти всегда. У чужого whisper-server нет ни одного
/// из этих признаков, и трогать его нельзя.
List<String> get ourServerMarks => [serverMark, legacyServerMark, supportDir];

bool processAlive(int pid) => os.isAlive(pid);

/// Погасить наверняка. whisper-server на SIGTERM не умирает — проверено:
/// процесс жил часами с 1,7 ГБ, пока приложение считало его выгруженным.
/// Поэтому просим вежливо, ждём, проверяем и добиваем. Возвращает true,
/// если процесса больше нет.
///
/// Асинхронно: ждать приходится до 600 мс, а зовут это и по кнопке
/// «Выгрузить», и по таймеру простоя — то есть прямо из изолята, который
/// рисует панель. Синхронный `sleep` там просто морозил интерфейс.
Future<bool> killForSure(int pid) async {
  Future<bool> gone() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!processAlive(pid)) return true;
    }
    return false;
  }

  os.signal(pid);
  if (await gone()) return true;
  os.signal(pid, force: true);
  return gone();
}

/// Наши серверы среди перечисленных процессов. Чужие whisper-server
/// в список не попадают: наших меток у них нет.
List<ProcListing> ourServersIn(List<ProcListing> processes) => [
      for (final p in processes)
        if (p.args.contains('whisper-server') && ourServerMarks.any(p.args.contains)) p,
    ];

/// Pid, записанный нашим сервером. Просто число из файла: ни живости,
/// ни имени процесса не проверяет.
///
/// Ровно это и нужно тому, кто уже знает, что процесс жив. Опрос занятости
/// получает pid из `ps` и спрашивает лишь «он наш?» — а чтение файла в сотню
/// байт стоит несравнимо меньше, чем запуск ещё одного `ps` дважды в секунду
/// на изоляте, который рисует окно.
int? recordedServerPid() {
  try {
    return int.tryParse(_pidFile.readAsStringSync().trim());
  } catch (_) {
    return null;
  }
}

/// Pid нашего whisper-server, если он жив. Отличать своего от чужого можно
/// только так: у пользователя рядом может работать чужой whisper-server,
/// и по имени процесса они неразличимы. Один и тот же pid система могла
/// успеть отдать другому — поэтому сверяемся с именем процесса.
///
/// Дорого (запуск `ps`), поэтому только для уборки за собой. Для опроса
/// занятости есть [recordedServerPid].
int? ourServerPid() {
  final pid = recordedServerPid();
  if (pid == null) return null;
  return os.isAlive(pid) ? pid : null;
}

/// Подобрать за собой на старте: сервер, переживший прошлый запуск,
/// держит полтора гигабайта и никому уже не отвечает. Ищем по меткам,
/// а не по pid-файлу: файла может не быть вовсе — именно так утечка
/// и становилась невидимой.
///
/// Возвращает, сколько мегабайт вернули: молчаливая потеря такого
/// размера должна становиться видимой человеку.
Future<int> sweepOurServers({Set<int> keep = const {}}) async {
  var freedKb = 0;
  for (final s in ourServersIn(await os.listProcesses())) {
    if (s.pid == pid || keep.contains(s.pid)) continue;
    if (await killForSure(s.pid)) freedKb += s.rssKb;
  }
  // Запись стираем, только когда за ней никого не осталось: pid живого
  // процесса — единственный способ найти его потом.
  final left = ourServerPid();
  if (left == null || !processAlive(left)) {
    try {
      _pidFile.deleteSync();
    } catch (_) {}
  }
  return freedKb ~/ 1024;
}

/// Насколько старым должен быть временный мусор, чтобы считаться забытым.
/// Час: свои папки этого же запуска трогать нельзя, а очередь может
/// готовить звук в соседнем изоляте прямо сейчас.
const _staleAfter = Duration(hours: 1);

/// Подмести временное от прошлых запусков.
///
/// Два вида мусора. Записи диктовки (`tsukiko-*.wav`) ложатся в корень
/// временной папки и стираются сразу после распознавания. Очередь заводит
/// себе целую папку (`tsukikoXXXXXX/`) и держит в ней подготовленный звук —
/// час записи это больше сотни мегабайт, а удалялась она только в dispose,
/// мимо которого проходит ⌘Q. Пережившее падение и выход остаётся тут
/// навсегда, поэтому подметаем на старте.
/// [where] — только для проверок: функция удаляет файлы, и проверять её
/// на настоящей временной папке разработчика было бы невежливо.
void sweepRecordings({Directory? where}) {
  final now = DateTime.now();
  try {
    for (final f in (where ?? Directory.systemTemp).listSync()) {
      final name = os.basename(f.path);
      try {
        if (f is File && name.startsWith('tsukiko-') && name.endsWith('.wav')) {
          f.deleteSync();
        } else if (f is Directory && name.startsWith(appName)) {
          // По возрасту: папка этого запуска ещё нужна своему окну.
          if (now.difference(f.statSync().modified) > _staleAfter) {
            f.deleteSync(recursive: true);
          }
        }
      } catch (_) {
        // Чужая папка, права, гонка с соседом — не наше дело, идём дальше.
      }
    }
  } catch (_) {}
}

/// Запись, которую не удалось распознать, — единственный экземпляр
/// сказанного, и стирать её нельзя. Уносим из временной папки (её
/// подметает `sweepRecordings`) в библиотеку, откуда файл видно и можно
/// перетащить в очередь. Возвращает путь или null, если и это не вышло.
String? rescueRecording(String path) {
  try {
    final root =
        (Settings.load()['libraryPath'] as String?) ?? defaultLibraryPath;
    final dir = Directory(os.join(root, 'Не распознано'))
      ..createSync(recursive: true);
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final dest = os.join(
        dir.path,
        'Диктовка ${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}-${two(t.minute)}-${two(t.second)}.wav');
    File(path).copySync(dest);
    try {
      File(path).deleteSync();
    } catch (_) {}
    return dest;
  } catch (_) {
    return null;
  }
}

/// Whisper на тишине сочиняет: «(музыка)», «[BLANK_AUDIO]», «Субтитры
/// сделал…». Всё, что целиком в скобках, — не речь, а галлюцинация.
final _bracketed = RegExp(r'^[\[\(\*][^\]\)\*]*[\]\)\*]$');

/// Сервер отдаёт текст сегментами, разделёнными переводом строки. В поле
/// ввода это выглядит рваным — диктовка должна вставлять одну фразу.
String tidyDictated(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return _bracketed.hasMatch(text) ? '' : text;
}

/// Свободный порт: занимаем его на мгновение и сразу отпускаем. Между
/// «отпустили» и «занял сервер» есть теоретическая гонка, но выбирает
/// порты ядро, и повторно тот же оно не выдаёт.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Аргументы запуска whisper-server. Отдельно от `_start` затем, что
/// проверять их иначе нечем: сервер поднимается один раз и надолго.
List<String> serverArgs(RunOptions o, int port) => [
  '-m', o.model,
  '-l', o.lang,
  '-t', '${o.threads}',
  '--host', '127.0.0.1',
  '--port', '$port',
  // Метка своего процесса в аргументах: по ней сирота узнаётся, когда
  // pid-файла уже нет. Сервер читает её только вместе с --convert.
  '--tmp-dir', serverMark,
  // Речь в диктовке короткая, таймкоды в ней не нужны и только мешают
  // склеивать текст.
  '-nt',
  // Луч, а не жадный поиск. Это и была потеря на длинных записях:
  // whisper-cli по умолчанию идёт лучом (-bs 5 -bo 5), а whisper-server
  // — жадно (-bs -1 -bo 2), и на жадном декодере длинная речь срывается
  // в повторы и обрывы. Измерено на одной и той же модели и записях:
  // 6 с и 2 мин — без разницы, 4 мин — +18% текста, 5,5 мин — +25%,
  // 10,5 мин — +46%, 14,5 мин — +24%. Короткая фраза от этого не
  // медленнее (1,2 с и там, и там), а очередь и так идёт лучом.
  //
  // Только флагами запуска: стратегию сервер выбирает один раз, и те же
  // beam_size/best_of в самом запросе доходят лишь наполовину.
  '-bs', '5', '-bo', '5',
  // Тот же VAD, что и у очереди: он вырезает тишину до модели, а
  // значит и повод для галлюцинаций.
  if (o.vad && o.vadModel.isNotEmpty) ...['--vad', '-vm', o.vadModel],
  if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
];

class WhisperServer {
  WhisperServer({this.idleTimeout = const Duration(minutes: 3), this.onChanged});

  Duration idleTimeout;

  /// Дёргается, когда сервер поднялся или выгрузился, — панели нужно
  /// перерисовать состояние модели.
  void Function()? onChanged;

  Process? _proc;
  int _port = 0;
  String _model = '';
  Timer? _idle;
  DateTime? _deadline;
  Future<void>? _starting;

  /// Незакрытые аренды. Сервер поднимается в начале записи, а работы у него
  /// до конца фразы никакой — таймер простоя успевал догореть и выгружал
  /// модель посреди длинной записи, после чего распознавать было нечем.
  /// Пока аренда открыта, таймер не идёт вовсе.
  int _holds = 0;

  bool get up => _proc != null;
  bool get held => _holds > 0;
  int get port => _port;
  String get model => _model;

  /// Сколько осталось до выгрузки. null — сервер не поднят.
  Duration? get untilUnload {
    final d = _deadline;
    if (_proc == null || d == null) return null;
    final left = d.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Реальная память процесса. `ps -o rss` на macOS занижает всё, что
  /// пришло через mmap; Мониторинг системы показывает phys_footprint,
  /// и в интерфейсе должно стоять то же число.
  Future<int> footprintMb() async {
    final p = _proc;
    if (p == null) return 0;
    try {
      return await os.footprintMb(p.pid);
    } catch (_) {}
    return 0;
  }

  /// Поднять сервер под нужную модель. Возвращает сразу, если он уже
  /// поднят под неё же, — на этом и держится вся скорость.
  ///
  /// Подъёмы выстроены в очередь, а не схлопнуты в один: раньше здесь
  /// стояло `_starting ??= _start(o)`, и запрос под другую модель молча
  /// получал фьючер чужого подъёма — диктовка уходила говорить не в ту
  /// модель, которую у неё попросили.
  Future<void> ensureUp(RunOptions o) async {
    await _starting;
    if (_proc != null && _model == o.model) {
      _touch();
      return;
    }
    await (_starting = _start(o).whenComplete(() => _starting = null));
  }

  /// Дождаться идущего подъёма. Нужен тем, кто собирается говорить с
  /// сервером: между `shutdown()` внутри `_start` и присвоением `_proc`
  /// сервер выглядит выключенным, хотя он как раз поднимается.
  Future<void> get ready => _starting ?? Future<void>.value();

  Future<void> _start(RunOptions o) async {
    // Ждём, пока прежний действительно умрёт: два сервера разом — это
    // три гигабайта в памяти и драка за процессор.
    await shutdown();
    final exe = findWhisperServer();
    if (exe == null || o.model.isEmpty) return;

    _port = await freePort();
    _model = o.model;
    final proc = await Process.start(exe, serverArgs(o, _port));
    _proc = proc;
    // Вывод сервера никому не нужен, но не читать его нельзя: труба
    // заполнится, и процесс встанет.
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    proc.exitCode.then((_) {
      if (identical(_proc, proc)) {
        _proc = null;
        _deadline = null;
        onChanged?.call();
      }
    });
    try {
      _pidFile.parent.createSync(recursive: true);
      _pidFile.writeAsStringSync('${proc.pid}');
    } catch (_) {}
    _touch();
    onChanged?.call();
  }

  /// Порт открывается только после того, как модель прочитана целиком —
  /// проверено: 0,75 с на прогретом кеше, до 2 с на холодном. Поэтому
  /// «порт отвечает» и есть «модель готова».
  Future<bool> waitReady({Duration timeout = const Duration(seconds: 30)}) async {
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if (_proc == null) return false;
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _port,
            timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    return false;
  }

  /// Пустая строка — человек промолчал; null — распознать не удалось.
  /// Разница принципиальна: на молчание нечего показывать, а провал должен
  /// быть виден, иначе запись пропадает в тишине.
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async {
    // Сервер поднимается параллельно записи, и короткая фраза успевает
    // кончиться раньше, чем `Process.start` вернёт процесс. Без этого
    // ожидания такая фраза считалась нераспознанной, а запись уезжала
    // в «Не распознано» — при том что сервер поднялся через полсекунды.
    await ready;
    if (_proc == null) return null;
    if (!await waitReady()) return null;
    _touch();

    // Тело собирается из трёх частей, и звук в память не читается: час
    // диктовки — это больше сотни мегабайт, которые прежде ложились
    // в BytesBuilder, а затем копировались ещё раз в takeBytes. Длина
    // известна заранее, поэтому файл просто утекает в сокет с диска,
    // и расход памяти перестаёт зависеть от длины записи. Ограничивать
    // длительность ради этого не нужно — а именно так и подмывало сделать.
    const boundary = '----tsukiko-dictation';
    final head = BytesBuilder();
    void field(String name, String value) => head.add(utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
    field('response_format', 'json');
    field('language', lang);
    head.add(utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        'Content-Type: audio/wav\r\n\r\n'));
    final headBytes = head.takeBytes();
    final tailBytes = utf8.encode('\r\n--$boundary--\r\n');
    final file = File(wav);
    final int audioLength;
    try {
      audioLength = await file.length();
    } catch (_) {
      return null;
    }

    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', _port, '/inference');
      req.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary');
      // Без явной длины Dart перешёл бы на chunked, а сервер её ждёт.
      req.contentLength = headBytes.length + audioLength + tailBytes.length;
      req.add(headBytes);
      await req.addStream(file.openRead());
      req.add(tailBytes);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final data = jsonDecode(text);
      return tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
      _touch();
    }
  }

  /// Держать сервер живым безусловно. Освобождать обязательно — иначе
  /// модель останется в памяти навсегда.
  void hold() {
    _holds++;
    _touch();
  }

  void release() {
    if (_holds > 0) _holds--;
    _touch();
  }

  void _touch() {
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    if (_proc == null || _holds > 0) return;
    _deadline = DateTime.now().add(idleTimeout);
    _idle = Timer(idleTimeout, () => unawaited(shutdown()));
  }

  /// Выгрузить модель. `p.kill()` здесь недостаточно: он шлёт SIGTERM,
  /// а whisper-server от него не умирает — панель писала «Выгружена»,
  /// пока процесс держал полтора гигабайта. Убеждаемся, что он мёртв,
  /// и только тогда забываем о нём.
  ///
  /// Экран обновляется сразу, до ожидания: с точки зрения интерфейса
  /// сервера уже нет, а добивание идёт в фоне и панель не морозит.
  Future<void> shutdown() async {
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    final p = _proc;
    _proc = null;
    if (p == null) return;
    onChanged?.call();
    if (await killForSure(p.pid)) {
      try {
        _pidFile.deleteSync();
      } catch (_) {}
    }
  }
}

// ── хоткеи ──────────────────────────────────────────────────────────────────

/// Сочетание в том виде, в каком его понимают обе стороны моста.
/// Клавиши нет вовсе — значит сочетание из одних модификаторов (fn+ctrl):
/// такое приходит событием flagsChanged, а не нажатием клавиши.
class Hotkey {
  const Hotkey(this.mods, {this.key});

  /// 'fn', 'ctrl', 'opt', 'shift', 'cmd' — в этом же виде их читает Swift.
  final List<String> mods;
  final String? key;

  static const holdDefault = Hotkey(['fn', 'ctrl']);
  static const toggleDefault = Hotkey(['fn'], key: 'space');

  bool get empty => mods.isEmpty && key == null;

  Map<String, dynamic> toJson() => {'mods': mods, 'key': key};

  factory Hotkey.fromJson(Object? raw, Hotkey fallback) {
    if (raw is! Map) return fallback;
    final mods = (raw['mods'] as List?)?.map((e) => '$e').toList();
    if (mods == null) return fallback;
    return Hotkey(mods, key: raw['key'] as String?);
  }

  static const _keyNames = {
    'space': 'Пробел',
    'return': '⏎',
    'tab': '⇥',
    'escape': '⎋',
  };

  /// Подпись для панели: «fn ⌃», «fn Пробел». Значки модификаторов рисует
  /// система: на macOS это ⌘ и ⌥, на Windows — слова Ctrl и Alt.
  String get label {
    if (empty) return 'Не назначено';
    final name = key == null ? null : (_keyNames[key!] ?? key!.toUpperCase());
    return os.shortcutLabel(mods, name);
  }
}

/// Настройки диктовки лежат отдельно от общих: панель и главное окно —
/// разные изоляты, и одним файлом они затирали бы правки друг друга.
class DictationSettings {
  DictationSettings({
    this.enabled = true,
    this.model = '',
    this.prompt = '',
    this.hold = Hotkey.holdDefault,
    this.toggle = Hotkey.toggleDefault,
    this.idleSeconds = 180,
    this.insert = true,
    this.hud = true,
    this.punctuate = true,
    this.threads = 4,
  });

  bool enabled;

  /// Пусто — берём модель из общих настроек приложения.
  String model;

  /// Подсказка модели своя: диктуют не то же, что расшифровывают.
  String prompt;
  Hotkey hold, toggle;
  int idleSeconds;

  /// Вставлять готовый текст в активное окно. Выключено — текст только
  /// ложится в буфер обмена.
  bool insert;

  /// Плавающая панель записи поверх всех окон.
  bool hud;

  /// Дальше — своё распознавание, не общее с очередью: диктуют не то же,
  /// что расшифровывают, и общие значения устраивали бы разом обе стороны
  /// плохо. Языка здесь нет: диктовке он всегда «авто».
  bool punctuate;
  int threads;

  static File get _file => File(os.join(supportDir, 'dictation.json'));

  static DictationSettings load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return DictationSettings(
        enabled: (j['enabled'] as bool?) ?? true,
        model: (j['model'] as String?) ?? '',
        prompt: (j['prompt'] as String?) ?? '',
        hold: Hotkey.fromJson(j['hold'], Hotkey.holdDefault),
        toggle: Hotkey.fromJson(j['toggle'], Hotkey.toggleDefault),
        idleSeconds: (j['idleSeconds'] as int?) ?? 180,
        insert: (j['insert'] as bool?) ?? true,
        hud: (j['hud'] as bool?) ?? true,
        punctuate: (j['punctuate'] as bool?) ?? true,
        threads: (j['threads'] as int?) ?? 4,
      );
    } catch (_) {
      return DictationSettings();
    }
  }

  void save() {
    try {
      Directory(supportDir).createSync(recursive: true);
      // Через временный файл и переименование — как и общие настройки:
      // падение посреди записи не должно стирать сочетания клавиш.
      writeJsonAtomically(_file, {
        'enabled': enabled,
        'model': model,
        'prompt': prompt,
        'hold': hold.toJson(),
        'toggle': toggle.toJson(),
        'idleSeconds': idleSeconds,
        'insert': insert,
        'hud': hud,
        'punctuate': punctuate,
        'threads': threads,
      });
    } catch (e) {
      stderr.writeln('tsukiko: не удалось сохранить настройки диктовки — $e');
    }
  }
}

/// Пара «быстрая · точная» из того, что нашлось на диске: маленькая модель
/// и большая. Одна модель на всю систему — обе половинки указывают на неё,
/// и переключатель нечего переключать.
({String fast, String accurate}) modelPair(List<String> models) {
  final files = models.where((p) => File(p).existsSync()).toList()
    ..sort((a, b) => File(a).lengthSync().compareTo(File(b).lengthSync()));
  if (files.isEmpty) return (fast: '', accurate: '');
  return (fast: files.first, accurate: files.last);
}

String modelSizeLabel(String path) {
  try {
    final gb = File(path).lengthSync() / (1024 * 1024 * 1024);
    return gb >= 1
        ? '${gb.toStringAsFixed(1).replaceAll('.', ',')} ГБ'
        : '${(gb * 1024).round()} МБ';
  } catch (_) {
    return '';
  }
}
