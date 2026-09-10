import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/text_commands.dart';

void main() {
  test('заменяет фразу без учёта регистра и хранит точный оригинал', () {
    final result = applyTextCommands('Пришли Адрес Офиса, пожалуйста.', const [
      TextCommand('адрес офиса', 'Минск, Немига, 1'),
    ]);

    expect(result.text, 'Пришли Минск, Немига, 1, пожалуйста.');
    expect(result.replacements, hasLength(1));
    expect(result.replacements.single.original, 'Адрес Офиса');
    expect(
      result.text.substring(
        result.replacements.single.start,
        result.replacements.single.end,
      ),
      'Минск, Немига, 1',
    );
  });

  test('не срабатывает внутри слова и выбирает длиннейшую команду', () {
    final result = applyTextCommands('адресат; адрес офиса; адрес', const [
      TextCommand('адрес', 'A'),
      TextCommand('адрес офиса', 'B'),
    ]);

    expect(result.text, 'адресат; B; A');
  });

  test('произносимые команды дополняют подсказку модели без повторов', () {
    const commands = [
      TextCommand(' адрес офиса ', 'Минск'),
      TextCommand('Адрес офиса', 'повтор'),
      TextCommand('новая строка', '\n'),
      TextCommand('', 'пусто'),
    ];

    expect(textCommandPhrases(commands), ['адрес офиса', 'новая строка']);
    expect(
      promptWithTextCommands('Имена и термины', commands),
      'Имена и термины, адрес офиса, новая строка',
    );
    expect(
      promptWithTextCommands('Адрес офиса.', commands),
      'Адрес офиса. новая строка',
    );
  });

  test('отмена одной замены сдвигает координаты следующих', () {
    final applied = applyTextCommands('икс и икс', const [
      TextCommand('икс', 'длинная замена'),
    ]);
    final undone = undoTextReplacement(applied, 0);

    expect(undone.text, 'икс и длинная замена');
    expect(undone.replacements, hasLength(1));
    final left = undone.replacements.single;
    expect(undone.text.substring(left.start, left.end), 'длинная замена');
  });

  test('битые и пустые правила с диска пропускаются безопасно', () {
    expect(
      textCommandsFromJson([
        {'phrase': 'новая строка', 'replacement': '\n'},
        {'phrase': 7, 'replacement': 'нет'},
        'нет',
      ]).map((command) => command.phrase),
      ['новая строка'],
    );
    expect(
      applyTextCommands('текст', const [TextCommand('', 'лишнее')]).text,
      'текст',
    );
  });
}
