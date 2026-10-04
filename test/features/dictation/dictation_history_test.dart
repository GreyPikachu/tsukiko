import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/library.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/features/dictation/dictation_history.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';

import '../../support/fake_os.dart';

void main() {
  useTempSupportDir('tsukiko-history-test');

  group('DictationEntry', () {
    test('сериализация и десериализация сохраняют данные', () {
      final now = DateTime(2026, 10, 2, 12, 0, 0);
      final entry = DictationEntry(
        id: '12345',
        text: 'Привет мир',
        createdAt: now,
      );

      final json = entry.toJson();
      final restored = DictationEntry.fromJson(json);

      expect(restored.id, '12345');
      expect(restored.text, 'Привет мир');
      expect(restored.createdAt, now);
      expect(restored, entry);
    });

    test('десериализация устойчива к отсутствующим и битым полям', () {
      final empty = DictationEntry.fromJson(const {});
      expect(empty.id, isNotEmpty);
      expect(empty.text, isEmpty);
      expect(empty.createdAt, isNotNull);

      final brokenDate = DictationEntry.fromJson({
        'id': 'abc',
        'text': 'текст',
        'created_at': 'not-a-date',
      });
      expect(brokenDate.id, 'abc');
      expect(brokenDate.text, 'текст');
      expect(brokenDate.createdAt, isNotNull);
    });
  });

  group('DictationHistory', () {
    test('чтение при отсутствии файла возвращает пустой список', () {
      final list = DictationHistory.load();
      expect(list, isEmpty);
    });

    test('сохранение и загрузка списка записей', () {
      final entries = [
        DictationEntry(
          id: '1',
          text: 'Первая фраза',
          createdAt: DateTime.now(),
        ),
        DictationEntry(
          id: '2',
          text: 'Вторая фраза',
          createdAt: DateTime.now(),
        ),
      ];

      DictationHistory.save(entries);
      final loaded = DictationHistory.load();

      expect(loaded.length, 2);
      expect(loaded[0].text, 'Первая фраза');
      expect(loaded[1].text, 'Вторая фраза');
    });

    test('лимит истории обрезается до maxEntries (20)', () {
      final entries = List.generate(
        30,
        (i) => DictationEntry(
          id: '$i',
          text: 'Фраза $i',
          createdAt: DateTime.now(),
        ),
      );

      DictationHistory.save(entries);
      final loaded = DictationHistory.load();

      expect(loaded.length, DictationHistory.maxEntries);
      expect(loaded.first.text, 'Фраза 0');
    });

    test('очистка удаляет файл с диска', () {
      DictationHistory.save([
        DictationEntry(id: '1', text: 'Тест', createdAt: DateTime.now()),
      ]);
      expect(DictationHistory.load(), isNotEmpty);

      DictationHistory.clear();
      expect(DictationHistory.load(), isEmpty);
    });
  });

  test('одна повреждённая запись не теряет остальную историю', () {
    final file = File(os.join(supportDir, 'dictation_history.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'items': [
          {'id': 'a', 'text': 'Первая'},
          {'id': 123, 'text': 'Повреждённая'},
          {'id': 'b', 'text': 'Вторая'},
        ],
      }),
    );
    expect(DictationHistory.load().map((e) => e.text), ['Первая', 'Вторая']);
  });
  test(
    'асинхронная запись заменяет прежний файл, удаление очищает историю',
    () async {
      final entry = DictationEntry(
        id: 'a',
        text: 'Текст',
        createdAt: DateTime(2026, 10, 4),
      );
      await DictationHistory.write([entry]);
      await DictationHistory.write([entry, entry]);
      expect(DictationHistory.load().length, 2);
      await DictationHistory.remove();
      expect(DictationHistory.load(), isEmpty);
    },
  );

  group('DictationState с историей', () {
    test('равенство учитывает список истории', () {
      final entry = DictationEntry(
        id: '1',
        text: 'Тест',
        createdAt: DateTime(2026, 1, 1),
      );

      const state1 = DictationState();
      final state2 = DictationState(history: [entry]);

      expect(state1 == state2, isFalse);
      expect(state2 == DictationState(history: [entry]), isTrue);
    });

    test('clearHistory очищает history и last', () {
      final entry = DictationEntry(
        id: '1',
        text: 'Тест',
        createdAt: DateTime(2026, 1, 1),
      );

      final state = DictationState(last: 'Тест', history: [entry]);
      final cleared = state.copyWith(clearHistory: true);

      expect(cleared.history, isEmpty);
      expect(cleared.last, isEmpty);
    });
  });
}
