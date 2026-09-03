import 'dart:convert';

/// Что whisper сочиняет на тишине.
///
/// Модель обучена в том числе на субтитрах, и в тишине она договаривает
/// то, чем субтитры кончаются: «Продолжение следует…», «Субтитры сделал…»,
/// «Спасибо за просмотр». Сказано этого не было, и в тексте этому не место.
///
/// Список намеренно узкий, и совпадение — только по целому куску: если
/// человек действительно произнёс «продолжение следует» в середине фразы,
/// фраза останется как есть. Выбрасывается лишь то, что целиком совпало
/// с известной выдумкой.
const _silenceHallucinations = {
  'продолжение следует',
  'субтитры сделал dimatorzok',
  'субтитры делал dimatorzok',
  'редактор субтитров а.синецкая корректор а.егорова',
  'спасибо за просмотр',
  'спасибо за внимание',
  'подписывайтесь на канал',
  'thanks for watching',
  'subscribe to my channel',
  'thank you for watching',
};

/// Похоже ли это на выдумку модели, а не на сказанное вслух.
bool looksLikeSilenceHallucination(String text) {
  final bare = text
      .toLowerCase()
      .replaceAll(RegExp(r'[!?.…,"«»\-—–]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return bare.isNotEmpty && _silenceHallucinations.contains(bare);
}

/// Расшифровка как данные: сегменты, разбор чужих форматов и обратная
/// сборка в наши.

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

/// Сколько одинаковых подряд — уже не речь.
///
/// Два одинаковых предложения человек говорит («Да. Да.»), три и больше
/// секунда в секунду — нет. Такой хвост оставляет сорвавшееся окно:
/// перенос текста между окнами уже отключён (см. `noLoopArgs`), но внутри
/// одного окна модель всё ещё способна повторяться, и это её след.
const _loopRun = 3;

/// Свернуть подряд идущие повторы в один сегмент на всё их время.
/// Сказанное один раз так и остаётся сказанным один раз.
List<Segment> collapseRepeats(List<Segment> segs) {
  final out = <Segment>[];
  var i = 0;
  while (i < segs.length) {
    var j = i + 1;
    while (j < segs.length && segs[j].text == segs[i].text) {
      j++;
    }
    final run = j - i;
    out.add(run >= _loopRun
        ? Segment(segs[i].from, segs[j - 1].to, segs[i].text)
        : segs[i]);
    i = run >= _loopRun ? j : i + 1;
  }
  return out;
}

Transcript parseWhisperJson(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final lang = (data['result']?['language'] ?? '?').toString();
  final segs = <Segment>[];
  for (final t in (data['transcription'] as List? ?? [])) {
    final text = (t['text'] as String).trim();
    // Фрагмент, целиком совпавший с известной выдумкой, — это тишина,
    // которую модель договорила за себя. В расшифровке ему не место.
    if (looksLikeSilenceHallucination(text)) continue;
    segs.add(Segment(
      (t['offsets']['from'] as num).toInt(),
      (t['offsets']['to'] as num).toInt(),
      text,
    ));
  }
  return Transcript(lang, collapseRepeats(segs));
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

/// Markdown с готовой шапкой. Шапку сюда передают: в ней имя записи,
/// язык и число фрагментов — то есть переведённый текст, а переводы
/// приходят из Flutter, которого в этом файле быть не должно
/// (см. `labels.dart`).
String renderMarkdown(String header, List<Segment> segs) {
  final b = StringBuffer(header);
  for (final s in segs) {
    b.writeln('**[${fmtTs(s.from)}]** ${s.text}\n');
  }
  return b.toString();
}

/// Формат экспорта — именованный, с собственным окончанием имени файла.
/// Раньше содержимое .txt зависело от галки «показывать метки времени»,
/// то есть настройка вида молча меняла файл. Теперь это разные форматы.
class ExportFormat {
  const ExportFormat(this.id, this.bareSuffix);
  final String id;

  /// Окончание имени файла без перевода. У текста с таймкодами в нём
  /// стоит слово, а слово это интерфейсное — по-английски файл должен
  /// называться «(timestamps).txt». Переведённое окончание, имя формата
  /// и всё прочее, что произносится вслух, живёт в `labels.dart`:
  /// здесь Flutter появиться не может.
  final String bareSuffix;
}

const formatPlainText = ExportFormat('txt', '.txt');
const formatTimedText = ExportFormat('txt-ts', ' (таймкоды).txt');
const formatSrt = ExportFormat('srt', '.srt');
const formatVtt = ExportFormat('vtt', '.vtt');
const formatMarkdown = ExportFormat('md', '.md');
const formatJson = ExportFormat('json', '.json');

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

/// Расшифровка в выбранном формате.
///
/// [markdownHeader] — готовая шапка markdown-файла; без неё берётся
/// простая, из одного имени. Приложение подставляет переведённую
/// (`renderFor` в `labels.dart`), отдельная программа расшифровки
/// обходится простой: переводов у неё нет.
String renderAs(ExportFormat f, Transcript t,
        {String name = '', String? markdownHeader}) =>
    switch (f.id) {
      'txt' => renderPlain(t.segments, false),
      'txt-ts' => renderPlain(t.segments, true),
      'srt' => renderSrt(t.segments),
      'vtt' => renderVtt(t.segments),
      'md' => renderMarkdown(markdownHeader ?? '# $name\n\n', t.segments),
      'json' => renderJson(t),
      _ => renderPlain(t.segments, false),
    };

// Настройки живут в lib/settings.dart: им нужен dart:ui ради очереди
// записи между изолятами, а этот файл должен оставаться пригодным для
// `dart run` (tool/probe.dart).
