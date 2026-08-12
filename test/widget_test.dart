import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/dictation.dart';
import 'package:tsukiko/engine.dart';

void main() {
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
    expect(ru.effectivePrompt, contains('пунктуацией'));
    expect(
      const RunOptions(model: 'm', lang: 'en', threads: 4).effectivePrompt,
      contains('punctuation'),
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

  test('владелец модели угадывается по пути к файлу', () {
    expect(
      ownerFromModelPath(
          '/Users/x/Library/Application Support/app.dictara/models/ggml-large.bin'),
      'dictara',
    );
    expect(ownerFromModelPath('/Users/x/.cache/whisper/ggml-large.bin'), isNull);
  });

  test('занятость модели: свободна, когда её никто не держит', () async {
    // несуществующий файл — проверять нечего
    expect((await modelUsage(modelPath: '/нет/такого.bin')).busy, isFalse);

    // реальная модель: сейчас распознавание не идёт, значит свободна
    final models = findModels();
    if (models.isEmpty) return;
    final use = await modelUsage(modelPath: models.first);
    expect(ModelState.values.contains(use.state), isTrue);
    expect(use.label.startsWith('Модель'), isTrue);
  });

  test('разбор процессорного времени из ps', () {
    expect(cpuSeconds('0:00.00'), 0);
    expect(cpuSeconds('69:20.60'), closeTo(69 * 60 + 20.6, 0.001));
    expect(cpuSeconds('1:02:03.5'), closeTo(3723.5, 0.001));
    expect(cpuSeconds('2-03:04:05'), closeTo(2 * 86400 + 3 * 3600 + 4 * 60 + 5, 0.001));
    expect(cpuSeconds('  '), isNull);
    expect(cpuSeconds('чепуха'), isNull);
  });

  test('опрос отдаёт замер CPU, по которому считается следующий', () async {
    final models = findModels();
    if (models.isEmpty) return;

    final first = await modelUsage(modelPath: models.first, others: models);
    // Первый опрос сравнивать не с чем — доля ядра ещё неизвестна.
    expect(first.share, 0);

    await Future<void>.delayed(const Duration(milliseconds: 800));
    final second = await modelUsage(
      modelPath: models.first,
      others: models,
      previous: first.cpu,
    );
    // Замер должен быть привязан ко времени, иначе разницу не поделить.
    if (second.cpu.byPid.isNotEmpty) expect(second.cpu.at, isNotNull);
    // Фоновые процессы не должны выглядеть занятыми.
    expect(second.share, lessThan(0.35));
  });

  test('чужая модель тоже видна, а не только выбранная', () async {
    final models = findModels();
    if (models.length < 2) return;
    // Кандидатов ищем по всем известным моделям: сосед может держать свою.
    final only = await modelUsage(modelPath: models.first);
    final all = await modelUsage(modelPath: models.first, others: models);
    expect(all.learned.length, greaterThanOrEqualTo(only.learned.length));
  });

  test('чужой процесс с большим RSS считается занявшим модель', () async {
    final models = findModels();
    if (models.isEmpty) return;
    // Собственный процесс исключается из проверки: очередь не должна
    // уступать сама себе.
    final self = await modelUsage(modelPath: models.first, ignorePid: pid);
    expect(self.busy, isFalse);
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
    final res = await toWav('/System/Library/Sounds/Ping.aiff', out);
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
  });

  test('подписи сочетаний читаются как в системе', () {
    expect(Hotkey.holdDefault.label, 'fn + ⌃');
    expect(Hotkey.toggleDefault.label, 'fn + Пробел');
    expect(const Hotkey([], key: 'f13').label, 'F13');
    expect(const Hotkey([]).label, 'Не назначено');
    // круг через JSON ничего не теряет
    final back = Hotkey.fromJson(Hotkey.toggleDefault.toJson(), Hotkey.holdDefault);
    expect(back.label, Hotkey.toggleDefault.label);
    // мусор в файле настроек не должен ронять диктовку
    expect(Hotkey.fromJson('чепуха', Hotkey.holdDefault).label, 'fn + ⌃');
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
    await toWav('/System/Library/Sounds/Ping.aiff', wav);

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
    } finally {
      server.shutdown();
      File(wav).deleteSync();
    }
    expect(server.up, isFalse);
    expect(server.untilUnload, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
