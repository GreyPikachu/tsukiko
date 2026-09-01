import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/core/library.dart';
import 'package:tsukiko/core/models.dart';
import 'package:tsukiko/core/text.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/platform/os.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding подменяет HttpOverrides и заворачивает
  // любой HttpClient в фальшивый 400 — а этот файл настоящую сеть
  // и проверяет (Download, whisper-server). Возвращаем обычные сокеты.
  HttpOverrides.global = null;
  // Строки идут через currentL10n(), который читает системный локаль.
  // Тестовый движок отдаёт en_US — здесь же тексты сверены с русским,
  // поэтому закрепляем его явно.
  setUp(() =>
      binding.platformDispatcher.localesTestValue = const [Locale('ru')]);

  _hotkeyTaps();

  test('таймкоды', () {
    expect(fmtTs(0), '00:00:00.000');
    expect(fmtTs(3723456), '01:02:03.456');
    expect(fmtTs(3723456, msSep: ','), '01:02:03,456');
  });

  test('рендер текста и субтитров', () {
    const segs = [Segment(0, 1500, 'раз'), Segment(1500, 3000, 'два')];
    expect(renderPlain(segs, false), 'раз\nдва');
    expect(renderPlain(segs, true).startsWith('[00:00:00.000 → 00:00:01.500]  раз'), isTrue);
    expect(renderSrt(segs).split('\n')[1], '00:00:00,000 --> 00:00:01,500');
    expect(renderMarkdown('x.ogg', const Transcript('ru', segs)).contains('раз'), isTrue);
  });

  test('аргументы whisper-cli', () {
    final args = buildArgs(
      const RunOptions(model: '/m.bin', lang: 'ru', threads: 6, maxLen: 42),
      '/a.wav',
      '/out',
    );
    expect(args.take(6).toList(), ['-m', '/m.bin', '-l', 'ru', '-t', '6']);
    expect(args.contains('-oj'), isTrue);
    expect(args.contains('-ml'), isTrue);
    expect(args.last, '/a.wav');
    // VAD не подключается без файла модели
    expect(
      buildArgs(const RunOptions(model: 'm', lang: 'auto', threads: 4, vad: true),
              '/a.wav', '/o')
          .contains('--vad'),
      isFalse,
    );
  });

  test('затравка на пунктуацию', () {
    // по умолчанию — подсказка на языке записи
    const ru = RunOptions(model: 'm', lang: 'ru', threads: 4);
    expect(buildArgs(ru, '/a.wav', '/o').contains('--prompt'), isTrue);
    expect(ru.effectivePrompt, contains('правилам русского языка'));
    // Затравка не должна наводить модель на диалог и на субтитры: оттуда
    // приходили и тире в начале реплики, и «Продолжение следует…».
    expect(ru.effectivePrompt, isNot(contains('тире')));
    expect(ru.effectivePrompt.toLowerCase(), isNot(contains('расшифровк')));
    expect(ru.effectivePrompt.toLowerCase(), isNot(contains('субтитр')));
    expect(
      const RunOptions(model: 'm', lang: 'en', threads: 4).effectivePrompt,
      contains('punctuation'),
    );
    expect(
      const RunOptions(model: 'm', lang: 'en', threads: 4).effectivePrompt,
      isNot(contains('dashes')),
    );
    // своя подсказка важнее затравки
    expect(
      const RunOptions(model: 'm', lang: 'ru', threads: 4, prompt: 'Минина, Сытый двор')
          .effectivePrompt,
      'Минина, Сытый двор',
    );
    // выключено — подсказки нет вовсе
    expect(
      buildArgs(const RunOptions(model: 'm', lang: 'ru', threads: 4, punctuate: false),
              '/a.wav', '/o')
          .contains('--prompt'),
      isFalse,
    );
  });

  test('живой разбор строк whisper-cli', () {
    final s = parseSegmentLine('[00:00:01.500 --> 00:00:24.720]   Ну давайце, вось. ');
    expect(s, isNotNull);
    expect(s!.from, 1500);
    expect(s.to, 24720);
    expect(s.text, 'Ну давайце, вось.');
    // прогресс и служебные строки сегментами не считаются
    expect(parseSegmentLine('whisper_print_progress_callback: progress =  40%'), isNull);
    expect(parseSegmentLine('[00:00:00.000 --> 00:00:02.000]   '), isNull);
  });

  test('разбор json от whisper', () {
    final json = jsonEncode({
      'result': {'language': 'be'},
      'transcription': [
        {
          'offsets': {'from': 0, 'to': 900},
          'text': ' прывітанне ',
        }
      ],
    });
    final t = parseWhisperJson(json);
    expect(t.lang, 'be');
    expect(t.segments.single.text, 'прывітанне');
    expect(t.segments.single.to, 900);
  });

  test('форматы экспорта различимы и не зависят от настроек вида', () {
    const t = Transcript('ru', [Segment(0, 1500, 'раз'), Segment(1500, 3000, 'два')]);

    // чистый текст — без единой цифры таймкода
    final plain = renderAs(formatPlainText, t);
    expect(plain, 'раз\nдва');
    expect(plain.contains('00:00'), isFalse);

    // текст с таймкодами — тот же текст, но с метками
    expect(renderAs(formatTimedText, t), contains('[00:00:00.000'));
    expect(renderAs(formatTimedText, t), contains('раз'));

    // у каждого формата своё окончание имени файла
    expect(formatPlainText.fileName('Запись'), 'Запись.txt');
    expect(formatTimedText.fileName('Запись'), 'Запись (таймкоды).txt');
    expect(formatSrt.fileName('Запись'), 'Запись.srt');
    expect(exportFormats.map((f) => f.fileName('x')).toSet().length,
        exportFormats.length);

    expect(renderAs(formatVtt, t).startsWith('WEBVTT'), isTrue);
    expect(renderAs(formatJson, t), contains('"language": "ru"'));
    expect(renderAs(formatMarkdown, t, name: 'Запись.ogg'), contains('# Запись.ogg'));
    expect(formatById('txt-ts').label, 'Текст с таймкодами');
  });

  test('раскладка библиотеки: месяц, папка записи, номера при совпадении', () {
    final root = Directory.systemTemp.createTempSync('tsukiko_lib').path;
    final when = DateTime(2026, 8, 2);
    expect(monthFolder(when), '2026-08');

    // один формат — файл прямо в папке месяца
    final one = planPlacement(root: root, stem: 'Запись', formatCount: 1, now: when);
    expect(one.dir, '$root/2026-08');
    expect(one.pathFor('.txt'), '$root/2026-08/Запись.txt');

    // имя занято — добавляем номер, старое не трогаем
    Directory(one.dir).createSync(recursive: true);
    File('${one.dir}/Запись.txt').writeAsStringSync('старое');
    expect(freeStem(one.dir, 'Запись', '.txt'), 'Запись 2');
    expect(File('${one.dir}/Запись.txt').readAsStringSync(), 'старое');

    // форматов несколько — у записи своя папка
    final many = planPlacement(root: root, stem: 'Запись', formatCount: 3, now: when);
    expect(many.dir, '$root/2026-08/Запись');
    expect(many.pathFor('.srt'), '$root/2026-08/Запись/Запись.srt');

    // и папка нумеруется, если такая уже есть
    Directory(many.dir).createSync(recursive: true);
    expect(
      planPlacement(root: root, stem: 'Запись', formatCount: 3, now: when).dir,
      '$root/2026-08/Запись 2',
    );

    Directory(root).deleteSync(recursive: true);
  });

  test('папка по умолчанию — в Документах, строчными', () {
    expect(appName, 'tsukiko');
    expect(defaultLibraryPath.endsWith('/Documents/tsukiko'), isTrue);
  });








  test('числительные согласуются с числом', () {
    expect(segmentsLabel(1), '1 фрагмент');
    expect(segmentsLabel(3), '3 фрагмента');
    expect(segmentsLabel(5), '5 фрагментов');
    expect(segmentsLabel(11), '11 фрагментов');
    expect(segmentsLabel(21), '21 фрагмент');
    expect(segmentsLabel(112), '112 фрагментов');
    expect(recordsLabel(2), '2 записи');
    expect(wordsLabel(1), '1 слово');
    expect(wordCount('  раз  два   три '), 3);
    expect(wordCount(''), 0);
  });

  test('длительность без лишних нулей', () {
    expect(humanDuration(7000), '0:07');
    expect(humanDuration(247000), '4:07');
    expect(humanDuration(3723000), '1:02:03');
  });

  test('языки называются словами, а не кодами', () {
    expect(languageName('be'), 'Беларуская');
    expect(languageName('auto'), 'Определять автоматически');
    // неизвестный код не должен ронять интерфейс
    expect(languageName('xx'), 'XX');
  });

  test('свои настройки записи: копия, отличия, обратная совместимость', () {
    const base = RunOptions(model: '/a.bin', lang: 'auto', threads: 4);
    final own = base.copyWith(lang: 'be', maxLen: 42);

    expect(own.model, base.model);
    expect(own.diffAgainst(base), ['язык', 'длина фрагмента']);
    expect(base.diffAgainst(base), isEmpty);

    // круг через JSON ничего не теряет
    final back = RunOptions.fromJson(own.toJson(), base);
    expect(back.diffAgainst(own), isEmpty);

    // в старом файле настроек новых ключей нет — берём из общих
    expect(RunOptions.fromJson({'lang': 'ru'}, base).threads, 4);
  });

  test('открытие субтитров превращает их в обычную расшифровку', () {
    const srt = '1\n'
        '00:00:00,000 --> 00:00:01,500\n'
        'раз\n'
        '\n'
        '2\n'
        '00:00:01,500 --> 00:00:03,000\n'
        'два\n'
        'два с половиной\n';
    final t = parseSubtitles(srt)!;
    expect(t.segments.length, 2);
    expect(t.segments.first.text, 'раз');
    expect(t.segments.first.to, 1500);
    expect(t.segments.last.text, 'два два с половиной');

    // VTT и наш собственный «текст с таймкодами» — тем же разбором
    expect(parseSubtitles(renderVtt(t.segments))!.segments.length, 2);
    final timed = parseSubtitles(renderPlain(t.segments, true))!;
    expect(timed.segments.map((s) => s.text).toList(), ['раз', 'два два с половиной']);
    expect(timed.segments.first.from, 0);

    // и, значит, открытые субтитры можно пересохранить в другой формат
    expect(renderAs(formatPlainText, timed), 'раз\nдва два с половиной');

    // обычный текст субтитрами не притворяется
    expect(parseSubtitles('просто текст\nбез таймкодов'), isNull);
  });

  test('afconvert делает wav из системного звука', () async {
    final out = '${Directory.systemTemp.path}/tsukiko_test.wav';
    final res = await os.toWav('/System/Library/Sounds/Ping.aiff', out);
    expect(res, out);
    expect(File(out).lengthSync() > 1000, isTrue);
    File(out).deleteSync();
  });

  // ── диктовка ──────────────────────────────────────────────────────────────

  test('расшифровку фразы склеиваем в строку, а галлюцинации отбрасываем', () {
    // сервер отдаёт текст сегментами, в поле ввода это должно попасть одной фразой
    expect(tidyDictated(' раз\n два  три \n'), 'раз два три');
    expect(tidyDictated(''), '');
    // на тишине whisper сочиняет — всё, что целиком в скобках, не речь
    expect(tidyDictated(' [BLANK_AUDIO] '), '');
    expect(tidyDictated('(музыка)'), '');
    expect(tidyDictated('*звук двигателя*'), '');
    // а скобки внутри фразы — обычный текст
    expect(tidyDictated('привет (кажется)'), 'привет (кажется)');

    // Выдумки на тишине выбрасываются целиком: сказано этого не было.
    expect(tidyDictated('Продолжение следует...'), '');
    expect(tidyDictated('Спасибо за просмотр!'), '');
    expect(tidyDictated('  субтитры сделал DimaTorzok '), '');
    // Но только когда совпал весь кусок: сказанное всерьёз остаётся.
    expect(
      tidyDictated('здесь продолжение следует из предыдущего'),
      'здесь продолжение следует из предыдущего',
    );

    // Ведущее тире модель ставит, приняв надиктованное за прямую речь.
    expect(tidyDictated('— привет'), 'привет');
    expect(tidyDictated('-- ну вот'), 'ну вот');
    // А тире внутри фразы — обычный знак.
    expect(tidyDictated('привет — это я'), 'привет — это я');
  });

  test('подписи сочетаний читаются как в системе', () {
    expect(Hotkey.holdDefault.label, 'fn + ⌃');
    expect(Hotkey.toggleDefault.label, 'fn + Пробел');
    expect(const Hotkey([], keys: ['f13']).label, 'F13');
    expect(const Hotkey([]).label, 'Не назначено');

    // Годится любая клавиша и любое их число: раньше обычную букву
    // в одиночку назначить было нельзя вовсе.
    expect(const Hotkey([], keys: ['y']).label, 'Y');
    expect(const Hotkey([], keys: ['x', 'y']).label, 'X + Y');
    expect(const Hotkey(['fn'], keys: ['o']).label, 'fn + O');
    // Порядок клавиш не зависит от того, в каком их нажали.
    expect(const Hotkey([], keys: ['y', 'x']).label,
        const Hotkey([], keys: ['x', 'y']).label);
    // Незнакомую клавишу называем её кодом — назначить можно любую.
    expect(const Hotkey([], keys: ['#57']).label, '#57');
    // круг через JSON ничего не теряет
    final back = Hotkey.fromJson(Hotkey.toggleDefault.toJson(), Hotkey.holdDefault);
    expect(back.label, Hotkey.toggleDefault.label);
    // мусор в файле настроек не должен ронять диктовку
    expect(Hotkey.fromJson('чепуха', Hotkey.holdDefault).label, 'fn + ⌃');
    // настройки прежних сборок: там клавиша была одна
    expect(
      Hotkey.fromJson({'mods': ['fn'], 'key': 'space'}, Hotkey.holdDefault).keys,
      ['space'],
    );
  });

  test('быстрая и точная модели выбираются по весу файла', () {
    final dir = Directory.systemTemp.createTempSync('tsukiko_models');
    File('${dir.path}/ggml-small.bin').writeAsBytesSync(List.filled(2048, 0));
    File('${dir.path}/ggml-large.bin').writeAsBytesSync(List.filled(9000, 0));
    final pair = modelPair([
      '${dir.path}/ggml-large.bin',
      '${dir.path}/ggml-small.bin',
      '/нет/такой.bin',
    ]);
    expect(pair.fast.endsWith('small.bin'), isTrue);
    expect(pair.accurate.endsWith('large.bin'), isTrue);
    // одна модель на всю систему — обе половинки указывают на неё
    final one = modelPair(['${dir.path}/ggml-large.bin']);
    expect(one.fast, one.accurate);
    expect(modelPair(const []).fast, '');
    dir.deleteSync(recursive: true);
  });

  test('VAD-модель качается из своего репозитория и не путается с речевой', () {
    // В ggerganov/whisper.cpp файла silero нет вовсе — оттуда приходит 404.
    expect(vadModelUrl, contains('ggml-org/whisper-vad'));
    expect(vadModelUrl.endsWith(vadModelFile), isTrue);
    // Ложится туда же, куда смотрит findModels(), — иначе её нечем подхватить.
    expect(vadModelPath, '$supportDir/models/$vadModelFile');
    // Но в списке моделей распознавания ей не место: выбрав её, человек
    // получил бы пустую расшифровку.
    expect(looksLikeSpeechModel(vadModelFile), isFalse);
    expect(looksLikeSpeechModel('ggml-large-v3-turbo.bin'), isTrue);
    expect(looksLikeSpeechModel('ggml-tiny.bin.part'), isFalse);
    expect(looksLikeSpeechModel('заметки.txt'), isFalse);
  });

  test('каталог моделей: ссылки в один репозиторий, файлы в свою папку', () {
    expect(modelCatalog.length, 6);
    for (final m in modelCatalog) {
      expect(looksLikeSpeechModel(m.file), isTrue, reason: m.file);
      // Ложится в папку, которую findModels() уже просматривает, — иначе
      // скачанное не появится в списке.
      expect(m.path, '$supportDir/models/${m.file}');
      expect(m.url, 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${m.file}');
      expect(m.mb, greaterThan(0));
      expect(m.about, isNotEmpty);
    }
    // Имена не повторяются: иначе две строки каталога боролись бы за один файл.
    expect(modelCatalog.map((m) => m.file).toSet().length, modelCatalog.length);
    // Размер читается человеком: мегабайты до гигабайта, дальше гигабайты.
    expect(modelCatalog.first.size, '74 МБ');
    expect(sizeLabelMb(1549), '1,5 ГБ');
  });

  test('модель везде называется одинаково', () {
    // Каталог, панель и инспектор берут имя из одной функции.
    expect(modelCatalog.map((m) => m.title).toList(),
        ['Tiny', 'Base', 'Small', 'Medium', 'Large v3 Turbo', 'Large v3']);
    expect(modelDisplayName('/x/ggml-large-v3-turbo.bin'), 'Large v3 Turbo');
    // Чужой файл: модель из папки соседнего приложения.
    expect(
        modelDisplayName(
            '/Users/x/Library/Application Support/com.example.речь/models/ggml-large.bin'),
        'Large');
    expect(modelDisplayName('/x/ggml-small.en.bin'), 'Small En');
    // Квантование и версии остаются как есть — их не «причёсывают».
    expect(modelDisplayName('/x/ggml-large-v3-q5_0.bin'), 'Large v3 q5_0');
    // Даже совсем не ggml-файл не должен показываться пустотой.
    expect(modelDisplayName('/x/my-model.bin'), 'My Model');
    expect(modelDisplayName('/x/ggml-.bin'), 'ggml-.bin');
  });

  test('загрузка не выдаёт недокачанное за готовый файл', () async {
    final dir = Directory.systemTemp.createTempSync('tsukiko_dl');
    final dest = '${dir.path}/ggml-tiny.bin';
    // В сеть не ходим: закрытый порт проходит тот же путь, что и обрыв связи.
    final failed = Download('http://127.0.0.1:9/нет.bin', dest);
    expect(await failed.run(), isNull);
    expect(File(dest).existsSync(), isFalse);
    // Кнопка повтора без объяснения бесполезна: причина нужна словами,
    // а не текстом исключения.
    expect(failed.error, 'нет связи с 127.0.0.1');

    // Ответ сервера — совсем другая беда, и звучать должна иначе.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response.statusCode = 404;
      r.response.close();
    });
    final missing = Download('http://127.0.0.1:${server.port}/нет.bin', dest);
    expect(await missing.run(), isNull);
    expect(missing.error, '127.0.0.1 ответил 404');
    await server.close(force: true);

    // Уже готовый файл повторно не качается.
    File(dest).writeAsStringSync('уже есть');
    expect(await Download('http://127.0.0.1:9/нет.bin', dest).run(), dest);
    dir.deleteSync(recursive: true);
  });

  test('свободный порт достаётся от ядра и повторно не выдаётся', () async {
    final a = await freePort(), b = await freePort();
    expect(a, greaterThan(1024));
    expect(a, isNot(b));
  });

  test('whisper-server держит модель и распознаёт фразу за доли секунды',
      () async {
    // Это единственный тест, который поднимает настоящий сервер: без него
    // проверить главную идею (модель живёт между фразами) нечем.
    final models = findModels();
    if (findWhisperServer() == null || models.isEmpty) return;

    final wav = '${Directory.systemTemp.path}/tsukiko_dictation.wav';
    await os.toWav('/System/Library/Sounds/Ping.aiff', wav);

    final server = WhisperServer(idleTimeout: const Duration(seconds: 30));
    try {
      await server.ensureUp(RunOptions(
          model: models.first, lang: 'ru', threads: 4, punctuate: false));
      expect(server.up, isTrue);
      expect(await server.waitReady(timeout: const Duration(seconds: 60)), isTrue);

      // Модель в памяти — значит процесс весит как она сама, а не как заглушка.
      expect(await server.footprintMb(), greaterThan(200));

      // Первая фраза уже на прогретой модели: секунда с запасом.
      final started = DateTime.now();
      await server.transcribe(wav, lang: 'ru');
      expect(DateTime.now().difference(started).inSeconds, lessThan(10));

      // Таймер простоя сдвигается каждым обращением.
      expect(server.untilUnload!.inSeconds, greaterThan(25));

      // Главное: пока идёт запись, простой не считается вовсе. Иначе модель
      // выгружалась посреди длинной фразы, и надиктованное пропадало.
      server.idleTimeout = const Duration(milliseconds: 300);
      server.hold();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(server.up, isTrue, reason: 'аренда обязана пережить таймаут');
      expect(server.untilUnload, isNull);

      // Отпущенная аренда возвращает всё как было: память не наша.
      server.release();
      expect(server.untilUnload!.inMilliseconds, lessThan(400));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(server.up, isFalse);
    } finally {
      await server.shutdown();
      File(wav).deleteSync();
    }
    expect(server.up, isFalse);
    expect(server.untilUnload, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('сирота узнаётся по метке в аргументах, а чужой сервер — нет', () {
    final processes = <ProcListing>[
      (
        pid: 501,
        rssKb: 1657392,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '--tmp-dir $serverMark'
      ),
      (
        pid: 502,
        rssKb: 42000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/чужая.bin --port 9000'
      ),
      (
        pid: 503,
        rssKb: 1600000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '-vm ${os.join(supportDir, 'models/silero.bin')}'
      ),
      (
        pid: 504,
        rssKb: 1500000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '--tmp-dir $legacyServerMark'
      ),
      (pid: 505, rssKb: 9000, args: '/Applications/Чужое.app/Contents/MacOS/Чужое'),
    ];
    final ours = ourServersIn(processes);
    // Свои — по нынешней метке, по папке приложения и по метке прежних
    // сборок. Чужой whisper-server и чужое приложение остаются нетронутыми.
    expect(ours.map((s) => s.pid), [501, 503, 504]);
    expect(ours.first.rssKb, 1657392);
  });

  test('забытый сервер находится без pid-файла и гасится наверняка', () async {
    // Настоящий whisper-server ради этого не поднимаем: проверять надо две
    // вещи — что процесс с нашей меткой виден в ps и что упрямый процесс
    // всё-таки гибнет. «trap "" TERM» — это и есть поведение
    // whisper-server, из-за которого сирота жила часами.
    final fake = await Process.start('/bin/sh', [
      '-c',
      'trap "" TERM; sleep 30 # whisper-server $serverMark',
    ]);
    addTearDown(() => Process.killPid(fake.pid, ProcessSignal.sigkill));

    final found = ourServersIn(await os.listProcesses()).map((s) => s.pid);
    expect(found, contains(fake.pid), reason: 'pid-файла нет, а процесс виден');

    expect(processAlive(fake.pid), isTrue);
    // SIGTERM его не берёт — из-за этого сервер и оставался жить.
    Process.killPid(fake.pid, ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(processAlive(fake.pid), isTrue);

    expect(await killForSure(fake.pid), isTrue);
    expect(processAlive(fake.pid), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('в модель распознавания годится не всякий .bin', () {
    final dir = Directory.systemTemp.createTempSync('tsukiko_model');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Метка ggml на диске — «lmgg», следом размер словаря числом.
    List<int> head(int vocab) => [
          ...'lmgg'.codeUnits,
          vocab & 0xFF,
          (vocab >> 8) & 0xFF,
          (vocab >> 16) & 0xFF,
          (vocab >> 24) & 0xFF,
        ];
    File file(String name, List<int> bytes) =>
        File('${dir.path}/$name')..writeAsBytesSync(bytes);

    final junk = file('модель.bin', List.filled(30 * 1024 * 1024, 7));
    expect(modelFileProblem(junk.path), contains('не модель распознавания'));

    // Модель тишины — тоже ggml, но словарь у неё в десять слов.
    final vad = file('ggml-silero.bin', [...head(10), ...List.filled(900000, 0)]);
    expect(modelFileProblem(vad.path), contains('тишины'));

    final tiny = file('ggml-tiny.bin', head(51865));
    expect(modelFileProblem(tiny.path), contains('слишком мал'));

    final good = file('ggml-ok.bin',
        [...head(51865), ...List.filled(30 * 1024 * 1024, 0)]);
    expect(modelFileProblem(good.path), isNull);

    expect(modelFileProblem('${dir.path}/нет.bin'), contains('больше нет'));

    // И на настоящих файлах, если они есть на этой машине.
    for (final m in findModels()) {
      expect(modelFileProblem(m), isNull, reason: m);
    }
    if (File(vadModelPath).existsSync()) {
      expect(modelFileProblem(vadModelPath), isNotNull);
    }
  });
}

void _hotkeyTaps() {
  group('двойное нажатие', () {
    test('число стуков хранится и читается', () {
      const twice = Hotkey(['fn'], taps: 2);
      expect(twice.isDouble, isTrue);
      final back = Hotkey.fromJson(twice.toJson(), Hotkey.holdDefault);
      expect(back.taps, 2);
      expect(back.mods, ['fn']);
      // Настройки прежних сборок про стуки не знали — там нажатие одно.
      expect(
        Hotkey.fromJson({'mods': ['fn'], 'keys': ['space']}, Hotkey.holdDefault)
            .taps,
        1,
      );
    });

    test('одиночное и двойное — разные жесты', () {
      // Иначе на два действия нельзя было бы повесить одни и те же клавиши.
      expect(const Hotkey(['fn']).sameAs(const Hotkey(['fn'], taps: 2)), isFalse);
      expect(const Hotkey(['fn'], taps: 2).label, contains('дважды'));
    });
  });


  test('окно не наследует текст предыдущего — иначе повтор кормит сам себя', () {
    final args = buildArgs(
        const RunOptions(model: 'm', lang: 'ru', threads: 4), '/a.wav', '/o');
    expect(args.contains('-mc'), isTrue);
    expect(args[args.indexOf('-mc') + 1], '0');
    // Затравка при этом должна доставаться каждому окну, иначе с
    // контекстом уйдут и знаки препинания.
    expect(args.contains('--carry-initial-prompt'), isTrue);
  });

  test('движок работает под своим именем и остаётся тем же движком', () {
    final exe = findWhisper();
    if (exe == null) return;
    final named = runnableWhisper(exe, 'tsukiko-recognizer');
    expect(named, isNotNull);
    expect(os.basename(named!), 'tsukiko-recognizer');
    // Ссылка, а не копия: копия теряет свои библиотеки. И ведёт туда же,
    // куда ведёт поиск, — иначе запустился бы вчерашний движок.
    expect(Link(named).targetSync(), exe);
    // Второй заход не спотыкается о готовую ссылку.
    expect(runnableWhisper(exe, 'tsukiko-recognizer'), named);
  });

  test('продолжение считает с места остановки, а не с начала записи', () {
    const o = RunOptions(model: 'm', lang: 'ru', threads: 4);
    expect(buildArgs(o, '/a.wav', '/o').contains('-ot'), isFalse);
    final again = buildArgs(o, '/a.wav', '/o', from: 600000);
    expect(again[again.indexOf('-ot') + 1], '600000');
  });

  test('подряд идущий повтор сворачивается в один сегмент', () {
    final segs = [
      const Segment(0, 1000, 'Начало.'),
      for (var i = 0; i < 5; i++) Segment(1000 + i * 1000, 2000 + i * 1000, 'Врезок.'),
      const Segment(7000, 8000, 'Конец.'),
      const Segment(8000, 9000, 'Да.'),
      const Segment(9000, 10000, 'Да.'),
    ];
    final out = collapseRepeats(segs);
    expect(out.map((s) => s.text).toList(),
        ['Начало.', 'Врезок.', 'Конец.', 'Да.', 'Да.']);
    expect(out[1].from, 1000);
    expect(out[1].to, 6000);
  });
}
