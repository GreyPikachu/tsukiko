import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/keyword_tokenizer.dart';

void main() {
  group('KeywordTokenizer', () {
    test('transliterate преобразует русскую кириллицу в фонетическую латиницу', () {
      expect(KeywordTokenizer.transliterate('Джеф'), 'DZHEF');
      expect(KeywordTokenizer.transliterate('привет'), 'PRIVET');
      expect(KeywordTokenizer.transliterate('стоп'), 'STOP');
      expect(KeywordTokenizer.transliterate('компьютер'), 'KOMPYUTER');
      expect(KeywordTokenizer.transliterate('яблоко'), 'YABLOKO');
      expect(KeywordTokenizer.transliterate('Hello'), 'HELLO');
    });

    test('tokenizeWord разбивает слово на токены словаря', () {
      final tokenizer = KeywordTokenizer();
      final tokens = tokenizer.tokenizeWord('Джеф', isFirstWord: true);
      expect(tokens, isNotEmpty);
      // Первый токен первого слова должен содержать BPE-префикс ▁
      expect(tokens.first.startsWith('▁'), isTrue);
    });

    test('formatKeyword форматирует ключевое слово для sherpa-onnx', () {
      final tokenizer = KeywordTokenizer();
      final formatted = tokenizer.formatKeyword(
        'Джеф',
        boostingScore: 1.6,
        threshold: 0.30,
      );

      expect(formatted, contains('@Джеф'));
      expect(formatted, contains(':1.60'));
      expect(formatted, contains('#0.30'));
      expect(formatted.startsWith('▁'), isTrue);
    });

    test('formatKeyword для пустой строки возвращает пустую строку', () {
      final tokenizer = KeywordTokenizer();
      expect(tokenizer.formatKeyword('   '), isEmpty);
    });

    test('buildStreamKeywords объединяет несколько слов через слеш /', () {
      final tokenizer = KeywordTokenizer();
      final combined = tokenizer.buildStreamKeywords(['Джеф', 'стоп']);
      final parts = combined.split('/');
      expect(parts, hasLength(2));
      expect(parts[0], contains('@Джеф'));
      expect(parts[1], contains('@стоп'));
    });

    test('fromTokensFile корректно читает словарь из текстового файла', () {
      const sampleTokens = '''
<blk> 0
<sos/eos> 1
▁HE 2
LL 3
O 4
''';
      final tokenizer = KeywordTokenizer.fromTokensFile(sampleTokens);
      final tokens = tokenizer.tokenizeWord('hello', isFirstWord: true);
      expect(tokens, contains('▁HE'));
    });
  });

  group('stripTrailingCloseWord', () {
    test('удаляет слово завершения в конце текста без пунктуации', () {
      expect(stripTrailingCloseWord('Запиши задачу стоп', 'стоп'), 'Запиши задачу');
      expect(stripTrailingCloseWord('Hello world stop', 'stop'), 'Hello world');
    });

    test('удаляет слово завершения с разной хвостовой пунктуацией', () {
      expect(stripTrailingCloseWord('Запиши задачу стоп.', 'стоп'), 'Запиши задачу');
      expect(stripTrailingCloseWord('Запиши задачу, стоп!', 'стоп'), 'Запиши задачу');
      expect(stripTrailingCloseWord('Запиши задачу — стоп…', 'стоп'), 'Запиши задачу');
      expect(stripTrailingCloseWord('Запиши задачу: стоп?', 'стоп'), 'Запиши задачу');
    });

    test('работает без учёта регистра', () {
      expect(stripTrailingCloseWord('Купи хлеб СТОП', 'стоп'), 'Купи хлеб');
      expect(stripTrailingCloseWord('Купи хлеб Стоп.', 'СТОП'), 'Купи хлеб');
    });

    test('удаляет многословную завершающую фразу', () {
      expect(
        stripTrailingCloseWord('Отправь письмо коллегам, спасибо всё.', 'спасибо всё'),
        'Отправь письмо коллегам',
      );
    });

    test('не удаляет слово завершения, если оно встретилось в середине фразы', () {
      expect(
        stripTrailingCloseWord('Сделай стоп-кадр прямо сейчас', 'стоп'),
        'Сделай стоп-кадр прямо сейчас',
      );
      expect(
        stripTrailingCloseWord('На слове стоп остановись и продолжай', 'стоп'),
        'На слове стоп остановись и продолжай',
      );
    });

    test('не отрезает завершающее слово, если оно является подстрокой другого слова', () {
      // "поток" оканчивается на "ток", но это цельное слово
      expect(stripTrailingCloseWord('Включи поток.', 'ток'), 'Включи поток.');
      // "хлопок" оканчивается на "ок", но это не отдельное слово
      expect(stripTrailingCloseWord('Раздался хлопок.', 'ок'), 'Раздался хлопок.');
    });

    test('возвращает исходный текст, если closeWord или text пустые', () {
      expect(stripTrailingCloseWord('Текст сообщения', ''), 'Текст сообщения');
      expect(stripTrailingCloseWord('', 'стоп'), '');
      expect(stripTrailingCloseWord('   ', 'стоп'), '   ');
    });

    test('удаляет повторенные подряд слова завершения (например при повторе "пока, пока")', () {
      expect(
        stripTrailingCloseWord('Смотри, ситуация в чем. Пока. Пока!', 'пока'),
        'Смотри, ситуация в чем.',
      );
      expect(
        stripTrailingCloseWord('Тоже это учти, пока, пока.', 'пока'),
        'Тоже это учти',
      );
      expect(
        stripTrailingCloseWord('Пока, пока!', 'пока'),
        '',
      );
    });

    test('удаляет слово завершения в кавычках и скобках', () {
      expect(
        stripTrailingCloseWord('Смотри, ситуация в чем: "пока"', 'пока'),
        'Смотри, ситуация в чем',
      );
      expect(
        stripTrailingCloseWord('Смотри, ситуация в чем. «Пока!»', 'пока'),
        'Смотри, ситуация в чем.',
      );
      expect(
        stripTrailingCloseWord('Завершаем мысль (стоп).', 'стоп'),
        'Завершаем мысль',
      );
    });
  });
}
