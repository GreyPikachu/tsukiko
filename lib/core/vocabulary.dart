// Словарь и замены: подсказки для модели и автозамена текста.
//
// Объединяет подсказки произношения/терминов (acoustic hints) и
// текстовые автозамены (text replacements) в единую модель данных.
// Не зависит от Flutter и файловой системы.

import 'dart:math' as math;

import 'package:equatable/equatable.dart';

import 'fuzzy_matching.dart';
import 'text_commands.dart';

const vocabularySetting = 'vocabulary';
const vocabularyDictationEnabledSetting = 'vocabularyDictationEnabled';
const vocabularyTranscriberEnabledSetting = 'vocabularyTranscriberEnabled';
// Whisper reserves at most half its 448-token text context for the initial
// prompt. Leave room for estimation error and for the model's own context.
const vocabularyPromptBudget = 160;

enum VocabularyType { hint, replacement }

class VocabularyItem extends Equatable {
  const VocabularyItem({
    required this.id,
    required this.phrase,
    this.replacement = '',
    this.enabled = true,
    this.isPriority = false,
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

  /// Приоритетная ли запись для передачи напрямую в контекст (токены) модели.
  /// Если false — запись применяется только на этапе постпроцессинга, не
  /// расходуя лимит токенов нейросети и защищая её от галлюцинаций.
  final bool isPriority;

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
    bool? isPriority,
    DateTime? createdAt,
  }) => VocabularyItem(
    id: id ?? this.id,
    phrase: phrase ?? this.phrase,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
    isPriority: isPriority ?? this.isPriority,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'phrase': phrase,
    'replacement': replacement,
    'enabled': enabled,
    'isPriority': isPriority,
    // Older versions starred every newly added hint automatically. Only
    // an explicit star in the new format may bias the decoder.
    'priorityExplicit': isPriority,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };

  static VocabularyItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final phrase = value['phrase'];
    if (phrase is! String || phrase.trim().isEmpty) return null;
    final id = value['id'] as String? ?? phrase.trim().toLowerCase();
    final replacement = (value['replacement'] as String?) ?? '';
    final enabled = (value['enabled'] as bool?) ?? true;
    final isPriority =
        value['priorityExplicit'] == true && value['isPriority'] == true;
    final createdAtStr = value['createdAt'] as String?;
    final createdAt = createdAtStr != null
        ? DateTime.tryParse(createdAtStr)
        : null;

    return VocabularyItem(
      id: id,
      phrase: phrase,
      replacement: replacement,
      enabled: enabled,
      isPriority: isPriority,
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
        isPriority: false,
      );

  @override
  List<Object?> get props => [
    id,
    phrase,
    replacement,
    enabled,
    isPriority,
    createdAt,
  ];
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

/// Одна операция добавления для словаря в настройках и в расшифровщике.
/// Повторное добавление того же слова обновляет запись, а не создаёт дубль.
List<VocabularyItem> upsertVocabulary(
  Iterable<VocabularyItem> items,
  String phrase, {
  String replacement = '',
}) {
  final word = phrase.trim();
  if (word.isEmpty) return items.toList();
  final value = replacement.trim();
  final updated = items.toList();
  final index = updated.indexWhere(
    (item) => item.phrase.trim().toLowerCase() == word.toLowerCase(),
  );
  if (index >= 0) {
    final old = updated[index];
    // Повторное добавление слова как подсказки не должно стирать уже
    // настроенную для него автозамену.
    final effectiveReplacement = value.isEmpty ? old.replacement : value;
    updated[index] = old.copyWith(
      phrase: word,
      replacement: effectiveReplacement,
      enabled: true,
      isPriority: old.isPriority,
    );
  } else {
    updated.add(
      VocabularyItem(
        id: 'vocab_${DateTime.now().microsecondsSinceEpoch}',
        phrase: word,
        replacement: value,
        enabled: true,
        isPriority: false,
        createdAt: DateTime.now(),
      ),
    );
  }
  return updated;
}

/// Составляет затравку (conditioning prompt) для модели из базовой подсказки
/// и активных записей словаря.
///
/// Подсказка модели не дополняется отдельными словами из словаря: словарь
/// полностью применяется на этапе локального фонетического сопоставления
/// (VocabularyMatcher), не засоряя окно контекста Whisper и не провоцируя
/// галлюцинации и зацикливания.
String promptWithVocabulary(
  String basePrompt,
  Iterable<VocabularyItem> items, {
  int maxEstimatedTokens = vocabularyPromptBudget,
  bool onlyPriority = true,
}) {
  return _boundedPrompt(basePrompt.trim(), maxEstimatedTokens);
}

/// Whisper silently keeps only the tail when its initial prompt exceeds the
/// text context. Keep complete words from the beginning instead, with the same
/// conservative token estimate already used for vocabulary additions.
String _boundedPrompt(String prompt, int budget) {
  if (budget <= 0) return '';
  if (_estimatePromptTokens(prompt) <= budget) return prompt;
  var weight = 0.0;
  var lastSpace = 0;
  var lastClause = 0;
  var end = 0;
  for (final rune in prompt.runes) {
    final next = weight + (rune < 128 ? 1 / 3 : 2 / 3);
    if (next.ceil() > budget) break;
    weight = next;
    end += rune > 0xFFFF ? 2 : 1;
    if (rune == 0x20 || rune == 0x0A) lastSpace = end;
    if (rune == 0x2C ||
        rune == 0x3B ||
        rune == 0x2E ||
        rune == 0x21 ||
        rune == 0x3F) {
      lastClause = end;
    }
  }
  final cut = lastClause >= end * 0.75
      ? lastClause
      : lastSpace > 0
      ? lastSpace
      : end;
  return prompt
      .substring(0, cut)
      .trimRight()
      .replaceFirst(RegExp(r'[,;]+$'), '');
}

/// Оценка количества токенов, занимаемых словарем в контексте модели.
/// Словарь применяется исключительно локально, поэтому в модель не добавляется (0 токенов).
int estimateVocabularyTokens(
  Iterable<VocabularyItem> items, {
  String basePrompt = '',
  bool onlyPriority = true,
}) {
  return 0;
}

int _estimatePromptTokens(String prompt) {
  var weight = 0.0;
  for (final rune in prompt.runes) {
    // Cyrillic and other non-ASCII scripts usually consume substantially
    // more Whisper tokens per character than English prose.
    weight += rune < 128 ? 1 / 3 : 2 / 3;
  }
  return weight.ceil();
}

final _vocabWordCharacter = RegExp(r'[\p{L}\p{N}_]', unicode: true);
final _cjkOrNonSpacedRegex = RegExp(
  r'[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3040-\u309F\u30A0-\u30FF\u0E00-\u0E7F]',
);

bool _isWordCharacterAt(String text, int at) {
  if (at < 0 || at >= text.length) return false;
  return _vocabWordCharacter.hasMatch(text.substring(at, at + 1));
}

bool _isCjkOrNonSpacedAt(String text, int at) {
  if (at < 0 || at >= text.length) return false;
  return _cjkOrNonSpacedRegex.hasMatch(text.substring(at, at + 1));
}

bool _isValidWordBoundary({
  required String source,
  required int start,
  required int end,
  required bool isRuleCjk,
}) {
  // Левая граница
  if (start > 0) {
    final prevIsWord = _isWordCharacterAt(source, start - 1);
    if (prevIsWord) {
      if (!isRuleCjk) {
        final prevIsCjk = _isCjkOrNonSpacedAt(source, start - 1);
        final currIsCjk = _isCjkOrNonSpacedAt(source, start);
        // Если оба символа принадлежат одному алфавитному скрипту без пробела — это внутри слова
        if (!prevIsCjk && !currIsCjk) return false;
      }
    }
  }

  // Правая граница
  if (end < source.length) {
    final nextIsWord = _isWordCharacterAt(source, end);
    if (nextIsWord) {
      if (!isRuleCjk) {
        final lastIsCjk = _isCjkOrNonSpacedAt(source, end - 1);
        final nextIsCjk = _isCjkOrNonSpacedAt(source, end);
        // Если оба символа принадлежат одному алфавитному скрипту без пробела — это внутри слова
        if (!lastIsCjk && !nextIsCjk) return false;
      }
    }
  }

  return true;
}

bool _isWordStartAt(String source, int at) {
  if (at < 0 || at >= source.length) return false;
  if (!_isWordCharacterAt(source, at)) return false;
  if (at == 0) return true;
  if (!_isWordCharacterAt(source, at - 1)) return true;
  return _isCjkOrNonSpacedAt(source, at - 1) != _isCjkOrNonSpacedAt(source, at);
}

class _VocabRule {
  _VocabRule(this.item)
    : phrase = item.phrase.trim(),
      lower = item.phrase.trim().toLowerCase(),
      charLength = item.phrase.trim().length,
      replacement = item.replacement,
      collapsedLower = PhoneticNormalizer.stripWhitespace(
        item.phrase.trim(),
      ).toLowerCase(),
      phoneticKey = PhoneticNormalizer.normalize(item.phrase.trim()),
      fullPhoneticKey = PhoneticNormalizer.normalize(
        item.phrase.trim(),
        extractSkeleton: false,
      ),
      wordCount = _countWords(item.phrase.trim()),
      isCjk = _cjkOrNonSpacedRegex.hasMatch(item.phrase.trim());

  final VocabularyItem item;
  final String phrase;
  final String lower;
  final int charLength;
  final String replacement;
  final String collapsedLower;
  final String phoneticKey;
  final String fullPhoneticKey;
  final int wordCount;
  final bool isCjk;
  String get output => item.isReplacement ? replacement : phrase;

  static int _countWords(String text) {
    final words = text.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    return words.isEmpty ? 1 : words.length;
  }
}

/// Build the lookup once per transcript, rather than comparing every word in
/// every segment with the entire vocabulary. The dictionary itself has no
/// artificial size limit; only an explicitly starred decoder prompt does.
class VocabularyMatcher {
  VocabularyMatcher(Iterable<VocabularyItem> items) {
    for (final item in items) {
      if (!item.usable) continue;
      final rule = _VocabRule(item);
      maxWordCount = math.max(maxWordCount, rule.wordCount);
      _exact.putIfAbsent(rule.lower[0], () => []).add(rule);
      if (rule.charLength > 4) {
        _surface.putIfAbsent(rule.lower[0], () => []).add(rule);
        if (rule.fullPhoneticKey.isNotEmpty) {
          _phonetic.putIfAbsent(rule.phoneticKey, () => []).add(rule);
          _fullPhonetic.putIfAbsent(rule.fullPhoneticKey, () => []).add(rule);
        }
      } else if (rule.charLength == 4 &&
          rule.phrase == rule.phrase.toUpperCase()) {
        _fullPhonetic.putIfAbsent(rule.fullPhoneticKey, () => []).add(rule);
      }
    }
    for (final bucket in _exact.values) {
      bucket.sort((a, b) => b.charLength.compareTo(a.charLength));
    }
  }

  final Map<String, List<_VocabRule>> _exact = {};
  final Map<String, List<_VocabRule>> _surface = {};
  final Map<String, List<_VocabRule>> _phonetic = {};
  final Map<String, List<_VocabRule>> _fullPhonetic = {};
  int maxWordCount = 1;

  CommandText apply(String source) => _applyVocabulary(source, this);
}

class _CandidateMatch {
  _CandidateMatch({
    required this.rule,
    required this.matchedLength,
    required this.score,
    required this.distance,
  });

  final _VocabRule rule;
  final int matchedLength;
  final double score;
  final int distance;
}

class _CandidateSpan {
  const _CandidateSpan(this.end, this.wordCount);
  final int end;
  final int wordCount;
}

_CandidateMatch? _findFuzzyMatchAt({
  required String source,
  required int at,
  required VocabularyMatcher matcher,
  required int maxWordCount,
}) {
  final candidateSpans = <_CandidateSpan>[];
  var current = at;
  var wordsCounted = 0;
  final maxWordsToScan = math.min(maxWordCount + 1, 6);

  while (current < source.length && wordsCounted < maxWordsToScan) {
    var wordEnd = current;
    while (wordEnd < source.length && _isWordCharacterAt(source, wordEnd)) {
      wordEnd++;
    }
    if (wordEnd == current) break;
    wordsCounted++;
    candidateSpans.add(_CandidateSpan(wordEnd, wordsCounted));

    var nextWordStart = wordEnd;
    while (nextWordStart < source.length &&
        (source[nextWordStart] == ' ' ||
            source[nextWordStart] == '\t' ||
            source[nextWordStart] == '-' ||
            source[nextWordStart] == '_')) {
      nextWordStart++;
    }
    if (nextWordStart == wordEnd ||
        nextWordStart >= source.length ||
        !_isWordCharacterAt(source, nextWordStart)) {
      break;
    }
    current = nextWordStart;
  }

  if (candidateSpans.isEmpty) return null;

  final matches = <_CandidateMatch>[];

  for (final span in candidateSpans) {
    final candidate = source.substring(at, span.end);
    final candWords = span.wordCount;
    final candLower = candidate.toLowerCase();
    final candCollapsed = PhoneticNormalizer.stripWhitespace(
      candLower,
    ).toLowerCase();
    final candPhonetic = PhoneticNormalizer.normalize(candidate);
    final candFullPhonetic = PhoneticNormalizer.normalize(
      candidate,
      extractSkeleton: false,
    );
    final candidateRules = <_VocabRule>{
      ...?matcher._surface[candLower[0]],
      ...?matcher._phonetic[candPhonetic],
      ...?matcher._fullPhonetic[candFullPhonetic],
    };

    for (final rule in candidateRules) {
      if (candLower == rule.lower) continue;
      final crossScript =
          RegExp(r'[A-Za-z]').hasMatch(rule.phrase) !=
          RegExp(r'[A-Za-z]').hasMatch(candidate);
      // У короткой аббревиатуры слишком мало звуков для сравнения скелета
      // согласных: FITU и «фото» иначе схлопываются в один ключ. Но «фиту»
      // целиком сохраняем как явный межалфавитный вариант.
      if (rule.charLength <= 4) {
        if (rule.charLength == 4 &&
            rule.phrase == rule.phrase.toUpperCase() &&
            candidate.length == rule.charLength &&
            // Межалфавитное чтение аббревиатуры, а не «кот»/«код».
            crossScript &&
            candFullPhonetic == rule.fullPhoneticKey) {
          matches.add(
            _CandidateMatch(
              rule: rule,
              matchedLength: candidate.length,
              score: 0.97,
              distance: 0,
            ),
          );
        }
        continue;
      }

      // Length pre-filtering (spec line 515: |L_cand - L_ref| <= tau)
      final tau = DamerauLevenshtein.adaptiveThreshold(rule.charLength);
      final collapsedLenDiff =
          (candCollapsed.length - rule.collapsedLower.length).abs();

      // 1. Space variations / Agglutination match (any word count)
      if (candCollapsed == rule.collapsedLower) {
        matches.add(
          _CandidateMatch(
            rule: rule,
            matchedLength: candidate.length,
            score: 1.0,
            distance: 0,
          ),
        );
        continue;
      }

      // Полная межалфавитная фонетика сохраняет гласные. Для имён вроде
      // tsukiko / цукико она точна, а короткий скелет FITU / фото — нет.
      if (rule.fullPhoneticKey.length >= 5 &&
          candFullPhonetic == rule.fullPhoneticKey) {
        matches.add(
          _CandidateMatch(
            rule: rule,
            matchedLength: candidate.length,
            score: 0.98,
            distance: 0,
          ),
        );
        continue;
      }

      // 2. Exact Phonetic Skeleton match (any word count)
      if (crossScript &&
          rule.phoneticKey.length >= 3 &&
          candPhonetic == rule.phoneticKey &&
          DamerauLevenshtein.similarity(
                candFullPhonetic,
                rule.fullPhoneticKey,
              ) >=
              0.72) {
        matches.add(
          _CandidateMatch(
            rule: rule,
            matchedLength: candidate.length,
            score: 0.98,
            distance: 0,
          ),
        );
        continue;
      }

      // Beyond exact collapsed and exact phonetic skeleton matches,
      // candidate must satisfy length pre-filtering and word count matching
      if (crossScript ||
          candWords != rule.wordCount ||
          collapsedLenDiff > tau ||
          tau == 0) {
        continue;
      }

      // 3. Metric distance (OSA) on surface and collapsed strings
      final d1 = DamerauLevenshtein.distance(candLower, rule.lower, tau);
      final d2 = DamerauLevenshtein.distance(
        candCollapsed,
        rule.collapsedLower,
        tau,
      );
      final dist = math.min(d1, d2);

      if (dist <= tau) {
        final maxL = math.max(candLower.length, rule.charLength);
        final sim = 1.0 - (dist / maxL);
        matches.add(
          _CandidateMatch(
            rule: rule,
            matchedLength: candidate.length,
            score: 0.85 + (sim * 0.10),
            distance: dist,
          ),
        );
        continue;
      }

      // Approximate consonant skeletons are too lossy for automatic edits:
      // ordinary words with different vowels collapse to the same key.
    }
  }

  if (matches.isEmpty) return null;

  // Tie-breaking priority:
  // 1. Highest score
  // 2. Longest rule charLength (Maximum Munch of rule phrases)
  // 3. Lowest distance
  // 4. Closest matchedLength to rule charLength (prefers minimal matching span)
  matches.sort((a, b) {
    final scoreCmp = b.score.compareTo(a.score);
    if (scoreCmp != 0) return scoreCmp;
    final ruleLenCmp = b.rule.charLength.compareTo(a.rule.charLength);
    if (ruleLenCmp != 0) return ruleLenCmp;
    final distCmp = a.distance.compareTo(b.distance);
    if (distCmp != 0) return distCmp;
    final deltaA = (a.matchedLength - a.rule.charLength).abs();
    final deltaB = (b.matchedLength - b.rule.charLength).abs();
    return deltaA.compareTo(deltaB);
  });

  // Two plausible dictionary entries are not enough evidence to rewrite
  // speech. Prefer leaving the model's text alone to choosing arbitrarily.
  if (matches.length > 1 &&
      matches[0].rule.output != matches[1].rule.output &&
      matches[0].score - matches[1].score < 0.03) {
    return null;
  }
  return matches.first;
}

/// Применяет активные автозамены из словаря к распознанному тексту.
///
/// Поддерживает:
/// - Быстрый точный поиск (O(1)) для точных совпадений без учёта регистра.
/// - Нечёткое (fuzzy) сопоставление через Optimal String Alignment (Damerau-Levenshtein).
/// - Фонетическую аппроксимацию (IPNF) между кириллицей и латиницей.
/// - Вариации склейки и пробелов в составных словах (юскейс / юс кейс / use case).
/// - Строгую защиту коротких слов (до 4 букв; исключение — полное чтение
///   четырёхбуквенной латинской аббревиатуры кириллицей).
/// - Неразрушающее отслеживание координат сгенерированных замен.
CommandText applyVocabularyReplacements(
  String source,
  Iterable<VocabularyItem> items,
) => VocabularyMatcher(items).apply(source);

CommandText _applyVocabulary(String source, VocabularyMatcher matcher) {
  if (source.isEmpty ||
      (matcher._exact.isEmpty &&
          matcher._surface.isEmpty &&
          matcher._fullPhonetic.isEmpty)) {
    return CommandText(source, const []);
  }
  final maxWordCount = matcher.maxWordCount;

  final lowerSource = source.toLowerCase();
  final out = StringBuffer();
  final replacements = <TextReplacement>[];
  var at = 0;

  while (at < source.length) {
    // 1. Точный путь (O(1)): ищем прямое совпадение с учётом границ слов
    _VocabRule? exactMatch;
    for (final rule
        in matcher._exact[lowerSource[at]] ?? const <_VocabRule>[]) {
      final end = at + rule.charLength;
      if (end > source.length) continue;
      if (!lowerSource.startsWith(rule.lower, at)) continue;
      if (!_isValidWordBoundary(
        source: source,
        start: at,
        end: end,
        isRuleCjk: rule.isCjk,
      )) {
        continue;
      }
      exactMatch = rule;
      break;
    }

    if (exactMatch != null) {
      final start = out.length;
      final original = source.substring(at, at + exactMatch.charLength);
      final output = exactMatch.output;
      out.write(output);
      if (original != output) {
        replacements.add(
          TextReplacement(
            start: start,
            end: start + output.length,
            original: original,
            replacement: output,
          ),
        );
      }
      at += exactMatch.charLength;
      continue;
    }

    // 2. Нечёткое и фонетическое сопоставление
    // Срабатывает только на границе слова
    if (_isWordStartAt(source, at)) {
      final match = _findFuzzyMatchAt(
        source: source,
        at: at,
        matcher: matcher,
        maxWordCount: maxWordCount,
      );

      if (match != null) {
        final start = out.length;
        final original = source.substring(at, at + match.matchedLength);
        final output = match.rule.output;
        out.write(output);
        if (original != output) {
          replacements.add(
            TextReplacement(
              start: start,
              end: start + output.length,
              original: original,
              replacement: output,
            ),
          );
        }
        at += match.matchedLength;
        continue;
      }
    }

    out.write(source[at]);
    at++;
  }

  return CommandText(out.toString(), List.unmodifiable(replacements));
}

/// Бесшовная миграция настроек из устаревших `textCommands` и `prompt`.
List<VocabularyItem> loadAndMigrateVocabulary(
  Map<String, dynamic> settingsJson,
) {
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
            isPriority: false,
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
            isPriority: false,
            createdAt: DateTime.now(),
          ),
        );
      }
    }
  }

  return migrated;
}
