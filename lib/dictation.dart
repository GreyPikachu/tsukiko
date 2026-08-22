import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'engine.dart';

/// Фоновая диктовка: долгоживущий whisper-server, который держит модель
/// в памяти между фразами, и состояние самой диктовки.
///
/// Ядро замысла — время. Холодный whisper-cli тратит на короткую фразу
/// секунды: почти всё уходит на чтение модели с диска. Сервер читает её
/// один раз, поэтому распознавание фразы занимает около полусекунды.
/// Сервер поднимается в тот момент, когда пользователь начал говорить,
/// и успевает загрузиться, пока фраза не кончилась.

const whisperServerCandidates = [
  '/opt/homebrew/bin/whisper-server',
  '/usr/local/bin/whisper-server',
];

String? findWhisperServer() {
  for (final p in whisperServerCandidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Модель весит гигабайты, поэтому осиротевший сервер — это не «лишний
/// процесс», а полтора гигабайта, которые никто не вернёт. Pid пишется
/// на диск, и следующий запуск добивает того, кто пережил падение.
File get _pidFile => File('$supportDir/whisper-server.pid');

/// Метка своего сервера в аргументах процесса. Нужна затем, что pid-файл
/// теряется: приложение падает, его убивают сигналом, файл стирают — и
/// сервер с полутора гигабайтами становится невидимым навсегда.
/// Аргументы процесса не теряются никогда, поэтому метка живёт в них.
///
/// `--tmp-dir` сервер читает только вместе с `--convert`, которого мы
/// не просим: на поведение метка не влияет, а в `ps` она видна.
const serverMark = '/tmp/tsukiko-whisper';

/// По чему сервер узнаётся нашим. Второй признак — для серверов, поднятых
/// прежними сборками, когда метки ещё не было: путь к нашей модели тишины
/// они передают почти всегда. У чужого whisper-server нет ни того, ни
/// другого, и трогать его нельзя.
List<String> get _ourMarks => [serverMark, supportDir];

bool processAlive(int pid) {
  try {
    final r = Process.runSync('ps', ['-o', 'pid=', '-p', '$pid']);
    return (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Погасить наверняка. whisper-server на SIGTERM не умирает — проверено:
/// процесс жил часами с 1,7 ГБ, пока приложение считало его выгруженным.
/// Поэтому просим вежливо, ждём, проверяем и добиваем. Возвращает true,
/// если процесса больше нет.
///
/// Синхронно: её зовут и на выходе из приложения, где ждать уже некому.
bool killForSure(int pid) {
  bool gone() {
    for (var i = 0; i < 6; i++) {
      sleep(const Duration(milliseconds: 50));
      if (!processAlive(pid)) return true;
    }
    return false;
  }

  try {
    Process.killPid(pid, ProcessSignal.sigterm);
  } catch (_) {
    return !processAlive(pid);
  }
  if (gone()) return true;
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } catch (_) {}
  return gone();
}

/// Наши серверы в выводе `ps -axo pid=,rss=,args=`. Чужие whisper-server
/// в список не попадают: наших меток у них нет.
List<({int pid, int rssKb})> ourServersIn(String psOutput) {
  final out = <({int pid, int rssKb})>[];
  for (final line in psOutput.split('\n')) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final args = m.group(3)!;
    if (!args.contains('whisper-server')) continue;
    if (!_ourMarks.any(args.contains)) continue;
    out.add((pid: int.parse(m.group(1)!), rssKb: int.parse(m.group(2)!)));
  }
  return out;
}

/// Pid нашего whisper-server, если он жив. Отличать своего от чужого можно
/// только так: у пользователя рядом может работать чужой whisper-server,
/// и по имени процесса они неразличимы. Один и тот же pid система могла
/// успеть отдать другому — поэтому сверяемся с именем процесса.
int? ourServerPid() {
  try {
    final pid = int.tryParse(_pidFile.readAsStringSync().trim());
    if (pid == null) return null;
    final comm = Process.runSync('ps', ['-o', 'comm=', '-p', '$pid']);
    return (comm.stdout as String).contains('whisper-server') ? pid : null;
  } catch (_) {
    return null;
  }
}

/// Подобрать за собой на старте: сервер, переживший прошлый запуск,
/// держит полтора гигабайта и никому уже не отвечает. Ищем по меткам,
/// а не по pid-файлу: файла может не быть вовсе — именно так утечка
/// и становилась невидимой.
///
/// Возвращает, сколько мегабайт вернули: молчаливая потеря такого
/// размера должна становиться видимой человеку.
int sweepOurServers({Set<int> keep = const {}}) {
  var freedKb = 0;
  try {
    final ps = Process.runSync('ps', ['-axo', 'pid=,rss=,args=']);
    for (final s in ourServersIn(ps.stdout as String)) {
      if (s.pid == pid || keep.contains(s.pid)) continue;
      if (killForSure(s.pid)) freedKb += s.rssKb;
    }
  } catch (_) {}
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

/// Запись диктовки ложится во временную папку и стирается сразу после
/// распознавания. Пережившие падение остаются — подметаем их на старте,
/// иначе за месяц там наберётся сотня забытых WAV.
void sweepRecordings() {
  try {
    for (final f in Directory(Directory.systemTemp.path).listSync()) {
      final name = f.path.split('/').last;
      if (f is File && name.startsWith('tsukiko-') && name.endsWith('.wav')) {
        f.deleteSync();
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
    final dir = Directory('$root/Не распознано')..createSync(recursive: true);
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final dest = '${dir.path}/Диктовка ${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}-${two(t.minute)}-${two(t.second)}.wav';
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
      final r = await Process.run('footprint', ['-p', '${p.pid}']);
      final m = RegExp(r'phys_footprint:\s*(\d+)\s*MB').firstMatch(r.stdout as String);
      if (m != null) return int.parse(m.group(1)!);
    } catch (_) {}
    return 0;
  }

  /// Поднять сервер под нужную модель. Возвращает сразу, если он уже
  /// поднят под неё же, — на этом и держится вся скорость.
  Future<void> ensureUp(RunOptions o) {
    if (_proc != null && _model == o.model) {
      _touch();
      return Future.value();
    }
    return _starting ??= _start(o).whenComplete(() => _starting = null);
  }

  Future<void> _start(RunOptions o) async {
    shutdown();
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
    if (_proc == null) return null;
    if (!await waitReady()) return null;
    _touch();

    const boundary = '----tsukiko-dictation';
    final body = BytesBuilder();
    void field(String name, String value) => body.add(utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
    field('response_format', 'json');
    field('language', lang);
    body.add(utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        'Content-Type: audio/wav\r\n\r\n'));
    body.add(await File(wav).readAsBytes());
    body.add(utf8.encode('\r\n--$boundary--\r\n'));

    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', _port, '/inference');
      req.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary');
      req.add(body.takeBytes());
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
    _idle = Timer(idleTimeout, shutdown);
  }

  /// Выгрузить модель. `p.kill()` здесь недостаточно: он шлёт SIGTERM,
  /// а whisper-server от него не умирает — панель писала «Выгружена»,
  /// пока процесс держал полтора гигабайта. Убеждаемся, что он мёртв,
  /// и только тогда забываем о нём.
  void shutdown() {
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    final p = _proc;
    _proc = null;
    if (p == null) return;
    if (killForSure(p.pid)) {
      try {
        _pidFile.deleteSync();
      } catch (_) {}
    }
    onChanged?.call();
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

  static const _modSymbols = {
    'fn': 'fn',
    'ctrl': '⌃',
    'opt': '⌥',
    'shift': '⇧',
    'cmd': '⌘',
  };

  static const _keyNames = {
    'space': 'Пробел',
    'return': '⏎',
    'tab': '⇥',
    'escape': '⎋',
  };

  /// Подпись для панели: «fn + ⌃», «fn + Пробел».
  String get label {
    if (empty) return 'Не назначено';
    final parts = [
      for (final m in mods) _modSymbols[m] ?? m,
      if (key != null) _keyNames[key!] ?? key!.toUpperCase(),
    ];
    return parts.join(' + ');
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

  static File get _file => File('$supportDir/dictation.json');

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
      _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
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
      }));
    } catch (_) {}
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
