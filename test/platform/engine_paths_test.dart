import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/library.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/platform/os_windows.dart';

/// Пути, которые уходят чужой программе доводом командной строки.
///
/// Из-за этого движок у хозяина и не поднимался: имя пользователя «Роман»,
/// модель лежала в `C:\Users\Роман\…`, а `whisper-cli` — программа на C,
/// и её рантайм переводит `argv` в однобайтовую кодировку системы. Буквы
/// терялись до первой строчки кода движка, дальше `fopen` по испорченному
/// пути и «failed to open». Лечится короткими именами Windows, и вся
/// защита от возврата к прежнему — здесь.
void main() {
  group('пути для чужой программы идут через границу системы', () {
    late Os real;

    setUp(() {
      real = os;
      os = _MarkingOs(real);
    });
    tearDown(() => os = real);

    test('buildArgs не отдаёт движку ни одного сырого пути', () {
      const o = RunOptions(
        model: r'C:\Users\Роман\models\ggml.bin',
        lang: 'ru',
        threads: 4,
        vad: true,
        vadModel: r'C:\Users\Роман\models\vad.bin',
      );
      final args = buildArgs(o, r'C:\Users\Роман\tmp\1.wav', r'C:\Users\Роман\tmp\1');

      expect(args[args.indexOf('-m') + 1], '<${o.model}>');
      expect(args[args.indexOf('-of') + 1], r'<C:\Users\Роман\tmp\1>');
      expect(args[args.indexOf('-vm') + 1], '<${o.vadModel}>');
      expect(args.last, r'<C:\Users\Роман\tmp\1.wav>',
          reason: 'сам звук идёт последним доводом и тоже должен быть преобразован');
      // И ни одного пути мимо преобразования.
      expect(args.where((a) => a.contains(r'\') && !a.startsWith('<')), isEmpty);
    });

    test('buildNemoArgs тоже преобразует все пути', () {
      const o = RunOptions(
        model: r'C:\Users\Роман\models\nemotron.gguf',
        lang: 'ru',
        threads: 4,
      );
      final args = buildNemoArgs(
        o,
        r'C:\Users\Роман\tmp\1.wav',
        r'C:\Users\Роман\tmp\1.json',
      );
      expect(args[1], r'<C:\Users\Роман\tmp\1.wav>');
      expect(args[args.indexOf('--model') + 1], '<${o.model}>');
      expect(
        args[args.indexOf('--output') + 1],
        r'<C:\Users\Роман\tmp\1.json>',
      );
      expect(args.where((a) => a.contains(r'\') && !a.startsWith('<')), isEmpty);
    });

    test('serverArgs преобразует модель, но не метку своего процесса', () {
      const o = RunOptions(
        model: r'C:\Users\Роман\models\ggml.bin',
        lang: 'ru',
        threads: 4,
        vad: true,
        vadModel: r'C:\Users\Роман\models\vad.bin',
      );
      final args = serverArgs(o, 1234);
      expect(args[args.indexOf('-m') + 1], '<${o.model}>');
      expect(args[args.indexOf('-vm') + 1], '<${o.vadModel}>');
      // Метка — не путь: сервер по ней ничего не открывает, зато мы ищем
      // её потом в командной строке процесса. Сократи мы её здесь —
      // забытый сервер с полутора гигабайтами больше не нашёлся бы.
      expect(args[args.indexOf('--tmp-dir') + 1], serverMark);
    });
  });

  test('путь без коротких имён виден заранее', () {
    final real = os;
    os = _StuckOs(real);
    addTearDown(() => os = real);
    expect(pathBeyondEngine(r'C:\Users\Роман\models\ggml.bin'), isTrue);
    expect(pathBeyondEngine(r'C:\Users\ROMAN~1\models\ggml.bin'), isFalse);
    expect(pathBeyondEngine(''), isFalse);
  });

  test('короткое имя Windows и правда из латиницы', () {
    // Проверка самого преобразования — она имеет смысл только на Windows:
    // на macOS processPath ничего не делает и делать не должен.
    if (!Platform.isWindows) return;
    final dir = Directory.systemTemp.createTempSync('tsukiko-Роман');
    try {
      final file = File(os.join(dir.path, 'модель.bin'))..writeAsStringSync('');
      final short = WindowsOs().processPath(file.path);
      expect(short.codeUnits.every((c) => c < 128), isTrue,
          reason: 'короткие имена 8.3 на этом томе выключены — '
              'см. fsutil 8dot3name query');
      expect(File(short).existsSync(), isTrue,
          reason: 'сокращённый путь обязан вести к тому же файлу');
      // Файла ещё нет — короткого имени у него тоже нет, и взяться ему
      // неоткуда. Сокращается папка, а имя дописывается как было: этим
      // путём уходит движку основа имени для `-of`, и своё имя мы туда
      // пишем сами, латиницей (в очереди это порядковый номер, см.
      // queue_bloc). Значит проверять надо папку — что от неё
      // не осталось ни одной кириллической буквы, — а не пропажу имени.
      final future = os.join(dir.path, '7');
      final shortFuture = WindowsOs().processPath(future);
      expect(shortFuture.codeUnits.every((c) => c < 128), isTrue,
          reason: 'папку у несуществующего файла всё равно надо сокращать');
      expect(shortFuture.endsWith(r'\7'), isTrue,
          reason: 'имя остаётся нашим: сокращается только папка');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

/// Помечает всякий путь, прошедший через границу системы. Что не помечено —
/// то ушло бы движку сырым.
class _MarkingOs implements Os {
  _MarkingOs(this._real);
  final Os _real;

  @override
  String processPath(String path) => '<$path>';

  @override
  String join(String a, [String? b, String? c]) => _real.join(a, b, c);

  @override
  String get supportDir => _real.supportDir;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('тесту это не нужно: ${invocation.memberName}');
}

/// Система, где короткие имена выключены: путь возвращается как есть.
class _StuckOs implements Os {
  _StuckOs(this._real);
  final Os _real;

  @override
  String processPath(String path) => path;

  @override
  String join(String a, [String? b, String? c]) => _real.join(a, b, c);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('тесту это не нужно: ${invocation.memberName}');
}
