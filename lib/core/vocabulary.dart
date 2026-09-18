// Словарь и замены: подсказки для модели и автозамена текста.
//
// Объединяет подсказки произношения/терминов (acoustic hints) и
// текстовые автозамены (text replacements) в единую модель данных.
// Не зависит от Flutter и файловой системы.

import 'package:equatable/equatable.dart';

import 'text_commands.dart';

const vocabularySetting = 'vocabulary';
const vocabularyDictationEnabledSetting = 'vocabularyDictationEnabled';
const vocabularyTranscriberEnabledSetting = 'vocabularyTranscriberEnabled';

enum VocabularyType {
  hint,
  replacement,
}

class VocabularyItem extends Equatable {
  const VocabularyItem({
    required this.id,
    required this.phrase,
    this.replacement = '',
    this.enabled = true,
    this.createdAt,
  });

  /// Уникальный идентификатор записи.
  final String id;

  /// Произносимое слово, термин, имя собственное или фраза-триггер.
  final String phrase;

  /// Заменяющий текст. Если пуст — запись работает исключительно как подсказка
  /// для модели (acoustic hint). Если заполнен — после распознавания [phrase]
  /// заменяется на [replacement].
  final String replacement;

  /// Включена ли запись для распознавания и автозамены.
  final bool enabled;

  final DateTime? createdAt;

  bool get isReplacement => replacement.trim().isNotEmpty;
  bool get isHintOnly => !isReplacement;
  bool get usable => phrase.trim().isNotEmpty && enabled;

  VocabularyType get type =>
      isReplacement ? VocabularyType.replacement : VocabularyType.hint;

  VocabularyItem copyWith({
    String? id,
    String? phrase,
    String? replacement,
    bool? enabled,
    DateTime? createdAt,
  }) =>
      VocabularyItem(
        id: id ?? this.id,
        phrase: phrase ?? this.phrase,
        replacement: replacement ?? this.replacement,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'phrase': phrase,
        'replacement': replacement,
        'enabled': enabled,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };

  static VocabularyItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final phrase = value['phrase'];
    if (phrase is! String || phrase.trim().isEmpty) return null;
    final id = value['id'] as String? ?? phrase.trim().toLowerCase();
    final replacement = (value['replacement'] as String?) ?? '';
    final enabled = (value['enabled'] as bool?) ?? true;
    final createdAtStr = value['createdAt'] as String?;
    final createdAt =
        createdAtStr != null ? DateTime.tryParse(createdAtStr) : null;

    return VocabularyItem(
      id: id,
      phrase: phrase,
      replacement: replacement,
      enabled: enabled,
      createdAt: createdAt,
    );
  }

  /// Обратная совместимость с существующим [TextCommand].
  TextCommand toTextCommand() => TextCommand(phrase, replacement);

  static VocabularyItem fromTextCommand(TextCommand cmd, {String? id}) =>
      VocabularyItem(
        id: id ?? cmd.phrase.trim().toLowerCase(),
        phrase: cmd.phrase,
        replacement: cmd.replacement,
        enabled: true,
      );

  @override
  List<Object?> get props => [id, phrase, replacement, enabled, createdAt];
}

/// Разбор списка элементов словаря из JSON.
List<VocabularyItem> vocabularyFromJson(Object? value) {
  if (value is! List) return const [];
  final items = <VocabularyItem>[];
  for (final item in value) {
    final parsed = VocabularyItem.fromJson(item);
    if (parsed != null) items.add(parsed);
  }
  return items;
}

/// Составляет затравку (conditioning prompt) для модели из базовой подсказки
/// и активных записей словаря.
///
/// В затравку попадают как чистые подсказки, так и фразы замен (чтобы модель
/// слышала и писала их предсказуемо). Ограничивается бюджетом токенов.
String promptWithVocabulary(
  String basePrompt,
  Iterable<VocabularyItem> items, {
  int maxEstimatedTokens = 220,
}) {
  final base = basePrompt.trim();
  final lowerBase = base.toLowerCase();

  final additions = <String>[];
  final seen = <String>{};

  for (final item in items) {
    if (!item.usable) continue;
    final phrase = item.phrase.trim();
    final lower = phrase.toLowerCase();

    // Предотвращаем дублирование
    if (seen.add(lower) && !lowerBase.contains(lower)) {
      additions.add(phrase);
    }
  }

  if (additions.isEmpty) return base;

  // Защита окна контекста Whisper (~3.8 символа на токен в среднем)
  final buffer = StringBuffer(base);
  for (final addition in additions) {
    final candidate = buffer.isEmpty ? addition : ', $addition';
    if ((buffer.length + candidate.length) / 3.8 > maxEstimatedTokens) {
      break;
    }
    if (buffer.isNotEmpty &&
        !RegExp(r'[.!?…,:;]\s*$').hasMatch(buffer.toString())) {
      buffer.write(', ');
    } else if (buffer.isNotEmpty) {
      buffer.write(' ');
    }
    buffer.write(addition);
  }

  return buffer.toString();
}

/// Оценка количества токенов, занимаемых словарем в контексте модели.
int estimateVocabularyTokens(
  Iterable<VocabularyItem> items, {
  String basePrompt = '',
}) {
  final prompt = promptWithVocabulary(basePrompt, items, maxEstimatedTokens: 9999);
  if (prompt.isEmpty) return 0;
  return (prompt.length / 3.8).ceil();
}

/// Применяет активные автозамены из словаря к распознанному тексту.
CommandText applyVocabularyReplacements(
  String source,
  Iterable<VocabularyItem> items,
) {
  final replacementCommands = items
      .where((item) => item.usable && item.isReplacement)
      .map((item) => item.toTextCommand());

  return applyTextCommands(source, replacementCommands);
}

/// Бесшовная миграция настроек из устаревших `textCommands` и `prompt`.
List<VocabularyItem> loadAndMigrateVocabulary(Map<String, dynamic> settingsJson) {
  // 1. Если уже сохранён современный ключ 'vocabulary'
  if (settingsJson.containsKey('vocabulary')) {
    final list = settingsJson['vocabulary'];
    if (list is List) {
      return list
          .map((e) => VocabularyItem.fromJson(e))
          .whereType<VocabularyItem>()
          .toList();
    }
  }

  // 2. Иначе мигрируем из legacy 'textCommands'
  final migrated = <VocabularyItem>[];
  final seenPhrases = <String>{};

  if (settingsJson.containsKey('textCommands')) {
    final legacyCommands = textCommandsFromJson(settingsJson['textCommands']);
    for (var i = 0; i < legacyCommands.length; i++) {
      final cmd = legacyCommands[i];
      if (cmd.usable && seenPhrases.add(cmd.phrase.trim().toLowerCase())) {
        migrated.add(
          VocabularyItem(
            id: 'migrated_cmd_$i',
            phrase: cmd.phrase.trim(),
            replacement: cmd.replacement,
            enabled: true,
            createdAt: DateTime.now(),
          ),
        );
      }
    }
  }

  // 3. Мигрируем слова из старой свободной подсказки (prompt), если их нет в словаре
  final legacyPrompt = (settingsJson['prompt'] as String?) ?? '';
  if (legacyPrompt.isNotEmpty) {
    final tokens = legacyPrompt.split(RegExp(r'[,;|\n]'));
    var hintIdx = 0;
    for (final raw in tokens) {
      final token = raw.trim();
      if (token.isNotEmpty && seenPhrases.add(token.toLowerCase())) {
        migrated.add(
          VocabularyItem(
            id: 'migrated_prompt_${hintIdx++}',
            phrase: token,
            replacement: '', // Чистая подсказка
            enabled: true,
            createdAt: DateTime.now(),
          ),
        );
      }
    }
  }

  return migrated;
}
