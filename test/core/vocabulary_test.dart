import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/vocabulary.dart';

void main() {
  group('Equivalence Classes (Classes 1-10)', () {
    test('Class 1: Pure acoustic hints (no replacement, hint-only)', () {
      const hint1 = VocabularyItem(id: 'h1', phrase: 'TypeScript');
      const hint2 = VocabularyItem(
        id: 'h2',
        phrase: 'Кубернетис',
        replacement: '',
      );

      expect(hint1.isHintOnly, isTrue);
      expect(hint1.isReplacement, isFalse);
      expect(hint1.type, VocabularyType.hint);
      expect(hint1.usable, isTrue);

      expect(hint2.isHintOnly, isTrue);
      expect(hint2.isReplacement, isFalse);
      expect(hint2.type, VocabularyType.hint);
      expect(hint2.usable, isTrue);

      // In promptWithVocabulary, pure acoustic hints are included to condition the model
      final prompt = promptWithVocabulary('Базовый текст', [hint1, hint2]);
      expect(prompt, 'Базовый текст, TypeScript, Кубернетис');

      // In applyVocabularyReplacements, pure hints do NOT change the recognized text
      final result = applyVocabularyReplacements(
        'Мы развернули Кубернетис и пишем на TypeScript.',
        [hint1, hint2],
      );
      expect(
        result.text,
        'Мы развернули Кубернетис и пишем на TypeScript.',
      );
      expect(result.replacements, isEmpty);
    });

    test('Class 2: Simple case replacements (мак -> Mac, сдк -> SDK)', () {
      const itemMac = VocabularyItem(
        id: 'r1',
        phrase: 'мак',
        replacement: 'Mac',
      );
      const itemSdk = VocabularyItem(
        id: 'r2',
        phrase: 'сдк',
        replacement: 'SDK',
      );

      expect(itemMac.isReplacement, isTrue);
      expect(itemMac.type, VocabularyType.replacement);
      expect(itemSdk.isReplacement, isTrue);

      // Included in initial prompt
      final prompt = promptWithVocabulary('', [itemMac, itemSdk]);
      expect(prompt, 'мак, сдк');

      // Replaces exact case triggers
      final result = applyVocabularyReplacements(
        'Я купил мак и скачал сдк для разработки.',
        [itemMac, itemSdk],
      );
      expect(result.text, 'Я купил Mac и скачал SDK для разработки.');
      expect(result.replacements.length, 2);
      expect(result.replacements[0].original, 'мак');
      expect(result.replacements[0].replacement, 'Mac');
      expect(result.replacements[1].original, 'сдк');
      expect(result.replacements[1].replacement, 'SDK');
    });

    test(
      'Class 3: Cross-language Cyrillic-to-Latin multi-word & compound replacements',
      () {
        const item1 = VocabularyItem(
          id: 'c1',
          phrase: 'юскейс',
          replacement: 'Use Case',
        );
        const item2 = VocabularyItem(
          id: 'c2',
          phrase: 'супервиспер',
          replacement: 'SuperWhisper',
        );
        const item3 = VocabularyItem(
          id: 'c3',
          phrase: 'пул реквест',
          replacement: 'Pull Request',
        );

        final result = applyVocabularyReplacements(
          'Создай пул реквест на этот юскейс в супервиспер.',
          [item1, item2, item3],
        );

        expect(
          result.text,
          'Создай Pull Request на этот Use Case в SuperWhisper.',
        );
        expect(result.replacements.length, 3);
        expect(result.replacements[0].replacement, 'Pull Request');
        expect(result.replacements[1].replacement, 'Use Case');
        expect(result.replacements[2].replacement, 'SuperWhisper');
      },
    );

    test('Class 4: Suffix/prefix substring boundaries (word boundary verification)', () {
      const itemAddress = VocabularyItem(
        id: 'wb1',
        phrase: 'адрес',
        replacement: 'address',
      );
      const itemMac = VocabularyItem(
        id: 'wb2',
        phrase: 'mac',
        replacement: 'Mac',
      );
      const itemCat = VocabularyItem(
        id: 'wb3',
        phrase: 'кот',
        replacement: 'cat',
      );

      // Must NOT replace inside longer words:
      // «адресат», «безадресный», «machine», «smack», «котик», «бойкот»
      final text =
          'Мой адресат получил безадресный пакет. The machine was in a smackdown. Наш котик объявил бойкот.';
      final result = applyVocabularyReplacements(text, [
        itemAddress,
        itemMac,
        itemCat,
      ]);

      expect(result.text, text);
      expect(result.replacements, isEmpty);

      // Must replace standalone words at boundaries
      final validText = 'Мой адрес записан. A mac was found. Наш кот спит.';
      final validResult = applyVocabularyReplacements(validText, [
        itemAddress,
        itemMac,
        itemCat,
      ]);

      expect(validResult.text, 'Мой address записан. A Mac was found. Наш cat спит.');
      expect(validResult.replacements.length, 3);
    });

    test('Class 5: Case sensitivity variations (trigger phrase in diverse cases)', () {
      const item = VocabularyItem(
        id: 'case1',
        phrase: 'юскейс',
        replacement: 'Use Case',
      );

      // Lowercase, UPPERCASE, TitleCase, mixed case
      final text = 'юскейс, ЮСКЕЙС, Юскейс, юсКЕЙС';
      final result = applyVocabularyReplacements(text, [item]);

      expect(result.text, 'Use Case, Use Case, Use Case, Use Case');
      expect(result.replacements.length, 4);
      expect(result.replacements[0].original, 'юскейс');
      expect(result.replacements[1].original, 'ЮСКЕЙС');
      expect(result.replacements[2].original, 'Юскейс');
      expect(result.replacements[3].original, 'юсКЕЙС');
      for (final r in result.replacements) {
        expect(r.replacement, 'Use Case');
      }
    });

    test('Class 6: Special punctuation boundaries', () {
      const item = VocabularyItem(
        id: 'punc1',
        phrase: 'юскейс',
        replacement: 'Use Case',
      );

      final inputs = [
        '«юскейс»',
        '“юскейс”',
        '"юскейс"',
        '(юскейс)',
        '[юскейс]',
        '{юскейс}',
        'юскейс,',
        'юскейс.',
        'юскейс:',
        'юскейс;',
        'юскейс!',
        'юскейс?',
        'юскейс…',
        'юскейс — круто',
      ];

      final expected = [
        '«Use Case»',
        '“Use Case”',
        '"Use Case"',
        '(Use Case)',
        '[Use Case]',
        '{Use Case}',
        'Use Case,',
        'Use Case.',
        'Use Case:',
        'Use Case;',
        'Use Case!',
        'Use Case?',
        'Use Case…',
        'Use Case — круто',
      ];

      for (var i = 0; i < inputs.length; i++) {
        final res = applyVocabularyReplacements(inputs[i], [item]);
        expect(res.text, expected[i], reason: 'Failed for input: ${inputs[i]}');
        expect(res.replacements.length, 1);
        expect(res.replacements.first.original, 'юскейс');
      }
    });

    test('Class 7: Multiple overlapping rules (longest phrase priority)', () {
      const items = [
        VocabularyItem(id: '1', phrase: 'адрес', replacement: 'ул. Ленина'),
        VocabularyItem(
          id: '2',
          phrase: 'адрес офиса',
          replacement: 'Минск, Немига, 1',
        ),
        VocabularyItem(
          id: '3',
          phrase: 'адрес офиса компании',
          replacement: 'Штаб-квартира',
        ),
      ];

      // Longest phrase "адрес офиса компании" wins over "адрес офиса" and "адрес"
      final res1 = applyVocabularyReplacements(
        'Сохрани адрес офиса компании для курьера.',
        items,
      );
      expect(res1.text, 'Сохрани Штаб-квартира для курьера.');
      expect(res1.replacements.single.original, 'адрес офиса компании');

      // Medium phrase "адрес офиса" wins over "адрес"
      final res2 = applyVocabularyReplacements(
        'Сохрани адрес офиса для курьера.',
        items,
      );
      expect(res2.text, 'Сохрани Минск, Немига, 1 для курьера.');
      expect(res2.replacements.single.original, 'адрес офиса');

      // Short phrase "адрес" triggers when others do not match
      final res3 = applyVocabularyReplacements(
        'Сохрани адрес для курьера.',
        items,
      );
      expect(res3.text, 'Сохрани ул. Ленина для курьера.');
      expect(res3.replacements.single.original, 'адрес');
    });

    test('Class 8: Disabled items (enabled = false)', () {
      const activeHint = VocabularyItem(id: '1', phrase: 'Flutter');
      const disabledHint = VocabularyItem(
        id: '2',
        phrase: 'React',
        enabled: false,
      );
      const activeRep = VocabularyItem(
        id: '3',
        phrase: 'мак',
        replacement: 'Mac',
      );
      const disabledRep = VocabularyItem(
        id: '4',
        phrase: 'винда',
        replacement: 'Windows',
        enabled: false,
      );

      final items = [activeHint, disabledHint, activeRep, disabledRep];

      // In promptWithVocabulary, disabled items are omitted
      final prompt = promptWithVocabulary('Инструменты', items);
      expect(prompt, contains('Flutter'));
      expect(prompt, contains('мак'));
      expect(prompt, isNot(contains('React')));
      expect(prompt, isNot(contains('винда')));

      // In applyVocabularyReplacements, disabled items are not substituted
      final res = applyVocabularyReplacements(
        'Я выбрал мак и Flutter, а винда и React мне не нужны.',
        items,
      );
      expect(
        res.text,
        'Я выбрал Mac и Flutter, а винда и React мне не нужны.',
      );
      expect(res.replacements.length, 1);
      expect(res.replacements.single.original, 'мак');
    });

    test('Class 9: Token budgeting, truncation and formatting', () {
      final items = [
        const VocabularyItem(id: '1', phrase: 'Альфа'),
        const VocabularyItem(id: '2', phrase: 'Бета'),
        const VocabularyItem(id: '3', phrase: 'Гамма'),
      ];

      // Base prompt punctuation formatting
      expect(
        promptWithVocabulary('Привет.', items),
        'Привет. Альфа, Бета, Гамма',
      );
      expect(
        promptWithVocabulary('Внимание!', items),
        'Внимание! Альфа, Бета, Гамма',
      );
      expect(
        promptWithVocabulary('Вопрос?', items),
        'Вопрос? Альфа, Бета, Гамма',
      );
      expect(
        promptWithVocabulary('Список:', items),
        'Список: Альфа, Бета, Гамма',
      );
      expect(
        promptWithVocabulary('И так далее…', items),
        'И так далее… Альфа, Бета, Гамма',
      );
      expect(
        promptWithVocabulary('База', items),
        'База, Альфа, Бета, Гамма',
      );

      // Token estimation
      final emptyEst = estimateVocabularyTokens(const []);
      expect(emptyEst, 0);

      final singleEst = estimateVocabularyTokens([
        const VocabularyItem(id: '1', phrase: 'Тест'),
      ]);
      expect(singleEst, greaterThan(0));

      // Token truncation with strict limit
      final longList = List.generate(
        100,
        (i) => VocabularyItem(
          id: 'item_$i',
          phrase: 'ДлинныйТерминНомер$i',
        ),
      );

      final truncated = promptWithVocabulary(
        '',
        longList,
        maxEstimatedTokens: 50,
      );
      expect((truncated.length / 3.8), lessThanOrEqualTo(55));
    });

    test('Class 10: Migration, backward compatibility, and serialization', () {
      // 1. JSON round-tripping for VocabularyItem
      final now = DateTime(2026, 9, 18, 15, 30);
      final item = VocabularyItem(
        id: 'full_item',
        phrase: 'Термин',
        replacement: 'Term',
        enabled: false,
        createdAt: now,
      );
      final json = item.toJson();
      final restored = VocabularyItem.fromJson(json);
      expect(restored, equals(item));
      expect(restored!.createdAt, equals(now));

      // 2. Vocabulary list round-tripping
      final listJson = [
        item.toJson(),
        {'id': 'item2', 'phrase': 'Второй', 'replacement': ''},
        {'invalid': 123}, // Malformed
        null,
      ];
      final list = vocabularyFromJson(listJson);
      expect(list.length, 2);
      expect(list[0].id, 'full_item');
      expect(list[1].id, 'item2');

      // 3. TextCommand interop
      final cmd = item.toTextCommand();
      expect(cmd.phrase, 'Термин');
      expect(cmd.replacement, 'Term');

      final fromCmd = VocabularyItem.fromTextCommand(cmd, id: 'converted');
      expect(fromCmd.id, 'converted');
      expect(fromCmd.phrase, 'Термин');
      expect(fromCmd.replacement, 'Term');
      expect(fromCmd.enabled, isTrue);

      // 4. loadAndMigrateVocabulary: prefers 'vocabulary' if present
      final settingsModern = {
        'vocabulary': [
          {'id': 'v1', 'phrase': 'Первый', 'replacement': 'First'},
        ],
        'textCommands': [
          {'phrase': 'старый', 'replacement': 'old'},
        ],
        'prompt': 'старая подсказка',
      };
      final migratedModern = loadAndMigrateVocabulary(settingsModern);
      expect(migratedModern.length, 1);
      expect(migratedModern.single.id, 'v1');
      expect(migratedModern.single.phrase, 'Первый');

      // 5. loadAndMigrateVocabulary: migrates legacy textCommands and prompt if vocabulary missing
      final settingsLegacy = {
        'textCommands': [
          {'phrase': 'адрес офиса', 'replacement': 'Минск'},
          {'phrase': '   ', 'replacement': 'пусто'}, // unusable, should be skipped
        ],
        'prompt': 'Kubernetes, Docker; Helm\nPodman, Минск, адрес офиса',
      };
      final migratedLegacy = loadAndMigrateVocabulary(settingsLegacy);

      // 'адрес офиса' is in textCommands, so prompt's 'адрес офиса' shouldn't duplicate
      expect(migratedLegacy.any((i) => i.phrase == 'адрес офиса' && i.isReplacement), isTrue);
      expect(migratedLegacy.any((i) => i.phrase == 'Kubernetes' && i.isHintOnly), isTrue);
      expect(migratedLegacy.any((i) => i.phrase == 'Docker' && i.isHintOnly), isTrue);
      expect(migratedLegacy.any((i) => i.phrase == 'Helm' && i.isHintOnly), isTrue);
      expect(migratedLegacy.any((i) => i.phrase == 'Podman' && i.isHintOnly), isTrue);

      // Total count: 1 replacement + 5 hints = 6 items
      expect(migratedLegacy.length, 6);
    });
  });

  group('Boundary Value Analysis (Boundaries 1-6)', () {
    test('Boundary 1: Phrase length & content (empty, whitespace, trimming)', () {
      // Empty phrase
      const empty = VocabularyItem(id: 'b1_1', phrase: '');
      expect(empty.usable, isFalse);
      expect(VocabularyItem.fromJson({'id': 'b1_1', 'phrase': ''}), isNull);

      // Whitespace-only phrase
      const spaces = VocabularyItem(id: 'b1_2', phrase: '   \t\n  ');
      expect(spaces.usable, isFalse);
      expect(VocabularyItem.fromJson({'id': 'b1_2', 'phrase': '   '}), isNull);

      // Trimming behavior: phrase with leading/trailing spaces
      const untrimmed = VocabularyItem(
        id: 'b1_3',
        phrase: '  мак  ',
        replacement: '  Mac  ',
      );
      expect(untrimmed.usable, isTrue);

      final prompt = promptWithVocabulary('', [untrimmed]);
      expect(prompt, 'мак');

      final result = applyVocabularyReplacements('Купил мак.', [untrimmed]);
      expect(result.text, 'Купил   Mac  .');
    });

    test('Boundary 2: Replacement state variations (empty vs whitespace vs non-empty)', () {
      const hintDefault = VocabularyItem(id: 'b2_1', phrase: 'Go');
      const hintEmpty = VocabularyItem(
        id: 'b2_2',
        phrase: 'Rust',
        replacement: '',
      );
      const hintWhitespace = VocabularyItem(
        id: 'b2_3',
        phrase: 'Zig',
        replacement: '   ',
      );
      const actualReplacement = VocabularyItem(
        id: 'b2_4',
        phrase: 'Dart',
        replacement: 'Flutter',
      );

      expect(hintDefault.isHintOnly, isTrue);
      expect(hintDefault.isReplacement, isFalse);

      expect(hintEmpty.isHintOnly, isTrue);
      expect(hintEmpty.isReplacement, isFalse);

      // Whitespace-only replacement is treated as hint-only
      expect(hintWhitespace.isHintOnly, isTrue);
      expect(hintWhitespace.isReplacement, isFalse);

      expect(actualReplacement.isHintOnly, isFalse);
      expect(actualReplacement.isReplacement, isTrue);

      final res = applyVocabularyReplacements(
        'Go, Rust, Zig and Dart',
        [hintDefault, hintEmpty, hintWhitespace, actualReplacement],
      );
      expect(res.text, 'Go, Rust, Zig and Flutter');
    });

    test('Boundary 3: Length extremes (single-character and huge phrases)', () {
      // Single character Cyrillic and Latin
      const singleCyr = VocabularyItem(
        id: 'b3_1',
        phrase: 'я',
        replacement: 'Я (местоимение)',
      );
      const singleLat = VocabularyItem(
        id: 'b3_2',
        phrase: 'a',
        replacement: 'one',
      );

      // Must not match inside words like «маяк» or «cat»
      final text = 'маяк cat я a';
      final res = applyVocabularyReplacements(text, [singleCyr, singleLat]);
      expect(res.text, 'маяк cat Я (местоимение) one');

      // Extremely long phrase (500+ characters)
      final longPhrase = 'ДлинноеСлово' * 40;
      final longReplacement = 'Замена' * 40;
      final longItem = VocabularyItem(
        id: 'b3_3',
        phrase: longPhrase,
        replacement: longReplacement,
      );

      final longRes = applyVocabularyReplacements(
        'Начало $longPhrase конец.',
        [longItem],
      );
      expect(longRes.text, 'Начало $longReplacement конец.');
      expect(longRes.replacements.single.original, longPhrase);
    });

    test(r'Boundary 4: Regex metacharacters and special symbols (*, +, ?, ^, $, etc.)', () {
      // If regex characters are mistakenly evaluated as regexes, this would throw FormatException
      const itemCpp = VocabularyItem(
        id: 'b4_1',
        phrase: 'C++',
        replacement: 'CPP',
      );
      const itemPrice = VocabularyItem(
        id: 'b4_2',
        phrase: r'цена $100',
        replacement: 'сто долларов',
      );
      const itemRegexChars = VocabularyItem(
        id: 'b4_3',
        phrase: r'a*b+c?d^e[f]\g(h).i',
        replacement: 'special_result',
      );
      const itemRepGroup = VocabularyItem(
        id: 'b4_4',
        phrase: 'доллар',
        replacement: r'$1 и \n и &',
      );

      final res1 = applyVocabularyReplacements('Я пишу на C++ сегодня.', [itemCpp]);
      expect(res1.text, 'Я пишу на CPP сегодня.');

      final res2 = applyVocabularyReplacements(
        r'Какова цена $100 сейчас?',
        [itemPrice],
      );
      expect(res2.text, 'Какова сто долларов сейчас?');

      final res3 = applyVocabularyReplacements(
        r'Вот a*b+c?d^e[f]\g(h).i тест.',
        [itemRegexChars],
      );
      expect(res3.text, 'Вот special_result тест.');

      final res4 = applyVocabularyReplacements('Один доллар остался.', [itemRepGroup]);
      expect(res4.text, r'Один $1 и \n и & остался.');
    });

    test('Boundary 5: Token budget boundaries (0, 199, 200, 201, 500)', () {
      // 0 tokens
      expect(estimateVocabularyTokens([]), 0);
      expect(estimateVocabularyTokens([], basePrompt: ''), 0);

      // Boundary around 200 tokens
      // 200 tokens * 3.8 chars/token ≈ 760 chars
      // We test that promptWithVocabulary strictly respects maxEstimatedTokens
      final itemTokens = [
        const VocabularyItem(id: '1', phrase: 'Слово1'),
        const VocabularyItem(id: '2', phrase: 'Слово2'),
      ];

      final prompt200 = promptWithVocabulary('', itemTokens, maxEstimatedTokens: 200);
      expect(prompt200, 'Слово1, Слово2');

      final promptSmall = promptWithVocabulary('', itemTokens, maxEstimatedTokens: 1);
      // 'Слово1' length is 6 -> 6 / 3.8 = 1.57 > 1 -> should not fit even the first word
      expect(promptSmall, '');

      final promptJustFits = promptWithVocabulary('', itemTokens, maxEstimatedTokens: 2);
      // 'Слово1' fits (1.57 <= 2), but ', Слово2' (6 + 8 = 14 / 3.8 = 3.68 > 2) does not
      expect(promptJustFits, 'Слово1');

      // 500 tokens budget
      final prompt500 = promptWithVocabulary('', itemTokens, maxEstimatedTokens: 500);
      expect(prompt500, 'Слово1, Слово2');
    });

    test('Boundary 6: Collection boundaries (empty list, single item, multiple items)', () {
      // 0 items
      expect(promptWithVocabulary('База', []), 'База');
      final res0 = applyVocabularyReplacements('Текст', []);
      expect(res0.text, 'Текст');
      expect(res0.replacements, isEmpty);

      // 1 item
      final res1 = applyVocabularyReplacements('Текст мак', [
        const VocabularyItem(id: '1', phrase: 'мак', replacement: 'Mac'),
      ]);
      expect(res1.text, 'Текст Mac');

      // Multiple items
      final resMulti = applyVocabularyReplacements('мак и сдк', [
        const VocabularyItem(id: '1', phrase: 'мак', replacement: 'Mac'),
        const VocabularyItem(id: '2', phrase: 'сдк', replacement: 'SDK'),
      ]);
      expect(resMulti.text, 'Mac и SDK');
    });
  });
}
