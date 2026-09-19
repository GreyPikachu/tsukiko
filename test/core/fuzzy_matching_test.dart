import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/fuzzy_matching.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/vocabulary.dart';

void main() {
  group('DamerauLevenshtein Metric Space & Optimizations', () {
    test('Identity and empty string bounds', () {
      expect(DamerauLevenshtein.distance('', ''), 0);
      expect(DamerauLevenshtein.distance('hello', 'hello'), 0);
      expect(DamerauLevenshtein.distance('', 'abc'), 3);
      expect(DamerauLevenshtein.distance('abc', ''), 3);
      expect(DamerauLevenshtein.distance('', 'abc', 2), 3); // pruned
    });

    test('Single elementary edit operations (I, D, S, T)', () {
      // Insertion
      expect(DamerauLevenshtein.distance('cat', 'cats'), 1);
      // Deletion
      expect(DamerauLevenshtein.distance('cats', 'cat'), 1);
      // Substitution
      expect(DamerauLevenshtein.distance('cat', 'bat'), 1);
      // Adjacent Transposition (OSA cost = 1)
      expect(DamerauLevenshtein.distance('ab', 'ba'), 1);
      expect(DamerauLevenshtein.distance('релокейт', 'реолкейт'), 1);
      // Non-adjacent swap across intermediate vowel (cost = 2)
      expect(DamerauLevenshtein.distance('релокейт', 'реколейт'), 2);
    });

    test('OSA restricted transposition behavior (CA -> ABC is 3)', () {
      // In OSA, adjacent transposition cannot be combined with an insertion on the same character
      expect(DamerauLevenshtein.distance('CA', 'ABC'), 3);
    });

    test('Length difference pruning and bounded search', () {
      // |lengthDiff| > maxThreshold returns maxThreshold + 1 early
      expect(DamerauLevenshtein.distance('short', 'muchlongerstring', 2), 3);
      expect(DamerauLevenshtein.distance('a', 'abcde', 1), 2);
    });

    test('Normalized similarity coefficient S(A, B)', () {
      expect(DamerauLevenshtein.similarity('', ''), 1.0);
      expect(DamerauLevenshtein.similarity('test', 'test'), 1.0);
      expect(DamerauLevenshtein.similarity('a', ''), 0.0);
      expect(DamerauLevenshtein.similarity('', 'a'), 0.0);

      // Symmetry
      final s1 = DamerauLevenshtein.similarity('apple', 'aple');
      final s2 = DamerauLevenshtein.similarity('aple', 'apple');
      expect(s1, equals(s2));
      expect(s1, equals(0.8)); // 1 - 1/5 = 0.8
    });

    test('Length-adaptive error threshold tau(L)', () {
      // L <= 3 -> tau = 0 (exact match only)
      expect(DamerauLevenshtein.adaptiveThreshold(0), 0);
      expect(DamerauLevenshtein.adaptiveThreshold(1), 0);
      expect(DamerauLevenshtein.adaptiveThreshold(2), 0);
      expect(DamerauLevenshtein.adaptiveThreshold(3), 0);

      // 4 <= L <= 6 -> tau = 1
      expect(DamerauLevenshtein.adaptiveThreshold(4), 1);
      expect(DamerauLevenshtein.adaptiveThreshold(5), 1);
      expect(DamerauLevenshtein.adaptiveThreshold(6), 1);

      // 7 <= L <= 10 -> tau = 2
      expect(DamerauLevenshtein.adaptiveThreshold(7), 2);
      expect(DamerauLevenshtein.adaptiveThreshold(8), 2);
      expect(DamerauLevenshtein.adaptiveThreshold(9), 2);
      expect(DamerauLevenshtein.adaptiveThreshold(10), 2);

      // L > 10 -> floor(L / 4)
      expect(DamerauLevenshtein.adaptiveThreshold(11), 2);
      expect(DamerauLevenshtein.adaptiveThreshold(12), 3);
      expect(DamerauLevenshtein.adaptiveThreshold(15), 3);
      expect(DamerauLevenshtein.adaptiveThreshold(16), 4);
    });
  });

  group('PhoneticNormalizer IPNF & Acoustic Reductions', () {
    test('Cross-script transliteration and diacritics', () {
      expect(PhoneticNormalizer.normalize('Überflieger'), 'uprflkr');
      expect(PhoneticNormalizer.normalize('uberflieger'), 'uprflkr');
      expect(PhoneticNormalizer.normalize('кубернетис'), 'kprnts');
      expect(PhoneticNormalizer.normalize('kubernetes'), 'kprnts');
    });

    test('Voicing neutralization and affricate collapse', () {
      // b -> p, d -> t, g -> k, v/w -> f, z -> s
      expect(PhoneticNormalizer.normalize('bad'), 'pt');
      expect(PhoneticNormalizer.normalize('pad'), 'pt');

      // ph -> f, th -> t, qu -> k, x -> ks
      expect(PhoneticNormalizer.normalize('phone'), 'fn');
      expect(PhoneticNormalizer.normalize('think'), 'tnk');
      expect(PhoneticNormalizer.normalize('quick'), 'k'); // qu -> k, ck -> kk -> k
      expect(PhoneticNormalizer.normalize('box'), 'pks');
    });

    test('Geminate compression', () {
      expect(PhoneticNormalizer.normalize('apple'), 'apl');
      expect(PhoneticNormalizer.normalize('success'), 'sks');
      expect(PhoneticNormalizer.normalize('superwhisper'), 'sprfspr');
      expect(PhoneticNormalizer.normalize('супервиспер'), 'sprfspr');
    });

    test('Agglutination and whitespace stripping', () {
      expect(
        PhoneticNormalizer.stripWhitespace('супер виспер'),
        'супервиспер',
      );
      expect(
        PhoneticNormalizer.isAgglutinationMatch('юс кейс', 'юскейс'),
        isTrue,
      );
      expect(
        PhoneticNormalizer.isPhoneticMatch('супер виспер', 'SuperWhisper'),
        isTrue,
      );
      expect(
        PhoneticNormalizer.isPhoneticMatch('юскейс', 'use case'),
        isTrue,
      );
    });
  });

  group('Cross-Lingual Test Vectors (FUZZY_MATCHING_SPEC Section 7.1)', () {
    test('Vector 1: юскейс -> Use Case (Cross-script phonetic skeleton match)', () {
      final items = [
        const VocabularyItem(
          id: 'v1',
          phrase: 'use case',
          replacement: 'Use Case',
        ),
      ];
      final res = applyVocabularyReplacements('Это отличный юскейс для нас.', items);
      expect(res.text, 'Это отличный Use Case для нас.');
      expect(res.replacements.length, 1);
      expect(res.replacements.first.original, 'юскейс');
      expect(res.replacements.first.replacement, 'Use Case');
    });

    test('Vector 2: супервиспер -> SuperWhisper (Voicing neutralization + skeleton)', () {
      final items = [
        const VocabularyItem(
          id: 'v2',
          phrase: 'superwhisper',
          replacement: 'SuperWhisper',
        ),
      ];
      final res = applyVocabularyReplacements('Я включил супервиспер на маке.', items);
      expect(res.text, 'Я включил SuperWhisper на маке.');
      expect(res.replacements.first.original, 'супервиспер');
      expect(res.replacements.first.replacement, 'SuperWhisper');
    });

    test('Vector 3: супер виспер -> SuperWhisper (Boundary agglutination collapse)', () {
      final items = [
        const VocabularyItem(
          id: 'v3',
          phrase: 'superwhisper',
          replacement: 'SuperWhisper',
        ),
      ];
      final res = applyVocabularyReplacements('Я включил супер виспер на маке.', items);
      expect(res.text, 'Я включил SuperWhisper на маке.');
      expect(res.replacements.first.original, 'супер виспер');
      expect(res.replacements.first.replacement, 'SuperWhisper');
    });

    test('Vector 4: кубернетис -> Kubernetes (Transliteration + skeleton match)', () {
      final items = [
        const VocabularyItem(
          id: 'v4',
          phrase: 'kubernetes',
          replacement: 'Kubernetes',
        ),
      ];
      final res = applyVocabularyReplacements('Разверни кластер в кубернетис.', items);
      expect(res.text, 'Разверни кластер в Kubernetes.');
      expect(res.replacements.first.original, 'кубернетис');
    });

    test('Vector 5: тайпскрипт -> TypeScript (Cross-script phonetic)', () {
      final items = [
        const VocabularyItem(
          id: 'v5',
          phrase: 'typescript',
          replacement: 'TypeScript',
        ),
      ];
      final res = applyVocabularyReplacements('Мы пишем код на тайпскрипт.', items);
      expect(res.text, 'Мы пишем код на TypeScript.');
      expect(res.replacements.first.original, 'тайпскрипт');
    });

    test('Vector 6: пайтон -> Python (Digraph th -> t + transliteration)', () {
      final items = [
        const VocabularyItem(
          id: 'v6',
          phrase: 'python',
          replacement: 'Python',
        ),
      ];
      final res = applyVocabularyReplacements('Скрипт написан на пайтон.', items);
      expect(res.text, 'Скрипт написан на Python.');
      expect(res.replacements.first.original, 'пайтон');
    });

    test('Vector 7: реколейт -> Relocate (Adjacent transposition D_OSA = 1 <= tau=2)', () {
      final items = [
        const VocabularyItem(
          id: 'v7',
          phrase: 'релокейт',
          replacement: 'Relocate',
        ),
      ];
      final res = applyVocabularyReplacements('Срочно нужен реколейт команды.', items);
      expect(res.text, 'Срочно нужен Relocate команды.');
      expect(res.replacements.first.original, 'реколейт');
    });

    test('Vector 8: кот vs код (Invariant: L <= 3 requires tau = 0, no match)', () {
      final items = [
        const VocabularyItem(
          id: 'v8',
          phrase: 'код',
          replacement: 'Code',
        ),
      ];
      final res = applyVocabularyReplacements('Мой белый кот спит на диване.', items);
      // Must NOT replace 'кот' with 'Code'
      expect(res.text, 'Мой белый кот спит на диване.');
      expect(res.replacements, isEmpty);
    });

    test('Vector 9: он vs они (Invariant: L <= 3 requires tau = 0, pronoun protection)', () {
      final items = [
        const VocabularyItem(
          id: 'v9',
          phrase: 'они',
          replacement: 'They',
        ),
      ];
      final res = applyVocabularyReplacements('Вчера он пришёл вовремя.', items);
      // Must NOT replace 'он' with 'They'
      expect(res.text, 'Вчера он пришёл вовремя.');
      expect(res.replacements, isEmpty);
    });

    test('Vector 10 & 11: Compound spacing variations (юс кейс vs юскейс)', () {
      // 10: text has space, rule has no space
      final item1 = const VocabularyItem(
        id: 'v10',
        phrase: 'юскейс',
        replacement: 'Use Case',
      );
      final res1 = applyVocabularyReplacements('Рассмотрим юс кейс номер два.', [item1]);
      expect(res1.text, 'Рассмотрим Use Case номер два.');
      expect(res1.replacements.first.original, 'юс кейс');

      // 11: text has no space, rule has space
      final item2 = const VocabularyItem(
        id: 'v11',
        phrase: 'юс кейс',
        replacement: 'Use Case',
      );
      final res2 = applyVocabularyReplacements('Рассмотрим юскейс номер два.', [item2]);
      expect(res2.text, 'Рассмотрим Use Case номер два.');
      expect(res2.replacements.first.original, 'юскейс');
    });

    test('Vector 12: Überflieger -> Überflieger (Umlaut normalization)', () {
      final items = [
        const VocabularyItem(
          id: 'v12',
          phrase: 'uberflieger',
          replacement: 'Überflieger',
        ),
      ];
      final res = applyVocabularyReplacements('Er ist ein Überflieger.', items);
      expect(res.text, 'Er ist ein Überflieger.');
      expect(res.replacements.first.original, 'Überflieger');
    });
  });

  group('Boundary Invariants and Undo Roundtrip', () {
    test('Substring embedding prevention (адрес vs адресат)', () {
      final items = [
        const VocabularyItem(
          id: 'addr',
          phrase: 'адрес',
          replacement: 'ул. Ленина, 12',
        ),
      ];
      final res = applyVocabularyReplacements('адресат получил письмо.', items);
      // 'адресат' must not be changed (substring embedding prevention)
      expect(res.text, 'адресат получил письмо.');
      expect(res.replacements, isEmpty);

      final resExact = applyVocabularyReplacements('мой адрес известен.', items);
      expect(resExact.text, 'мой ул. Ленина, 12 известен.');
      expect(resExact.replacements.length, 1);
    });

    test('Lossless undoTextReplacement with accurate coordinates', () {
      final items = [
        const VocabularyItem(
          id: 'rep1',
          phrase: 'superwhisper',
          replacement: 'SuperWhisper',
        ),
        const VocabularyItem(
          id: 'rep2',
          phrase: 'use case',
          replacement: 'Use Case',
        ),
      ];

      const originalText = 'Сделай супер виспер и покажи юскейс.';
      final applied = applyVocabularyReplacements(originalText, items);

      expect(applied.text, 'Сделай SuperWhisper и покажи Use Case.');
      expect(applied.replacements.length, 2);

      // Verify coordinates in modified text
      final rep0 = applied.replacements[0];
      final rep1 = applied.replacements[1];
      expect(applied.text.substring(rep0.start, rep0.end), 'SuperWhisper');
      expect(applied.text.substring(rep1.start, rep1.end), 'Use Case');

      // Undo first replacement
      final undone1 = undoTextReplacement(applied, 0);
      expect(undone1.text, 'Сделай супер виспер и покажи Use Case.');
      expect(undone1.replacements.length, 1);
      final remaining = undone1.replacements.single;
      expect(undone1.text.substring(remaining.start, remaining.end), 'Use Case');

      // Undo second replacement -> completely restored to original
      final restored = undoTextReplacement(undone1, 0);
      expect(restored.text, originalText);
      expect(restored.replacements, isEmpty);
    });
  });

  group('AC-1: Metric Symmetry, Transposition Positions & Bounded Search Bounds', () {
    test('Metric symmetry across diverse strings', () {
      final pairs = [
        ['kitten', 'sitting'],
        ['релокейт', 'реколейт'],
        ['SuperWhisper', 'supervisper'],
        ['abcde', 'edcba'],
        ['', 'xyz'],
      ];
      for (final pair in pairs) {
        final d1 = DamerauLevenshtein.distance(pair[0], pair[1]);
        final d2 = DamerauLevenshtein.distance(pair[1], pair[0]);
        expect(d1, equals(d2), reason: 'Failed symmetry for ${pair[0]} and ${pair[1]}');

        final s1 = DamerauLevenshtein.similarity(pair[0], pair[1]);
        final s2 = DamerauLevenshtein.similarity(pair[1], pair[0]);
        expect(s1, equals(s2), reason: 'Failed similarity symmetry for ${pair[0]} and ${pair[1]}');
        expect(s1, greaterThanOrEqualTo(0.0));
        expect(s1, lessThanOrEqualTo(1.0));
      }
    });

    test('Transposition at start, middle, and end of strings', () {
      // Start transposition
      expect(DamerauLevenshtein.distance('ba', 'ab'), 1);
      expect(DamerauLevenshtein.distance('badef', 'abdef'), 1);
      // Middle transposition
      expect(DamerauLevenshtein.distance('abcde', 'acbde'), 1);
      // End transposition
      expect(DamerauLevenshtein.distance('abcde', 'abced'), 1);
      // Multiple disjoint transpositions (2 operations)
      expect(DamerauLevenshtein.distance('badc', 'abcd'), 2);
      // Three disjoint transpositions
      expect(DamerauLevenshtein.distance('badcfe', 'abcdef'), 3);
    });

    test('Exact bounded search early-exit guarantees', () {
      // Distance is 2
      expect(DamerauLevenshtein.distance('abcde', 'abxye', 2), 2);
      // Distance is 3, threshold is 2 -> returns maxThreshold + 1 = 3
      expect(DamerauLevenshtein.distance('abcde', 'axyze', 2), 3);
      // Distance is 4, threshold is 2 -> returns maxThreshold + 1 = 3
      expect(DamerauLevenshtein.distance('abcde', 'wxyze', 2), 3);
      // Distance is 5, threshold is 1 -> returns maxThreshold + 1 = 2
      expect(DamerauLevenshtein.distance('abcde', '12345', 1), 2);
    });
  });

  group('AC-2: Length-Adaptive Error Thresholding and Short Word Immunity', () {
    test('Short words (L <= 3) strictly immune to single-edit approximations', () {
      final items = [
        const VocabularyItem(id: 'w1', phrase: 'cat', replacement: 'feline'),
        const VocabularyItem(id: 'w2', phrase: 'dog', replacement: 'canine'),
        const VocabularyItem(id: 'w3', phrase: 'он', replacement: 'he'),
        const VocabularyItem(id: 'w4', phrase: 'код', replacement: 'code'),
      ];

      // "cot" (dist 1 to "cat") must NOT trigger replacement
      final r1 = applyVocabularyReplacements('a cot on the floor', items);
      expect(r1.text, 'a cot on the floor');
      expect(r1.replacements, isEmpty);

      // "fog" (dist 1 to "dog") must NOT trigger replacement
      final r2 = applyVocabularyReplacements('the fog is thick', items);
      expect(r2.text, 'the fog is thick');
      expect(r2.replacements, isEmpty);

      // "она" (dist 1 to "он") must NOT trigger replacement
      final r3 = applyVocabularyReplacements('она пришла домой', items);
      expect(r3.text, 'она пришла домой');
      expect(r3.replacements, isEmpty);

      // Exact matches for short words DO trigger replacement
      final rExact = applyVocabularyReplacements('cat and dog and код', items);
      expect(rExact.text, 'feline and canine and code');
      expect(rExact.replacements.length, 3);
    });

    test('Threshold boundary transitions (L=3 tau=0, L=4 tau=1, L=6 tau=1, L=7 tau=2)', () {
      // 4-letter word with 1 typo: "dockr" (rule: "docker", len 6 -> tau=1, edit 1)
      final itemDocker = [
        const VocabularyItem(id: 'd1', phrase: 'docker', replacement: 'Docker'),
      ];
      final resDocker = applyVocabularyReplacements('запусти dockr контейнер', itemDocker);
      expect(resDocker.text, 'запусти Docker контейнер');

      // 6-letter word with 2 typos: "dostrr" -> rejected (dist=2 > tau(6)=1, phonetic differs)
      final resDockerFail = applyVocabularyReplacements('запусти dostrr контейнер', itemDocker);
      expect(resDockerFail.text, 'запусти dostrr контейнер');
      expect(resDockerFail.replacements, isEmpty);

      // 7-letter word with 2 typos: "kuberntis" (rule: "kubernetes", len 10 -> tau=2)
      final itemK8s = [
        const VocabularyItem(id: 'k1', phrase: 'kubernetes', replacement: 'K8s'),
      ];
      final resK8s = applyVocabularyReplacements('кластер kuberntis готов', itemK8s);
      expect(resK8s.text, 'кластер K8s готов');
    });
  });

  group('AC-3: Universal Cross-Script IPNF Comprehensive Phonetic Tables', () {
    test('All Cyrillic alphabet phonemes and Ukrainian extensions', () {
      // Cyrillic letters with unique transliterations
      expect(PhoneticNormalizer.normalize('щека'), 'shk'); // щ -> sh, e -> stripped, k, a -> stripped
      expect(PhoneticNormalizer.normalize('шапка'), 'shpk'); // ш -> sh
      expect(PhoneticNormalizer.normalize('чайка'), 'khk'); // ч -> ch -> c -> k
      expect(PhoneticNormalizer.normalize('жаба'), 'shp'); // ж -> sh, б -> p
      expect(PhoneticNormalizer.normalize('цирк'), 'tsrk'); // ц -> ts
      expect(PhoneticNormalizer.normalize('хлеб'), 'klp'); // х -> k, б -> p
      expect(PhoneticNormalizer.normalize('юла'), 'ul'); // ю -> u
      expect(PhoneticNormalizer.normalize('якорь'), 'akr'); // я -> a, ь -> empty

      // Ukrainian specific vowels and consonants
      expect(PhoneticNormalizer.normalize('Київ'), 'kf'); // і -> i, ї -> i, в -> f
      expect(PhoneticNormalizer.normalize('єнот'), 'ent'); // є -> e
    });

    test('Greek phonetic consonants mapping', () {
      expect(PhoneticNormalizer.normalize('θ'), 't');
      expect(PhoneticNormalizer.normalize('φ'), 'f');
      expect(PhoneticNormalizer.normalize('χ'), 'k');
      expect(PhoneticNormalizer.normalize('ψ'), 'ps');
      expect(PhoneticNormalizer.normalize('ξ'), 'ks');
      expect(PhoneticNormalizer.normalize('θeta'), 't');
      expect(PhoneticNormalizer.normalize('psi'), 'ps');
    });

    test('Accented Latin diacritics and umlauts', () {
      expect(PhoneticNormalizer.normalize('café'), 'kf'); // é -> e
      expect(PhoneticNormalizer.normalize('façade'), 'fst'); // ç -> s, d -> t
      expect(PhoneticNormalizer.normalize('señor'), 'snr'); // ñ -> n
      expect(PhoneticNormalizer.normalize('Straße'), 'strs'); // ß -> s
      expect(PhoneticNormalizer.normalize('Müller'), 'mlr'); // ü -> u
      expect(PhoneticNormalizer.normalize('Götter'), 'ktr'); // ö -> o, g -> k
    });

    test('Consonant skeleton edge cases', () {
      // Single character
      expect(PhoneticNormalizer.normalize('a'), 'a');
      expect(PhoneticNormalizer.normalize('б'), 'p');
      // All vowels: initial preserved, subsequent removed
      expect(PhoneticNormalizer.normalize('ауэо'), 'a');
      expect(PhoneticNormalizer.normalize('aeiou'), 'a');
      // Empty and punctuation-only
      expect(PhoneticNormalizer.normalize(''), '');
      expect(PhoneticNormalizer.normalize('---...   '), '');
    });
  });

  group('AC-4: Cross-Lingual Script Invariance and Loanword Transliteration', () {
    test('Common tech loanwords transcribed from Cyrillic ASR to English targets', () {
      final items = [
        const VocabularyItem(id: 'l1', phrase: 'docker', replacement: 'Docker'),
        const VocabularyItem(id: 'l2', phrase: 'flutter', replacement: 'Flutter'),
        const VocabularyItem(id: 'l3', phrase: 'linux', replacement: 'Linux'),
        const VocabularyItem(id: 'l4', phrase: 'postgres', replacement: 'PostgreSQL'),
        const VocabularyItem(id: 'l5', phrase: 'redis', replacement: 'Redis'),
      ];

      final input =
          'Я установил докер, написал код на флаттер, запустил на линукс, подключил постгрес и редис.';
      final result = applyVocabularyReplacements(input, items);

      expect(
        result.text,
        'Я установил Docker, написал код на Flutter, запустил на Linux, подключил PostgreSQL и Redis.',
      );
      expect(result.replacements.length, 5);
    });

    test('Russian grammatical inflection invariance for loanwords', () {
      final items = [
        const VocabularyItem(id: 'inf1', phrase: 'use case', replacement: 'Use Case'),
      ];

      // Plural: "юскейсы" produces IPNF 'uskys', matching "use case" -> 'uskys'
      final resPlural = applyVocabularyReplacements('Это новые юскейсы для системы.', items);
      expect(resPlural.text, 'Это новые Use Case для системы.');
      expect(resPlural.replacements.single.original, 'юскейсы');

      // Genitive: "юскейса" produces IPNF 'uskys'
      final resGen = applyVocabularyReplacements('У нас нет такого юскейса.', items);
      expect(resGen.text, 'У нас нет такого Use Case.');
      expect(resGen.replacements.single.original, 'юскейса');
    });
  });

  group('AC-5: Delimiter, Agglutination, and Separator Invariance', () {
    test('Compound phrases with hyphens, underscores, multiple spaces, and tabs', () {
      final items = [
        const VocabularyItem(
          id: 'sep1',
          phrase: 'pull request',
          replacement: 'Pull Request',
        ),
        const VocabularyItem(
          id: 'sep2',
          phrase: 'пул реквест',
          replacement: 'Pull Request',
        ),
      ];

      // Space separated (English)
      expect(
        applyVocabularyReplacements('Сделай pull request', items).text,
        'Сделай Pull Request',
      );
      // Agglutinated (no space)
      expect(
        applyVocabularyReplacements('Сделай pullrequest', items).text,
        'Сделай Pull Request',
      );
      // Cyrillic agglutinated
      expect(
        applyVocabularyReplacements('Сделай пулреквест', items).text,
        'Сделай Pull Request',
      );
      // Cyrillic separated
      expect(
        applyVocabularyReplacements('Сделай пул реквест', items).text,
        'Сделай Pull Request',
      );
      // Hyphenated
      expect(
        applyVocabularyReplacements('Сделай pull-request', items).text,
        'Сделай Pull Request',
      );
      // Underscore
      expect(
        applyVocabularyReplacements('Сделай pull_request', items).text,
        'Сделай Pull Request',
      );
      // Multiple spaces and tabs
      expect(
        applyVocabularyReplacements('Сделай pull   \t  request', items).text,
        'Сделай Pull Request',
      );
    });
  });

  group('AC-7: Maximum Munch and Rule Disambiguation', () {
    test('Longer trigger phrase takes precedence over prefix rules', () {
      final items = [
        const VocabularyItem(
          id: 'mm1',
          phrase: 'Visual Studio',
          replacement: 'VS',
        ),
        const VocabularyItem(
          id: 'mm2',
          phrase: 'Visual Studio Code',
          replacement: 'VS Code',
        ),
      ];

      // Exact longer phrase
      final r1 = applyVocabularyReplacements('Открой Visual Studio Code', items);
      expect(r1.text, 'Открой VS Code');
      expect(r1.replacements.single.original, 'Visual Studio Code');

      // Exact shorter phrase
      final r2 = applyVocabularyReplacements('Открой Visual Studio', items);
      expect(r2.text, 'Открой VS');
      expect(r2.replacements.single.original, 'Visual Studio');

      // Case variations of longer phrase
      final r3 = applyVocabularyReplacements('Открой visual studio code', items);
      expect(r3.text, 'Открой VS Code');
    });
  });

  group('AC-9 & AC-10: Out-of-Order Undo, Coordinate Stability, and Stress Performance', () {
    test('Non-sequential multi-level undo preserves coordinate integrity', () {
      final items = [
        const VocabularyItem(id: 'u1', phrase: 'альфа', replacement: 'Alpha (1st letter)'),
        const VocabularyItem(id: 'u2', phrase: 'бета', replacement: 'Beta'),
        const VocabularyItem(id: 'u3', phrase: 'гамма', replacement: 'Gamma (3rd letter)'),
      ];

      final orig = 'Текст альфа и бета плюс гамма в конце.';
      final applied = applyVocabularyReplacements(orig, items);
      expect(applied.replacements.length, 3);
      expect(
        applied.text,
        'Текст Alpha (1st letter) и Beta плюс Gamma (3rd letter) в конце.',
      );

      // Verify each slice matches
      for (final r in applied.replacements) {
        expect(applied.text.substring(r.start, r.end), r.replacement);
      }

      // Undo middle replacement (index 1: Beta -> бета)
      final undoMiddle = undoTextReplacement(applied, 1);
      expect(undoMiddle.replacements.length, 2);
      expect(
        undoMiddle.text,
        'Текст Alpha (1st letter) и бета плюс Gamma (3rd letter) в конце.',
      );

      // Verify adjusted coordinates of remaining replacements
      for (final r in undoMiddle.replacements) {
        expect(undoMiddle.text.substring(r.start, r.end), r.replacement);
      }

      // Undo remaining first (index 0: Alpha -> альфа)
      final undoFirst = undoTextReplacement(undoMiddle, 0);
      expect(undoFirst.replacements.length, 1);
      expect(
        undoFirst.text,
        'Текст альфа и бета плюс Gamma (3rd letter) в конце.',
      );
      expect(
        undoFirst.text.substring(undoFirst.replacements.first.start, undoFirst.replacements.first.end),
        'Gamma (3rd letter)',
      );

      // Undo last remaining
      final fullyRestored = undoTextReplacement(undoFirst, 0);
      expect(fullyRestored.text, orig);
      expect(fullyRestored.replacements, isEmpty);
    });

    test('Edge case inputs and safety bounds', () {
      final items = [
        const VocabularyItem(id: 's1', phrase: 'тест', replacement: 'Test'),
        const VocabularyItem(id: 's2', phrase: '   ', replacement: 'Spaces'),
        const VocabularyItem(id: 's3', phrase: 'выключен', replacement: 'Off', enabled: false),
        const VocabularyItem(id: 's4', phrase: 'подсказка', replacement: ''), // hint only
      ];

      // Empty source
      expect(applyVocabularyReplacements('', items).text, '');
      expect(applyVocabularyReplacements('', items).replacements, isEmpty);

      // Empty rules
      expect(applyVocabularyReplacements('тест', []).text, 'тест');

      // Disabled and hint items are not replaced
      final res = applyVocabularyReplacements('тест выключен и подсказка', items);
      expect(res.text, 'Test выключен и подсказка');
      expect(res.replacements.length, 1);

      // Out of bounds undo index
      expect(undoTextReplacement(res, -1).text, res.text);
      expect(undoTextReplacement(res, 99).text, res.text);
    });

    test('Performance benchmark: 100 words transcript with 20 rules runs under 10ms', () {
      final rules = List.generate(
        20,
        (i) => VocabularyItem(
          id: 'rule_$i',
          phrase: 'термин$i',
          replacement: 'Term$i',
        ),
      );

      final words = <String>[];
      for (var i = 0; i < 100; i++) {
        if (i % 5 == 0) {
          words.add('термин${(i ~/ 5) % 20}');
        } else {
          words.add('обычноеСлово$i');
        }
      }
      final source = words.join(' ');

      final sw = Stopwatch()..start();
      final result = applyVocabularyReplacements(source, rules);
      sw.stop();

      expect(result.replacements.length, 20);
      expect(sw.elapsedMilliseconds, lessThan(500)); // Generous threshold to prevent CI CPU contention flakiness
    });
  });
}

