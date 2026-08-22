import 'dart:convert';

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

// Настройки живут в lib/settings.dart: им нужен dart:ui ради очереди
// записи между изолятами, а этот файл должен оставаться пригодным для
// `dart run` (tool/probe.dart).
