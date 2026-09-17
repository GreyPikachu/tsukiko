import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/models.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/platform/os.dart';

import '../support/fake_os.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('Class 1: Subtitle / fansub credits', () {
    test('Subclass 1.1: DimaTorzok credit variants', () {
      final variations = [
        'Субтитры сделал DimaTorzok',
        'субтитры делал dimatorzok',
        'Субтитры делал DimaTorzok',
        'субтитры dimatorzok',
        'Субтитры: DimaTorzok',
        'субтитры - DimaTorzok',
        'субтитры — DimaTorzok',
        'Субтитры от DimaTorzok',
        'Subtitles by DimaTorzok',
        'dimatorzok',
        'DimaTorzok',
        'DIMA TORZOK',
        'dima torzok',
        'Dima Torzok',
      ];

      for (final text in variations) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize DimaTorzok credit: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone DimaTorzok credit: "$text"',
        );
      }
    });

    test('Subclass 1.2: Generic author and contributor credits', () {
      final authorCredits = [
        'Субтитры добавил Alex',
        'Субтитры подготовил Иван',
        'Субтитры перевел Пётр',
        'Субтитры перевёл Пётр',
        'Субтитры создал Alex',
        'Субтитры оформил Alex',
        'Субтитры писал Сергей',
        'Субтитры для глухих',
        'Субтитры от студии Кравец',
        'Автор субтитров: Alex',
        'автор субтитров: А. Иванов',
        'автор субтитров',
        'Русские субтитры',
        'русские субтитры: студия',
        'Русские субтитры от команды',
      ];

      for (final text in authorCredits) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize author credit: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone author credit: "$text"',
        );
      }
    });

    test('Subclass 1.3: Editor and corrector credits', () {
      final editorCredits = [
        'Редактор субтитров А.Синецкая корректор А.Егорова',
        'Редактор субтитров А. Синецкая корректор А. Егорова',
        'редактор субтитров асинецкая корректор аегорова',
        'Редактор субтитров: А.Синецкая',
        'редактор субтитров',
        'Корректор А. Егорова',
        'Корректор А.Егорова.',
      ];

      for (final text in editorCredits) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize editor credit: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone editor credit: "$text"',
        );
      }
    });

    test('Subclass 1.4: Translation credits', () {
      final translationCredits = [
        'Перевод и субтитры: Студия',
        'Перевод на русский язык: Studio',
        'Перевод текста: Alex',
        'Перевод и озвучка: LostFilm',
        'Subtitles by John Doe',
        'subtitles by john',
        'subtitles created by Jane',
        'subtitles made by Team',
        'Translated by Jane Doe',
        'translated by alex',
        'Translation by John Doe',
        'translation by Studio',
      ];

      for (final text in translationCredits) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize translation credit: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone translation credit: "$text"',
        );
      }
    });
  });

  group('Class 2: Movie / TV episode closings', () {
    test('Standalone episode and movie endings', () {
      final closings = [
        'Продолжение следует',
        'продолжение следует',
        'ПРОДОЛЖЕНИЕ СЛЕДУЕТ',
        'Продолжение следует...',
        'Продолжение следует…',
        '«Продолжение следует»',
        'To be continued',
        'to be continued',
        'TO BE CONTINUED',
        'To be continued...',
        '[To be continued]',
        'Конец фильма',
        'конец фильма.',
        'КОНЕЦ ФИЛЬМА',
        'Конец серии',
        'конец серии.',
        'Конец связи',
        'конец связи.',
        'The end',
        'the end',
        'THE END.',
        '«The End»',
      ];

      for (final text in closings) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize closing: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone closing: "$text"',
        );
      }
    });
  });

  group('Class 3: Video / blogger outros and calls to action', () {
    test('Gratitude and outros', () {
      final outros = [
        'Спасибо за просмотр',
        'Спасибо за просмотр!',
        'Большое спасибо за просмотр',
        'Спасибо всем за просмотр!',
        'Спасибо большое за просмотр этого видео',
        'Спасибо за просмотр видео',
        'Спасибо за просмотр ролика',
        'Спасибо за просмотр друзья',
        'Спасибо за внимание',
        'Спасибо за внимание!',
        'Большое спасибо за внимание.',
        'большое спасибо за внимание',
        'Thanks for watching',
        'Thanks for watching!',
        'Thank you for watching',
        'Thank you for watching!',
        'Thank you so much for watching guys',
        'Thank you so much for watching this video',
        'Thanks for watching everyone',
      ];

      for (final text in outros) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize outro: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone outro: "$text"',
        );
      }
    });

    test('Subscriptions and like plugs', () {
      final plugs = [
        'Подписывайтесь на канал',
        'Подписывайтесь на наш канал',
        'Подписывайтесь на канал и ставьте лайки',
        'Подпишитесь на канал',
        'Подпишитесь на наш канал',
        'Не забудьте подписаться',
        'Не забудьте подписаться на канал',
        'Не забудьте подписаться на канал и поставить лайк',
        'Ставьте лайки',
        'Ставьте лайки!',
        'Ставьте лайк',
        'Не забудьте поставить лайк',
        'Subscribe to my channel',
        'Subscribe to our channel',
        'Please subscribe',
        'Please subscribe to the channel',
        'Like and subscribe',
        'Please like and subscribe',
        "Don't forget to subscribe",
        "Don't forget to like and subscribe",
        'Dont forget to subscribe',
      ];

      for (final text in plugs) {
        expect(
          looksLikeSilenceHallucination(text),
          isTrue,
          reason: 'Failed to recognize channel plug: "$text"',
        );
        expect(
          stripSilenceHallucinations(text),
          isEmpty,
          reason: 'Failed to strip standalone plug: "$text"',
        );
      }
    });
  });

  group('Class 4: Mixed legitimate speech + outros', () {
    test('Subclass 4.1: Trailing hallucination removal', () {
      final cases = {
        'Сегодня мы провели отличный митап. Спасибо за просмотр!':
            'Сегодня мы провели отличный митап.',
        'Все тесты успешно пройдены. Субтитры сделал DimaTorzok':
            'Все тесты успешно пройдены.',
        'Мы завершили первую фазу проекта, продолжение следует...':
            'Мы завершили первую фазу проекта',
        'Отчёт готов к отправке. Конец связи.':
            'Отчёт готов к отправке.',
        'We implemented the feature. Thanks for watching!':
            'We implemented the feature.',
        'Deploy was successful. Like and subscribe!':
            'Deploy was successful.',
        'Все задачи закрыты. Спасибо за просмотр! Подписывайтесь на канал.':
            'Все задачи закрыты.',
        'План выполнен на сто процентов. Редактор субтитров А.Синецкая':
            'План выполнен на сто процентов.',
      };

      cases.forEach((input, expected) {
        expect(
          looksLikeSilenceHallucination(input),
          isFalse,
          reason: 'Mixed text must not be flagged as pure hallucination: "$input"',
        );
        expect(
          stripSilenceHallucinations(input),
          expected,
          reason: 'Failed to strip trailing hallucination from: "$input"',
        );
      });
    });

    test('Subclass 4.2: Leading hallucination removal', () {
      final cases = {
        'Субтитры сделал DimaTorzok. Привет всем участникам встречи!':
            'Привет всем участникам встречи!',
        'Продолжение следует... Но сначала вспомним, о чём шла речь ранее.':
            'Но сначала вспомним, о чём шла речь ранее.',
        'Спасибо за просмотр! Начнём сегодняшнее обсуждение с архитектуры.':
            'Начнём сегодняшнее обсуждение с архитектуры.',
        'The end. Let us examine the test outcomes.':
            'Let us examine the test outcomes.',
        'Редактор субтитров А.Синецкая. Доброе утро, коллеги!':
            'Доброе утро, коллеги!',
      };

      cases.forEach((input, expected) {
        expect(
          looksLikeSilenceHallucination(input),
          isFalse,
          reason: 'Mixed text must not be flagged as pure hallucination: "$input"',
        );
        expect(
          stripSilenceHallucinations(input),
          expected,
          reason: 'Failed to strip leading hallucination from: "$input"',
        );
      });
    });

    test('Subclass 4.3: Middle hallucination removal between sentences', () {
      const input =
          'Первый модуль собран без ошибок. Спасибо за просмотр! Второй модуль тоже готов к тестам.';
      expect(looksLikeSilenceHallucination(input), isFalse);
      expect(
        stripSilenceHallucinations(input),
        'Первый модуль собран без ошибок. Второй модуль тоже готов к тестам.',
      );

      const inputWithCredit =
          'Мы подготовили сборку. Субтитры сделал DimaTorzok. Отправляем в тестирование.';
      expect(
        stripSilenceHallucinations(inputWithCredit),
        'Мы подготовили сборку. Отправляем в тестирование.',
      );
    });

    test('Subclass 4.4: Trailing hallucination with comma, dash, or colon', () {
      expect(
        stripSilenceHallucinations('На сегодня всё, спасибо за просмотр'),
        'На сегодня всё',
      );
      expect(
        stripSilenceHallucinations('Завтра созвон — подписывайтесь на канал'),
        'Завтра созвон',
      );
      expect(
        stripSilenceHallucinations('Результаты теста: субтитры сделал DimaTorzok'),
        'Результаты теста',
      );
    });
  });

  group('Class 5: Legitimate speech negative controls (MUST NOT BE STRIPPED)', () {
    final legitimatePhrases = [
      'Фильм интересный, продолжение следует ждать осенью',
      'Здесь продолжение следует из предыдущего утверждения',
      'В конце фильма герои встречаются снова',
      'Субтитры к фильму были переведены неточно',
      'Спасибо за внимание к деталям в проекте',
      'Большое спасибо за внимание к нашей проблеме',
      'Подписывайтесь на канал поставки оборудования',
      'Редактор субтитров в этой программе работает отлично',
      'Я поставил лайки всем постам автора',
      'Поставьте лайки на все сообщения в чате поддержки',
      'Thanks for watching out for me yesterday',
      'The end of the road was blocked by trees',
      'To be continued as previously agreed by all partners',
      'Конец связи с сервером произошёл внезапно',
      'Конец серии экспериментов показал отличный результат',
      'Автор субтитров допустил грамматическую ошибку',
    ];

    for (final phrase in legitimatePhrases) {
      test('Preserves legitimate phrase: "$phrase"', () {
        expect(
          looksLikeSilenceHallucination(phrase),
          isFalse,
          reason: 'Legitimate speech falsely flagged as hallucination: "$phrase"',
        );
        expect(
          stripSilenceHallucinations(phrase),
          phrase,
          reason: 'Legitimate speech was modified or stripped: "$phrase"',
        );
      });
    }
  });

  group('Class 6: Dictation processing (tidyDictated)', () {
    test('Subclass 6.1: Prunes bracketed acoustic artifacts', () {
      final artifacts = [
        '[музыка]',
        '(музыка)',
        '*музыка*',
        '[BLANK_AUDIO]',
        '(смех)',
        '[аплодисменты]',
        '*applause*',
        '[laughter]',
        '(тишина)',
      ];

      for (final artifact in artifacts) {
        expect(
          tidyDictated(artifact),
          isEmpty,
          reason: 'Failed to prune acoustic artifact: "$artifact"',
        );
      }
    });

    test('Subclass 6.2: Strips leading dialogue dashes', () {
      expect(tidyDictated('- Привет, как дела?'), 'Привет, как дела?');
      expect(tidyDictated('— Доброе утро.'), 'Доброе утро.');
      expect(tidyDictated('– Проверка связи.'), 'Проверка связи.');
      expect(tidyDictated('-- Двойное тире в начале'), 'Двойное тире в начале');
      expect(tidyDictated('- - С пробелами'), 'С пробелами');
    });

    test('Subclass 6.3: Pure silence hallucinations in dictation return empty', () {
      expect(tidyDictated('Субтитры сделал DimaTorzok'), isEmpty);
      expect(tidyDictated('Продолжение следует...'), isEmpty);
      expect(tidyDictated('Спасибо за просмотр!'), isEmpty);
      expect(tidyDictated('To be continued'), isEmpty);
      expect(tidyDictated('Like and subscribe!'), isEmpty);
    });

    test('Subclass 6.4: Strips trailing hallucination from dictation', () {
      expect(
        tidyDictated('Завтра в десять утра встреча. Спасибо за просмотр!'),
        'Завтра в десять утра встреча.',
      );
      expect(
        tidyDictated('- Завтра релиз, подписывайтесь на канал'),
        'Завтра релиз',
      );
      expect(
        tidyDictated('Делаем коммит. Субтитры сделал DimaTorzok'),
        'Делаем коммит.',
      );
    });

    test('Subclass 6.5: Strips leading hallucination from dictation', () {
      expect(
        tidyDictated('Продолжение следует... Отправьте отчёт клиенту.'),
        'Отправьте отчёт клиенту.',
      );
      expect(
        tidyDictated('Спасибо за просмотр! Приступаем к работе.'),
        'Приступаем к работе.',
      );
    });

    test('Subclass 6.6: Normalizes whitespace, newlines and tabs', () {
      expect(
        tidyDictated('   \n\t  -  Привет,   мир!  \t\n  '),
        'Привет, мир!',
      );
      expect(
        tidyDictated('Первая строка.\nВторая строка.'),
        'Первая строка. Вторая строка.',
      );
    });

    test('Subclass 6.7: Legitimate dictation preserved', () {
      expect(
        tidyDictated('Создай пулл реквест и назначь ревьюеров'),
        'Создай пулл реквест и назначь ревьюеров',
      );
      expect(
        tidyDictated('Большое спасибо за внимание к деталям задачи'),
        'Большое спасибо за внимание к деталям задачи',
      );
    });
  });

  group('Class 7: Multi-segment transcript processing', () {
    test('Subclass 7.1: parseWhisperJson filters hallucinations across segments', () {
      final fixture = jsonEncode({
        'result': {'language': 'ru'},
        'transcription': [
          {
            'offsets': {'from': 0, 'to': 1500},
            'text': 'Субтитры сделал DimaTorzok',
          },
          {
            'offsets': {'from': 1500, 'to': 4000},
            'text': 'Первая важная мысль выступления.',
          },
          {
            'offsets': {'from': 4000, 'to': 6500},
            'text': 'Вторая важная мысль. Спасибо за просмотр!',
          },
          {
            'offsets': {'from': 6500, 'to': 8000},
            'text': 'Подписывайтесь на канал!',
          },
          {
            'offsets': {'from': 8000, 'to': 10000},
            'text': 'Продолжение следует...',
          },
          {
            'offsets': {'from': 10000, 'to': 12000},
            'text': 'Третья мысль после тишины.',
          },
        ],
      });

      final transcript = parseWhisperJson(fixture);
      expect(transcript.lang, 'ru');
      expect(transcript.segments, hasLength(3));
      expect(transcript.segments[0].text, 'Первая важная мысль выступления.');
      expect(transcript.segments[0].from, 1500);
      expect(transcript.segments[0].to, 4000);
      expect(transcript.segments[1].text, 'Вторая важная мысль.');
      expect(transcript.segments[1].from, 4000);
      expect(transcript.segments[1].to, 6500);
      expect(transcript.segments[2].text, 'Третья мысль после тишины.');
      expect(transcript.segments[2].from, 10000);
      expect(transcript.segments[2].to, 12000);
    });

    test('Subclass 7.2: parseNemoJson with word timestamps filters hallucinations', () {
      final fixture = jsonEncode({
        'text':
            'Привет мир. Субтитры сделал DimaTorzok. Продолжаем разговор. Спасибо за просмотр!',
        'duration': 8.0,
        'languages': ['ru-RU'],
        'words': [
          {'word': 'Привет', 'start': 0.0, 'end': 0.4},
          {'word': 'мир.', 'start': 0.4, 'end': 0.8},
          {'word': 'Субтитры', 'start': 1.5, 'end': 1.9},
          {'word': 'сделал', 'start': 1.9, 'end': 2.3},
          {'word': 'DimaTorzok.', 'start': 2.3, 'end': 2.8},
          {'word': 'Продолжаем', 'start': 3.5, 'end': 4.0},
          {'word': 'разговор.', 'start': 4.0, 'end': 4.5},
          {'word': 'Спасибо', 'start': 5.0, 'end': 5.3},
          {'word': 'за', 'start': 5.3, 'end': 5.5},
          {'word': 'просмотр!', 'start': 5.5, 'end': 6.0},
        ],
      });

      final transcript = parseNemoJson(fixture);
      expect(transcript.lang, 'ru');
      expect(transcript.segments, hasLength(2));
      expect(transcript.segments[0].text, 'Привет мир.');
      expect(transcript.segments[1].text, 'Продолжаем разговор.');
    });

    test('Subclass 7.3: parseNemoJson without word-level timestamps', () {
      final pureHallucination = jsonEncode({
        'text': 'Субтитры сделал DimaTorzok',
        'duration': 2.5,
        'language': 'ru',
        'words': [],
      });
      final t1 = parseNemoJson(pureHallucination);
      expect(t1.segments, isEmpty);

      final trailingHallucination = jsonEncode({
        'text': 'Отчёт готов. Спасибо за просмотр!',
        'duration': 3.0,
        'language': 'ru',
        'words': [],
      });
      final t2 = parseNemoJson(trailingHallucination);
      expect(t2.segments, hasLength(1));
      expect(t2.segments.single.text, 'Отчёт готов.');

      final legitimate = jsonEncode({
        'text': 'Осмысленная фраза без галлюцинаций',
        'duration': 2.0,
        'language': 'ru',
        'words': [],
      });
      final t3 = parseNemoJson(legitimate);
      expect(t3.segments, hasLength(1));
      expect(t3.segments.single.text, 'Осмысленная фраза без галлюцинаций');
    });

    test('Subclass 7.4: parseSegmentLine live stream parser', () {
      expect(
        parseSegmentLine('[00:00:01.000 --> 00:00:03.000]   Субтитры сделал DimaTorzok'),
        isNull,
      );
      expect(
        parseSegmentLine('[00:00:03.000 --> 00:00:05.000]   Продолжение следует...'),
        isNull,
      );
      expect(
        parseSegmentLine('[00:00:05.000 --> 00:00:07.000]   Спасибо за внимание!'),
        isNull,
      );

      final cleaned = parseSegmentLine(
        '[00:00:07.000 --> 00:00:10.000]   Зафиксировали результат, спасибо за просмотр!',
      );
      expect(cleaned, isNotNull);
      expect(cleaned!.text, 'Зафиксировали результат');
      expect(cleaned.from, 7000);
      expect(cleaned.to, 10000);

      final legitimate = parseSegmentLine(
        '[00:00:10.000 --> 00:00:12.000]   Спасибо за внимание к деталям в проекте.',
      );
      expect(legitimate, isNotNull);
      expect(legitimate!.text, 'Спасибо за внимание к деталям в проекте.');
    });
  });

  group('Boundary Value Analysis (BVA)', () {
    group('Boundary 1: Position', () {
      test('100% Hallucination', () {
        const text = 'Субтитры сделал DimaTorzok';
        expect(looksLikeSilenceHallucination(text), isTrue);
        expect(stripSilenceHallucinations(text), isEmpty);
      });

      test('Leading Hallucination', () {
        const text = 'Субтитры сделал DimaTorzok. Мы начинаем трансляцию.';
        expect(looksLikeSilenceHallucination(text), isFalse);
        expect(stripSilenceHallucinations(text), 'Мы начинаем трансляцию.');
      });

      test('Trailing Hallucination', () {
        const text = 'Мы закончили трансляцию. Субтитры сделал DimaTorzok';
        expect(looksLikeSilenceHallucination(text), isFalse);
        expect(stripSilenceHallucinations(text), 'Мы закончили трансляцию.');
      });

      test('Middle Hallucination', () {
        const text =
            'Вводная часть завершена. Субтитры сделал DimaTorzok. Переходим к выводам.';
        expect(looksLikeSilenceHallucination(text), isFalse);
        expect(
          stripSilenceHallucinations(text),
          'Вводная часть завершена. Переходим к выводам.',
        );
      });

      test('0% Hallucination (Pure Legitimate Speech)', () {
        const text = 'Вводная часть завершена. Переходим к выводам.';
        expect(looksLikeSilenceHallucination(text), isFalse);
        expect(stripSilenceHallucinations(text), text);
      });
    });

    group('Boundary 2: Punctuation and Outer Decorations', () {
      test('No terminal punctuation', () {
        expect(looksLikeSilenceHallucination('Спасибо за просмотр'), isTrue);
        expect(stripSilenceHallucinations('Спасибо за просмотр'), isEmpty);
      });

      test('Period terminal punctuation', () {
        expect(looksLikeSilenceHallucination('Спасибо за просмотр.'), isTrue);
        expect(stripSilenceHallucinations('Спасибо за просмотр.'), isEmpty);
      });

      test('Comma terminal punctuation', () {
        expect(looksLikeSilenceHallucination('Спасибо за просмотр,'), isTrue);
        expect(stripSilenceHallucinations('Спасибо за просмотр,'), isEmpty);
      });

      test('Colon and semicolon', () {
        expect(looksLikeSilenceHallucination('Субтитры сделал DimaTorzok:'), isTrue);
        expect(looksLikeSilenceHallucination('Конец фильма;'), isTrue);
      });

      test('Exclamation mark', () {
        expect(looksLikeSilenceHallucination('Спасибо за просмотр!'), isTrue);
        expect(stripSilenceHallucinations('Спасибо за просмотр!'), isEmpty);
      });

      test('Question mark', () {
        expect(looksLikeSilenceHallucination('Продолжение следует?'), isTrue);
        expect(stripSilenceHallucinations('Продолжение следует?'), isEmpty);
      });

      test('Ellipsis variants (ASCII and Unicode)', () {
        expect(looksLikeSilenceHallucination('Продолжение следует...'), isTrue);
        expect(looksLikeSilenceHallucination('Продолжение следует…'), isTrue);
        expect(stripSilenceHallucinations('Продолжение следует...'), isEmpty);
        expect(stripSilenceHallucinations('Продолжение следует…'), isEmpty);
      });

      test('Quotes: straight double, Russian guillemets, curly quotes', () {
        expect(looksLikeSilenceHallucination('"Продолжение следует"'), isTrue);
        expect(looksLikeSilenceHallucination('«Продолжение следует»'), isTrue);
        expect(looksLikeSilenceHallucination('“To be continued”'), isTrue);
        expect(looksLikeSilenceHallucination('„Конец фильма“'), isTrue);
      });

      test('Enclosing brackets and special wrappers', () {
        expect(looksLikeSilenceHallucination('[To be continued]'), isTrue);
        expect(looksLikeSilenceHallucination('(Спасибо за просмотр)'), isTrue);
        expect(looksLikeSilenceHallucination('{The end}'), isTrue);
        expect(looksLikeSilenceHallucination('*Подписывайтесь на канал*'), isTrue);
        expect(looksLikeSilenceHallucination('— Конец фильма —'), isTrue);
        expect(looksLikeSilenceHallucination('### Спасибо за просмотр'), isTrue);
      });

      test('Dangling punctuation cleanup after stripping', () {
        expect(
          stripSilenceHallucinations('Работа сделана, спасибо за просмотр!'),
          'Работа сделана',
        );
        expect(
          stripSilenceHallucinations('Работа сделана: спасибо за просмотр!'),
          'Работа сделана',
        );
        expect(
          stripSilenceHallucinations('Работа сделана — спасибо за просмотр!'),
          'Работа сделана',
        );
        expect(
          stripSilenceHallucinations('Работа сделана; спасибо за просмотр!'),
          'Работа сделана',
        );
      });
    });

    group('Boundary 3: Casing & Whitespace Variations', () {
      test('All lowercase', () {
        expect(looksLikeSilenceHallucination('спасибо за просмотр'), isTrue);
        expect(looksLikeSilenceHallucination('dimatorzok'), isTrue);
        expect(looksLikeSilenceHallucination('to be continued'), isTrue);
      });

      test('ALL UPPERCASE', () {
        expect(looksLikeSilenceHallucination('СПАСИБО ЗА ПРОСМОТР!'), isTrue);
        expect(looksLikeSilenceHallucination('DIMATORZOK'), isTrue);
        expect(looksLikeSilenceHallucination('TO BE CONTINUED'), isTrue);
        expect(looksLikeSilenceHallucination('THE END'), isTrue);
      });

      test('Title Case', () {
        expect(looksLikeSilenceHallucination('Спасибо За Просмотр'), isTrue);
        expect(looksLikeSilenceHallucination('To Be Continued'), isTrue);
      });

      test('Mixed / camelCase', () {
        expect(looksLikeSilenceHallucination('DimaTorzok'), isTrue);
        expect(looksLikeSilenceHallucination('dImAtOrZoK'), isTrue);
        expect(looksLikeSilenceHallucination('sUbTiTlEs By'), isTrue);
      });

      test('Leading and trailing whitespace', () {
        expect(looksLikeSilenceHallucination('   \t\n  Спасибо за просмотр   \n\t  '), isTrue);
        expect(stripSilenceHallucinations('   \t\n  Спасибо за просмотр   \n\t  '), isEmpty);
      });

      test('Redundant internal whitespace, tabs, and newlines', () {
        expect(
          looksLikeSilenceHallucination('Субтитры   \t   сделал   \t   DimaTorzok'),
          isTrue,
        );
        expect(
          stripSilenceHallucinations('Субтитры   \t   сделал   \t   DimaTorzok'),
          isEmpty,
        );
      });
    });

    group('Boundary 4: Length Boundaries', () {
      test('Length = 0 (Empty string)', () {
        expect(looksLikeSilenceHallucination(''), isFalse);
        expect(stripSilenceHallucinations(''), isEmpty);
      });

      test('Whitespace only', () {
        expect(looksLikeSilenceHallucination('   \t\n  '), isFalse);
        expect(stripSilenceHallucinations('   \t\n  '), isEmpty);
      });

      test('Punctuation / decorations only', () {
        expect(looksLikeSilenceHallucination('...'), isFalse);
        expect(looksLikeSilenceHallucination('---'), isFalse);
        expect(looksLikeSilenceHallucination('[ ]'), isFalse);
        expect(stripSilenceHallucinations('...'), isEmpty);
      });

      test('Single word boundaries', () {
        // Hallucination single word
        expect(looksLikeSilenceHallucination('dimatorzok'), isTrue);
        expect(stripSilenceHallucinations('dimatorzok'), isEmpty);

        // Legitimate single words MUST NOT be flagged
        expect(looksLikeSilenceHallucination('Привет'), isFalse);
        expect(looksLikeSilenceHallucination('Да'), isFalse);
        expect(looksLikeSilenceHallucination('Нет'), isFalse);
        expect(looksLikeSilenceHallucination('Hello'), isFalse);
        expect(stripSilenceHallucinations('Привет'), 'Привет');
      });

      test('Very long paragraph (1000+ chars) with trailing hallucination', () {
        final longLegitimateText = List.generate(
          15,
          (i) => 'Предложение номер $i описывает ключевые аспекты системной архитектуры и надёжности.',
        ).join(' ');

        expect(longLegitimateText.length, greaterThan(1000));

        final fullTextWithOutro = '$longLegitimateText Спасибо за просмотр! Подписывайтесь на канал.';

        expect(looksLikeSilenceHallucination(fullTextWithOutro), isFalse);
        final cleaned = stripSilenceHallucinations(fullTextWithOutro);
        expect(cleaned, longLegitimateText);
      });
    });
  });

  group('Server transcribe response processing (Whisper and NeMo fixtures)', () {
    test('Simulated Whisper HTTP server /inference endpoint response parsing', () {
      final whisperSuccessPayload = jsonEncode({
        'text': 'Мы проверили работоспособность алгоритма. Спасибо за просмотр!',
      });
      final data = jsonDecode(whisperSuccessPayload);
      final result = tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
      expect(result, 'Мы проверили работоспособность алгоритма.');

      final whisperPureHallucinationPayload = jsonEncode({
        'text': 'Субтитры сделал DimaTorzok',
      });
      final data2 = jsonDecode(whisperPureHallucinationPayload);
      final result2 = tidyDictated((data2 is Map ? data2['text'] : null)?.toString() ?? '');
      expect(result2, isEmpty);

      final whisperBracketedAudioPayload = jsonEncode({
        'text': '[BLANK_AUDIO]',
      });
      final data3 = jsonDecode(whisperBracketedAudioPayload);
      final result3 = tidyDictated((data3 is Map ? data3['text'] : null)?.toString() ?? '');
      expect(result3, isEmpty);
    });

    test('Simulated NeMo HTTP server /v1/audio/transcriptions response parsing', () {
      final nemoSuccessPayload = jsonEncode({
        'text': '- Тестирование NeMo прошло успешно. Подписывайтесь на канал!',
      });
      final data = jsonDecode(nemoSuccessPayload);
      final result = tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
      expect(result, 'Тестирование NeMo прошло успешно.');

      final nemoPureHallucinationPayload = jsonEncode({
        'text': 'To be continued...',
      });
      final data2 = jsonDecode(nemoPureHallucinationPayload);
      final result2 = tidyDictated((data2 is Map ? data2['text'] : null)?.toString() ?? '');
      expect(result2, isEmpty);
    });

    test('Simulated local HTTP server emulating WhisperServer.transcribe pipeline', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;

      server.listen((HttpRequest request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/inference');
        await request.drain<void>();

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'text': '   - Голосовая команда принята. Субтитры сделал DimaTorzok   ',
          }));
        await request.response.close();
      });

      try {
        final client = HttpClient();
        final req = await client.post('127.0.0.1', port, '/inference');
        req.headers.contentType = ContentType.parse('multipart/form-data; boundary=boundary');
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        client.close();

        final data = jsonDecode(body);
        final cleaned = tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
        expect(cleaned, 'Голосовая команда принята.');
      } finally {
        await server.close(force: true);
      }
    });

    test('Real whisper-server integration: launches model server if available and verifies', () async {
      final models = findModels();
      final serverExe = findWhisperServer();
      if (serverExe == null || models.isEmpty) {
        // Skip gracefully in environments without downloaded whisper models/binaries
        return;
      }

      final wav = '${Directory.systemTemp.path}/tsukiko_hallucination_test.wav';
      await os.toWav('/System/Library/Sounds/Ping.aiff', wav);

      await withTempSupportDir('tsukiko-real-server-hallucination', () async {
        final isolatedModel = os.join(os.modelsDir, os.basename(models.first));
        Link(isolatedModel).createSync(models.first);
        final server = WhisperServer(idleTimeout: const Duration(seconds: 30));
        try {
          await server.ensureUp(
            RunOptions(model: isolatedModel, lang: 'ru', threads: 4, punctuate: false),
          );
          expect(server.up, isTrue);
          expect(await server.waitReady(timeout: const Duration(seconds: 60)), isTrue);
          expect(await server.footprintMb(), greaterThan(100));

          final recognized = await server.transcribe(wav, lang: 'ru');
          expect(recognized, isNotNull);
          // Whatever text is recognized by whisper on short ping sound
          // MUST be properly sanitized through tidyDictated without crashing
          final sanitized = tidyDictated(recognized!);
          expect(sanitized, isNot(contains('DimaTorzok')));
          expect(sanitized, isNot(contains('Спасибо за просмотр')));
          expect(sanitized, isNot(contains('Продолжение следует')));
        } finally {
          await server.shutdown();
        }
      });
    });
  });
}
