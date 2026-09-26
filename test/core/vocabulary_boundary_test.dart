import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/vocabulary.dart';
import 'package:tsukiko/core/whisper.dart';

void main() {
  const entries = [
    VocabularyItem(id: 'fitu', phrase: 'FITU', replacement: 'ФИТУ'),
    VocabularyItem(id: 'bguir', phrase: 'БГУИР', replacement: 'БГУИР'),
  ];

  test('названия распознаются только как целые слова', () {
    const unrelated =
        'Профитура, полуфиту, фитушный, БГУИРовский, пробгуир, '
        'дебгуир, superFITUcase, фото, фигура и футурамо.';
    final result = applyVocabularyReplacements(unrelated, entries);
    expect(result.text, unrelated);
    expect(result.replacements, isEmpty);

    final spoken = applyVocabularyReplacements('Фиту и БГУИР.', entries);
    expect(spoken.text, 'ФИТУ и БГУИР.');
    expect(spoken.replacements, hasLength(1));
    expect(spoken.replacements.single.original, 'Фиту');
  });

  test('длинная подсказка не отрезает начало и не обрывает слово', () {
    final prompt = List.generate(100, (i) => 'Термин$i').join(', ');
    final bounded = promptWithVocabulary(
      prompt,
      const [],
      maxEstimatedTokens: 30,
    );
    expect(bounded, startsWith('Термин0'));
    expect(bounded, isNot(contains('Термин99')));
    expect(bounded.endsWith(','), isFalse);
    expect(
      estimateVocabularyTokens(const [], basePrompt: bounded),
      lessThanOrEqualTo(30),
    );
  });

  test(
    'словарь не подмешивается в подсказку модели, избегая галлюцинаций',
    () {
      final prompt = List.generate(100, (i) => 'Термин$i').join(', ');
      final bounded = promptWithVocabulary(prompt, const [
        VocabularyItem(id: 'fitu', phrase: 'ФИТУ', isPriority: true),
      ], maxEstimatedTokens: 30);
      expect(bounded, isNot(contains('ФИТУ')));
      expect(
        estimateVocabularyTokens(const [], basePrompt: bounded),
        0,
      );
    },
  );

  test('ограничение подсказки действует и при отключённом словаре', () {
    final prompt = List.generate(100, (i) => 'Термин$i').join(', ');
    final whisper = RunOptions(
      model: 'ggml-base.bin', lang: 'ru', threads: 4, prompt: prompt,
    );
    final nemo = RunOptions(
      model: 'nemotron.gguf', lang: 'ru', threads: 4, prompt: prompt,
    );
    expect(whisper.effectivePrompt, startsWith('Термин0'));
    expect(whisper.effectivePrompt, isNot(contains('Термин99')));
    expect(nemo.effectivePrompt, prompt);
  });
}
