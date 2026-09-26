import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';

import '../../support/fake_os.dart';

void main() {
  useTempSupportDir('tsukiko-speaker-profile-test');

  group('SpeakerProfile - cosineSimilarity', () {
    test('идентичные векторы дают сходство 1.0', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(SpeakerProfile.cosineSimilarity(a, b), closeTo(1.0, 0.0001));
    });

    test('коллинеарные векторы разной длины дают сходство 1.0', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([2.0, 4.0, 6.0]);
      expect(SpeakerProfile.cosineSimilarity(a, b), closeTo(1.0, 0.0001));
    });

    test('ортогональные векторы дают сходство 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(SpeakerProfile.cosineSimilarity(a, b), closeTo(0.0, 0.0001));
    });

    test('противоположные векторы дают сходство -1.0', () {
      final a = Float32List.fromList([1.0, 2.0]);
      final b = Float32List.fromList([-1.0, -2.0]);
      expect(SpeakerProfile.cosineSimilarity(a, b), closeTo(-1.0, 0.0001));
    });

    test('пустые векторы или разная размерность возвращают 0.0', () {
      final a = Float32List(0);
      final b = Float32List(0);
      expect(SpeakerProfile.cosineSimilarity(a, b), 0.0);

      final c = Float32List.fromList([1.0, 2.0]);
      final d = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(SpeakerProfile.cosineSimilarity(c, d), 0.0);
    });

    test('нулевой вектор возвращает 0.0 (деление на ноль безопасно)', () {
      final a = Float32List.fromList([0.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(SpeakerProfile.cosineSimilarity(a, b), 0.0);
    });
  });

  group('SpeakerProfile - similarity & verify', () {
    test('similarity вычисляет взвешенное среднее между максимумом и средним', () {
      final emb1 = Float32List.fromList([1.0, 0.0]);
      final emb2 = Float32List.fromList([0.0, 1.0]);
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 2,
        embeddings: [emb1, emb2],
      );

      // Кандидат идентичен emb1 (сходство с emb1 = 1.0, с emb2 = 0.0)
      // max = 1.0, avg = 0.5
      // weighted = 0.7 * 1.0 + 0.3 * 0.5 = 0.7 + 0.15 = 0.85
      final candidate = Float32List.fromList([1.0, 0.0]);
      expect(profile.similarity(candidate), closeTo(0.85, 0.001));
    });

    test('verify возвращает true, если оценка превышает порог', () {
      final emb = Float32List.fromList([1.0, 0.0]);
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 2,
        embeddings: [emb],
      );

      final candidate = Float32List.fromList([1.0, 0.0]);
      expect(profile.verify(candidate, 0.70), isTrue);
      expect(profile.verify(candidate, 0.99), isTrue);

      final nonMatching = Float32List.fromList([0.0, 1.0]); // similarity 0.0
      expect(profile.verify(nonMatching, 0.70), isFalse);
    });

    test('verify без сохранённых эмбеддингов возвращает true (не блокирует)', () {
      final emptyProfile = SpeakerProfile(
        name: 'user',
        dimension: 2,
        embeddings: const [],
      );
      final candidate = Float32List.fromList([1.0, 0.0]);
      expect(emptyProfile.verify(candidate, 0.80), isTrue);
    });
  });

  group('SpeakerProfile - сериализация и сохранение на диск', () {
    test('toJson и fromJson сохраняют все поля и эмбеддинги', () {
      final now = DateTime.now();
      final original = SpeakerProfile(
        name: 'test_speaker',
        dimension: 3,
        createdAt: now,
        embeddings: [
          Float32List.fromList([0.1, 0.2, 0.3]),
          Float32List.fromList([0.4, 0.5, 0.6]),
        ],
      );

      final json = original.toJson();
      final restored = SpeakerProfile.fromJson(json);

      expect(restored.name, 'test_speaker');
      expect(restored.dimension, 3);
      expect(restored.embeddings, hasLength(2));
      expect(restored.embeddings[0], [closeTo(0.1, 0.001), closeTo(0.2, 0.001), closeTo(0.3, 0.001)]);
      expect(restored.embeddings[1], [closeTo(0.4, 0.001), closeTo(0.5, 0.001), closeTo(0.6, 0.001)]);
    });

    test('save, load, exists и delete работают с файловой системой', () {
      expect(SpeakerProfile.exists(), isFalse);
      expect(SpeakerProfile.load(), isNull);

      final profile = SpeakerProfile(
        name: 'user',
        dimension: 2,
        embeddings: [
          Float32List.fromList([0.5, 0.5]),
        ],
      );

      profile.save();

      expect(SpeakerProfile.exists(), isTrue);
      final loaded = SpeakerProfile.load();
      expect(loaded, isNotNull);
      expect(loaded!.name, 'user');
      expect(loaded.embeddings, hasLength(1));
      expect(loaded.embeddings.first.length, 2);

      final deleted = SpeakerProfile.delete();
      expect(deleted, isTrue);
      expect(SpeakerProfile.exists(), isFalse);
      expect(SpeakerProfile.load(), isNull);
    });

    test('load повреждённого файла возвращает null', () {
      final file = File(SpeakerProfile.defaultPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{ broken json:');

      expect(SpeakerProfile.load(), isNull);
    });
  });
}
