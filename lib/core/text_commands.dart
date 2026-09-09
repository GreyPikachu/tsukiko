// Голосовые команды: сказанная фраза заменяется заранее заданным текстом.
//
// Здесь нет Flutter и файловой системы. Один и тот же преобразователь
// работает в диктовке, живых фрагментах расшифровщика и тестах, поэтому
// правила совпадают во всех трёх местах.

const textCommandsSetting = 'textCommands';
const dictationCommandsEnabledSetting = 'dictationCommandsEnabled';
const transcriberCommandsEnabledSetting = 'transcriberCommandsEnabled';

class TextCommand {
  const TextCommand(this.phrase, this.replacement);

  final String phrase;
  final String replacement;

  bool get usable => phrase.trim().isNotEmpty;

  Map<String, String> toJson() => {
    'phrase': phrase,
    'replacement': replacement,
  };

  static TextCommand? fromJson(Object? value) {
    if (value is! Map) return null;
    final phrase = value['phrase'];
    final replacement = value['replacement'];
    if (phrase is! String || replacement is! String) return null;
    return TextCommand(phrase, replacement);
  }
}

/// Одна состоявшаяся замена и её положение уже в преобразованном тексте.
/// [original] хранится буквально — с тем регистром, который распознала
/// модель, — поэтому отмена возвращает ровно сказанное, а не шаблон.
class TextReplacement {
  const TextReplacement({
    required this.start,
    required this.end,
    required this.original,
    required this.replacement,
  });

  final int start, end;
  final String original, replacement;

  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'original': original,
    'replacement': replacement,
  };

  static TextReplacement? fromJson(Object? value) {
    if (value is! Map) return null;
    final start = (value['start'] as num?)?.toInt();
    final end = (value['end'] as num?)?.toInt();
    final original = value['original'];
    final replacement = value['replacement'];
    if (start == null ||
        end == null ||
        original is! String ||
        replacement is! String ||
        start < 0 ||
        end < start) {
      return null;
    }
    return TextReplacement(
      start: start,
      end: end,
      original: original,
      replacement: replacement,
    );
  }
}

class CommandText {
  const CommandText(this.text, this.replacements);

  final String text;
  final List<TextReplacement> replacements;
}

final _wordCharacter = RegExp(r'[\p{L}\p{N}_]', unicode: true);

bool _isWordCharacter(String text, int at) {
  if (at < 0 || at >= text.length) return false;
  return _wordCharacter.hasMatch(text.substring(at, at + 1));
}

/// Применить команды слева направо.
///
/// Совпадение не залезает внутрь слова: команда «адрес» не портит
/// «адресат». Если в одной точке подходят несколько правил, побеждает
/// самая длинная фраза — «адрес офиса» раньше «адрес».
CommandText applyTextCommands(String source, Iterable<TextCommand> commands) {
  final rules =
      commands
          .where((command) => command.usable)
          .map(
            (command) => (
              command: command,
              phrase: command.phrase.trim(),
              lower: command.phrase.trim().toLowerCase(),
            ),
          )
          .toList()
        ..sort((a, b) => b.phrase.length.compareTo(a.phrase.length));
  if (source.isEmpty || rules.isEmpty) return CommandText(source, const []);

  final lower = source.toLowerCase();
  final out = StringBuffer();
  final replacements = <TextReplacement>[];
  var at = 0;
  while (at < source.length) {
    ({TextCommand command, String phrase, String lower})? found;
    for (final rule in rules) {
      final end = at + rule.phrase.length;
      if (end > source.length || !lower.startsWith(rule.lower, at)) continue;
      if (_isWordCharacter(source, at - 1) || _isWordCharacter(source, end)) {
        continue;
      }
      found = rule;
      break;
    }
    if (found == null) {
      out.write(source[at]);
      at++;
      continue;
    }

    final start = out.length;
    final original = source.substring(at, at + found.phrase.length);
    out.write(found.command.replacement);
    replacements.add(
      TextReplacement(
        start: start,
        end: start + found.command.replacement.length,
        original: original,
        replacement: found.command.replacement,
      ),
    );
    at += found.phrase.length;
  }
  return CommandText(out.toString(), List.unmodifiable(replacements));
}

/// Отменить одну замену и поправить координаты следующих за ней.
CommandText undoTextReplacement(CommandText text, int index) {
  if (index < 0 || index >= text.replacements.length) return text;
  final hit = text.replacements[index];
  if (hit.start < 0 || hit.end < hit.start || hit.end > text.text.length) {
    return text;
  }
  final restored = text.text.replaceRange(hit.start, hit.end, hit.original);
  final shift = hit.original.length - (hit.end - hit.start);
  final remaining = <TextReplacement>[];
  for (var i = 0; i < text.replacements.length; i++) {
    if (i == index) continue;
    final other = text.replacements[i];
    remaining.add(
      i < index
          ? other
          : TextReplacement(
              start: other.start + shift,
              end: other.end + shift,
              original: other.original,
              replacement: other.replacement,
            ),
    );
  }
  return CommandText(restored, List.unmodifiable(remaining));
}

List<TextCommand> textCommandsFromJson(Object? value) {
  if (value is! List) return const [];
  final commands = <TextCommand>[];
  for (final item in value) {
    final command = TextCommand.fromJson(item);
    if (command != null) commands.add(command);
  }
  return commands;
}

List<TextReplacement> textReplacementsFromJson(Object? value) {
  if (value is! List) return const [];
  final replacements = <TextReplacement>[];
  for (final item in value) {
    final replacement = TextReplacement.fromJson(item);
    if (replacement != null) replacements.add(replacement);
  }
  return replacements;
}
