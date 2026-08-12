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

/// Один и тот же процесс мог перезапуститься, а pid — достаться другому.
/// Убиваем только если по этому pid действительно whisper-server.
void killStaleServer() {
  try {
    final raw = _pidFile.readAsStringSync().trim();
    final pid = int.tryParse(raw);
    if (pid == null) return;
    final comm = Process.runSync('ps', ['-o', 'comm=', '-p', '$pid']);
    if ((comm.stdout as String).contains('whisper-server')) {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
  } catch (_) {
  } finally {
    try {
      _pidFile.deleteSync();
    } catch (_) {}
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

  bool get up => _proc != null;
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
    final proc = await Process.start(exe, [
      '-m', o.model,
      '-l', o.lang,
      '-t', '${o.threads}',
      '--host', '127.0.0.1',
      '--port', '$_port',
      // Речь в диктовке короткая, таймкоды в ней не нужны и только мешают
      // склеивать текст.
      '-nt',
      // Тот же VAD, что и у очереди: он вырезает тишину до модели, а
      // значит и повод для галлюцинаций.
      if (o.vad && o.vadModel.isNotEmpty) ...['--vad', '-vm', o.vadModel],
      if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
    ]);
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

  Future<String> transcribe(String wav, {String lang = 'auto'}) async {
    if (_proc == null) return '';
    if (!await waitReady()) return '';
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
      if (res.statusCode != 200) return '';
      final data = jsonDecode(text);
      return tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
      _touch();
    }
  }

  void _touch() {
    _idle?.cancel();
    _deadline = DateTime.now().add(idleTimeout);
    _idle = Timer(idleTimeout, shutdown);
  }

  void shutdown() {
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill();
      try {
        _pidFile.deleteSync();
      } catch (_) {}
      onChanged?.call();
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
    this.lang = 'ru',
    this.model = '',
    this.hold = Hotkey.holdDefault,
    this.toggle = Hotkey.toggleDefault,
    this.idleSeconds = 180,
  });

  bool enabled;
  String lang;

  /// Пусто — берём модель из общих настроек приложения.
  String model;
  Hotkey hold, toggle;
  int idleSeconds;

  static File get _file => File('$supportDir/dictation.json');

  static DictationSettings load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return DictationSettings(
        enabled: (j['enabled'] as bool?) ?? true,
        lang: (j['lang'] as String?) ?? 'ru',
        model: (j['model'] as String?) ?? '',
        hold: Hotkey.fromJson(j['hold'], Hotkey.holdDefault),
        toggle: Hotkey.fromJson(j['toggle'], Hotkey.toggleDefault),
        idleSeconds: (j['idleSeconds'] as int?) ?? 180,
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
        'lang': lang,
        'model': model,
        'hold': hold.toJson(),
        'toggle': toggle.toJson(),
        'idleSeconds': idleSeconds,
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
