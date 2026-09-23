import 'dart:convert';

import 'languages.dart';
import 'text_commands.dart';
import 'vocabulary.dart';

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
  // Continuation & endings
  'продолжение следует',
  'to be continued',
  'конец фильма',
  'конец серии',
  'конец связи',
  'the end',

  // Subtitle credits & ripper tags
  'субтитры сделал dimatorzok',
  'субтитры делал dimatorzok',
  'субтитры dimatorzok',
  'dimatorzok',
  'редактор субтитров асинецкая корректор аегорова',
  'редактор субтитров а синецкая корректор а егорова',
  'редактор субтитров',
  'автор субтитров',
  'русские субтитры',
  'subtitles by',
  'translated by',

  // Outros & channel plugs
  'спасибо за просмотр',
  'спасибо за внимание',
  'подписывайтесь на канал',
  'не забудьте подписаться',
  'ставьте лайки',
  'ставьте лайк',
  'thanks for watching',
  'thank you for watching',
  'subscribe to my channel',
  'please subscribe',
  'like and subscribe',
};

final _outerDecorations = RegExp(
  r'''^[\s"«»“”„'\[\]\(\)\{\}\*\-—–#]+|[\s"«»“”„'\[\]\(\)\{\}\*\-—–#]+$''',
);

final _standaloneCreditRegex = RegExp(
  r'^(?:'
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^.!?…\n]*|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[а-яёa-z0-9_\-]+[^.!?…\n]*|'
  r'(?:субтитры\s*[:\-—–]?\s*)?dima\s*torzok|'
  r'русские\s+субтитры(?:\s*[:\-—–]\s*.+|\s+(?:от|для)\s+.+|\s*)|'
  r'автор\s+субтитров(?:\s*[:\-—–]\s*.+|\s+[а-яёa-z]\s*\..*|\s+(?:от|для)\s+.+|\s*)|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор|\s*$).*|'
  r'корректор\s+[а-яёa-z]\s*\..*|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?:\s*[:\-—–]\s*.+|\s+(?:от|для)\s+.+|\s*)|'
  r'subtitles\s+(?:by|created\s+by|made\s+by)(?:\s+[^.!?…\n]+)?|'
  r'translated\s+by(?:\s+[^.!?…\n]+)?|'
  r'translation\s+by(?:\s+[^.!?…\n]+)?'
  r')$',
  caseSensitive: false,
);

final _standaloneEndingRegex = RegExp(
  r'^(?:продолжение\s+следует|to\s+be\s+continued|конец\s+фильма|конец\s+серии|конец\s+связи|the\s+end)$',
  caseSensitive: false,
);

final _standaloneOutroRegex = RegExp(
  r'^(?:'
  r'(?:большое\s+)?спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр(?:\s+(?:этого\s+видео|этого\s+ролика|видео|ролика|друзья|ставьте|подписывайтесь|не\s+забудьте).*)?|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s+(?:и|жмит[её]|ставь).*|\s*$)|'
  r'не\s+забудьте\s+подписаться(?:\s+(?:на\s+канал|и|постави).*|\s*$)|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s+(?:и|подписыва).*|\s*$)|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s+(?:this\s+video|guys|everyone|and|please).*|\s*$)|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel(?:\s+.*)?|'
  r'(?:please\s+)?like\s+and\s+subscribe(?:\s+.*)?|'
  r'please\s+subscribe(?:\s+.*)?|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe(?:\s+.*)?"""
  r')$',
  caseSensitive: false,
);

final _trailingHallucinationPattern = RegExp(
  r'(?:(?<=[.!?…])\s*|(?:\s*[,;\-—–:]\s*|\s+))'
  r'(?:'
  // 1. Subtitle credits (longer credit phrases first, cannot span across sentences)
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[^.!?…\n]+[.!?…\s]*|'
  r'(?:(?:субтитры|subtitles|автор|перевод|by|от)\s*[:\-—–]?\s*)?dima\s*torzok\b[^.!?…\n]*[.!?…\s]*|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор|\s*$).*?|'
  r'(?:редактор\s+субтитров.*?)?корректор\s+[а-яёa-z]\s*\..*?|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'автор\s+субтитров(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'русские\s+субтитры(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'subtitles\s+by\b[^.!?…\n]*[.!?…\s]*|'
  r'translated\s+by\b[^.!?…\n]*[.!?…\s]*|'
  r'translation\s+by\b[^.!?…\n]*[.!?…\s]*|'
  // 2. Continuation & endings
  r'продолжение\s+следует[.!?…\s]*|'
  r'to\s+be\s+continued[.!?…\s]*|'
  r'конец\s+фильма[.!?…\s]*|'
  r'конец\s+серии[.!?…\s]*|'
  r'конец\s+связи[.!?…\s]*|'
  r'the\s+end[.!?…\s]*|'
  // 3. Outros & channel plugs
  r'спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр(?:\s*[,–—\-]?\s*(?:этого\s+видео|этого\s+ролика|видео|ролика|друзья|ставьте\s+лайки|подписывайтесь))?[.!?…\s]*|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание[.!?…\s]*|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s*[,–—\-]?\s*(?:и\s+жмите\s+колокольчик|и\s+ставьте\s+лайки|ставьте\s+лайки|ставьте\s+лайк))?[.!?…\s]*|'
  r'не\s+забудьте\s+подписаться(?:\s+на\s+(?:наш\s+)?канал)?(?:\s*[,–—\-]?\s*(?:и\s+поставить\s+лайк|и\s+поставьте\s+лайк))?[.!?…\s]*|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s*[,–—\-]?\s*(?:и\s+подписывайтесь|и\s+подпишитесь))?[.!?…\s]*|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s+(?:this\s+video|guys|everyone))?[.!?…\s]*|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel[.!?…\s]*|'
  r'(?:please\s+)?like\s+and\s+subscribe[.!?…\s]*|'
  r'please\s+subscribe[.!?…\s]*|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe[.!?…\s]*"""
  r')\s*$',
  caseSensitive: false,
);

final _leadingHallucinationPattern = RegExp(
  r'^\s*(?:'
  // 1. Subtitle credits
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]+?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'(?:(?:субтитры|subtitles|автор|перевод|by|от)\s*[:\-—–]?\s*)?dima\s*torzok\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'автор\s+субтитров(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+[а-яёa-z]\s*\.|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'русские\s+субтитры(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'subtitles\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'translated\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'translation\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  // 2. Continuation & endings
  r'(?:продолжение\s+следует|to\s+be\s+continued|конец\s+фильма|конец\s+серии|конец\s+связи|the\s+end)(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  // 3. Outros & channel plugs
  r'спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s*(?:[,.!?…\-]|и\s+.*)|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'не\s+забудьте\s+подписаться(?:\s*[,.!?…\-]|\s+на\s+канал|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s*[,.!?…\-]|и\s+.*|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s*[,.!?…\-]|\s+(?:this\s+video|guys|everyone|and|please)|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:please\s+)?like\s+and\s+subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'please\s+subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)"""
  r')',
  caseSensitive: false,
);

/// Похоже ли это на выдумку модели, а не на сказанное вслух.
bool looksLikeSilenceHallucination(String text) {
  var s = text.trim();
  if (s.isEmpty) return false;

  // Убираем внешние кавычки, скобки, тире, звёздочки
  s = s.replaceAll(_outerDecorations, '').trim();
  if (s.isEmpty) return false;

  // Если текст состоит из нескольких предложений:
  // он является чистой галлюцинацией ТОЛЬКО если каждое предложение — галлюцинация.
  if (s.contains(RegExp(r'(?<=[a-zа-яё0-9]{2,}[.!?…])\s+(?=[А-ЯЁA-Z])|\n+'))) {
    final sentences = s
        .split(RegExp(r'(?<=[a-zа-яё0-9]{2,}[.!?…])\s+(?=[А-ЯЁA-Z])|\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (sentences.length > 1) {
      return sentences.every(looksLikeSilenceHallucination);
    }
  }

  final bare = s
      .toLowerCase()
      .replaceAll(RegExp(r'''[!?.…,"«»“”„'\[\]\(\)\{\}\*\:;\-—–/\\_#]'''), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (bare.isEmpty) return false;

  // 1. Точное совпадение со списком
  if (_silenceHallucinations.contains(bare)) return true;

  // 2. Титры и авторство (проверяем и по s с пунктуацией, и по bare)
  if (_standaloneCreditRegex.hasMatch(s) || _standaloneCreditRegex.hasMatch(bare)) {
    return true;
  }

  // 3. Заставки окончания (строго по границам)
  if (_standaloneEndingRegex.hasMatch(bare)) return true;

  // 4. Концовки и подписки блогеров
  if (_standaloneOutroRegex.hasMatch(bare) || _standaloneOutroRegex.hasMatch(s)) {
    return true;
  }

  return false;
}

/// Удалить галлюцинации модели (титры, концовки видео, подписки),
/// прилипшие в начале или в конце сказанного пользователем.
///
/// Если весь текст состоит только из галлюцинации, возвращается пустая строка.
/// Осмысленная речь («продолжение следует ожидать осенью») не трогается.
String stripSilenceHallucinations(String text) {
  var s = text.trim();
  if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s)) return '';

  // 1. Повторно срезаем галлюцинации в хвосте
  while (true) {
    final m = _trailingHallucinationPattern.firstMatch(s);
    if (m == null) break;
    s = s.substring(0, m.start).trim();
    if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  }

  // 2. Повторно срезаем галлюцинации в начале
  while (true) {
    final m = _leadingHallucinationPattern.firstMatch(s);
    if (m == null) break;
    s = s.substring(m.end).trim();
    if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  }

  // 3. Проверяем предложения внутри текста: если одно из них — чистая галлюцинация
  if (s.contains(RegExp(r'[.!?…]\s+[А-ЯЁA-Z]'))) {
    final parts = s.split(RegExp(r'(?<=[.!?…])\s+(?=[А-ЯЁA-Z])'));
    if (parts.length > 1) {
      final filtered = parts
          .where((p) => !looksLikeSilenceHallucination(p.trim()))
          .toList();
      if (filtered.isNotEmpty && filtered.length < parts.length) {
        s = filtered.join(' ');
      }
    }
  }

  // 4. Очищаем висящие запятые, тире, двоеточия на конце
  s = s.replaceFirst(RegExp(r'[,;:\-—–\s]+$'), '').trim();

  if (s.isEmpty || looksLikeSilenceHallucination(s) || !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s)) return '';
  return s;
}

/// Расшифровка как данные: сегменты, разбор чужих форматов и обратная
/// сборка в наши.

class Segment {
  final int from, to;
  final String text;
  final List<TextReplacement> replacements;

  const Segment(this.from, this.to, this.text, {this.replacements = const []});

  Segment applyCommands(Iterable<TextCommand> commands) {
    final result = applyTextCommands(text, commands);
    return Segment(from, to, result.text, replacements: result.replacements);
  }

  Segment applyVocabulary(Iterable<VocabularyItem> items) {
    final result = applyVocabularyReplacements(text, items);
    return Segment(from, to, result.text, replacements: result.replacements);
  }

  Segment undoReplacement(int index) {
    final result = undoTextReplacement(CommandText(text, replacements), index);
    return Segment(from, to, result.text, replacements: result.replacements);
  }
}

class Transcript {
  final String lang;
  final List<Segment> segments;
  const Transcript(this.lang, this.segments);

  Transcript applyVocabulary(Iterable<VocabularyItem> items) {
    final matcher = VocabularyMatcher(items);
    return Transcript(
      lang,
      segments.map((s) {
        final result = matcher.apply(s.text);
        return Segment(s.from, s.to, result.text,
            replacements: result.replacements);
      }).toList(),
    );
  }
}

final _segmentLine = RegExp(
  r'^\[(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)\]\s*(.*)$',
);

/// whisper-cli печатает готовые сегменты по ходу работы — ловим их сразу,
/// чтобы текст появлялся во время распознавания, а не только в конце.
Segment? parseSegmentLine(String line) {
  final m = _segmentLine.firstMatch(line.trim());
  if (m == null) return null;
  int at(int i) => int.parse(m.group(i)!);
  final from = at(1) * 3600000 + at(2) * 60000 + at(3) * 1000 + at(4);
  final to = at(5) * 3600000 + at(6) * 60000 + at(7) * 1000 + at(8);
  final rawText = m.group(9)!.trim();
  if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) return null;
  final text = stripSilenceHallucinations(rawText).trim();
  return (text.isEmpty || looksLikeSilenceHallucination(text))
      ? null
      : Segment(from, to, text);
}

final _cue = RegExp(
  r'(\d+):(\d{2}):(\d{2})[.,](\d{3})\s*(?:-->|→)\s*(\d+):(\d{2}):(\d{2})[.,](\d{3})',
);

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
    final tail = lines[i]
        .substring(m.end)
        .replaceFirst(RegExp(r'^\s*\]?\s*'), '');
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
    out.add(
      run >= _loopRun
          ? Segment(segs[i].from, segs[j - 1].to, segs[i].text)
          : segs[i],
    );
    i = run >= _loopRun ? j : i + 1;
  }
  return out;
}

/// Разобрать содержимое файла расшифровки.
///
/// Одна дорога на всех, кто открывает готовый текст: очередь по
/// «Открыть расшифровку…» и обзор прошлых расшифровок. Разбираются JSON,
/// субтитры и наш «текст с таймкодами» — такую расшифровку можно
/// пересохранить в любой другой формат. Не разобралось — значит это
/// просто текст, и он отдаётся как есть: показать его всё равно можно,
/// а сочинять из него фрагменты нельзя.
({Transcript? parsed, String? raw}) readTranscript(String path, String text) {
  if (path.toLowerCase().endsWith('.json')) {
    try {
      return (parsed: parseWhisperJson(text), raw: null);
    } catch (_) {
      return (parsed: null, raw: text);
    }
  }
  final parsed = parseSubtitles(text);
  return parsed == null
      ? (parsed: null, raw: text)
      : (parsed: parsed, raw: null);
}

Transcript parseWhisperJson(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final lang = (data['result']?['language'] ?? '?').toString();
  final segs = <Segment>[];
  for (final t in (data['transcription'] as List? ?? [])) {
    final rawText = (t['text'] as String).trim();
    if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) continue;
    final text = stripSilenceHallucinations(rawText).trim();
    // Фрагмент, совпавший с известной выдумкой или очищенный до пустоты, —
    // это тишина, которую модель договорила за себя.
    if (text.isEmpty || looksLikeSilenceHallucination(text)) continue;
    segs.add(
      Segment(
        (t['offsets']['from'] as num).toInt(),
        (t['offsets']['to'] as num).toInt(),
        text,
      ),
    );
  }
  return Transcript(lang, collapseRepeats(segs));
}

/// Разобрать JSON, который пишет `nemo-speech transcribe --format json`.
///
/// NeMo отдаёт времена отдельных слов, а интерфейс работает с фрагментами.
/// Собираем слова по естественным границам: конец предложения, заметная
/// пауза, либо достаточно длинная строка. Таймкоды при этом не теряются.
Transcript parseNemoJson(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final detectedLanguages = (data['languages'] as List? ?? const [])
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList();
  var rawLang = detectedLanguages.isNotEmpty
      ? detectedLanguages.first
      : (data['language']?.toString().isNotEmpty == true
          ? data['language'].toString()
          : '?');
  var lang = normalizeLanguageCode(rawLang);
  final words = (data['words'] as List? ?? const [])
      .whereType<Map>()
      .map((raw) {
        final text = raw['word']?.toString().trim() ?? '';
        final from = (((raw['start'] as num?) ?? 0) * 1000).round();
        final to = (((raw['end'] as num?) ?? 0) * 1000).round();
        return Segment(from, to, text);
      })
      .where((word) => word.text.isNotEmpty)
      .toList();

  if (lang == '?' || lang == 'auto' || lang == 'unknown') {
    final wordsText = words.map((w) => w.text).join(' ');
    final rootText = data['text']?.toString() ?? '';
    final combinedText = '$wordsText $rootText'.trim();
    if (RegExp(r'[\u0400-\u04FF]').hasMatch(combinedText)) {
      lang = 'ru';
    } else {
      final latinCount = RegExp(r'[a-zA-Z]').allMatches(combinedText).length;
      final cyrillicCount =
          RegExp(r'[\u0400-\u04FF]').allMatches(combinedText).length;
      if (latinCount > cyrillicCount && latinCount > 0) {
        lang = 'en';
      }
    }
  }

  if (words.isEmpty) {
    final rawText = data['text']?.toString().trim() ?? '';
    if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) {
      return Transcript(lang, const []);
    }
    final text = stripSilenceHallucinations(rawText).trim();
    if (text.isEmpty || looksLikeSilenceHallucination(text)) {
      return Transcript(lang, const []);
    }
    final duration = (((data['duration'] as num?) ?? 0) * 1000).round();
    return Transcript(lang, [Segment(0, duration, text)]);
  }

  final segments = <Segment>[];
  var start = 0;
  for (var i = 0; i < words.length; i++) {
    final current = words[i];
    final next = i + 1 < words.length ? words[i + 1] : null;
    final chars = words
        .sublist(start, i + 1)
        .fold<int>(0, (sum, word) => sum + word.text.length + 1);
    final sentenceEnd = RegExp(r'[.!?…][\"»”’)]*$').hasMatch(current.text);
    final pause = next != null && next.from - current.to >= 700;
    final tooLong = chars >= 90 || current.to - words[start].from >= 12000;
    if (next == null || sentenceEnd || pause || tooLong) {
      final rawText = words.sublist(start, i + 1).map((word) => word.text).join(' ').trim();
      if (rawText.isNotEmpty && !looksLikeSilenceHallucination(rawText)) {
        final text = stripSilenceHallucinations(rawText).trim();
        if (text.isNotEmpty && !looksLikeSilenceHallucination(text)) {
          segments.add(Segment(words[start].from, current.to, text));
        }
      }
      start = i + 1;
    }
  }
  return Transcript(lang, collapseRepeats(segments));
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
    ? segs
          .map((s) => '[${fmtTs(s.from)} → ${fmtTs(s.to)}]  ${s.text}')
          .join('\n')
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
String renderAs(
  ExportFormat f,
  Transcript t, {
  String name = '',
  String? markdownHeader,
}) => switch (f.id) {
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
