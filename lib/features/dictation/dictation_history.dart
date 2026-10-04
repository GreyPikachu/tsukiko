import 'dart:convert';
import 'dart:io';

import 'package:equatable/equatable.dart';

import '../../core/library.dart' show supportDir, writeJsonAtomically;
import '../../core/logger.dart';
import '../../platform/os.dart';

/// Одна расшифрованная фраза в истории диктовки.
class DictationEntry extends Equatable {
  const DictationEntry({
    required this.id,
    required this.text,
    required this.createdAt,
  });

  /// Уникальный идентификатор записи (например, микросекундная отметка).
  final String id;

  /// Распознанный текст диктовки.
  final String text;

  /// Момент времени, когда диктовка завершилась.
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'created_at': createdAt.toIso8601String(),
  };

  factory DictationEntry.fromJson(Map<String, dynamic> json) {
    final rawTime = json['created_at'] as String?;
    return DictationEntry(
      id:
          (json['id'] as String?) ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      text: (json['text'] as String?) ?? '',
      createdAt: rawTime != null
          ? (DateTime.tryParse(rawTime) ?? DateTime.now())
          : DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [id, text, createdAt];
}

/// Хранилище истории расшифровок диктовки на диске.
///
/// Хранит последние [maxEntries] записей в файле `dictation_history.json`
/// в служебной папке приложения. Запись атомарна: падение посреди записи
/// не повреждает историю.
class DictationHistory {
  DictationHistory._();

  /// Максимальное число записей в истории диктовки.
  static const int maxEntries = 20;

  static File get _file => File(os.join(supportDir, 'dictation_history.json'));

  /// Загрузить историю с диска. Возвращает пустой список, если файла нет
  /// или структура повреждена.
  static List<DictationEntry> load() {
    try {
      if (!_file.existsSync()) return const [];
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return const [];
      final data = jsonDecode(text);
      if (data is! Map<String, dynamic>) return const [];
      final rawList = data['items'];
      if (rawList is! List) return const [];
      final list = <DictationEntry>[];
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          DictationEntry entry;
          try {
            entry = DictationEntry.fromJson(item);
          } catch (_) {
            continue; // One corrupt item must not discard the other transcripts.
          }
          if (entry.text.trim().isNotEmpty) {
            list.add(entry);
          }
        }
      }
      return list.take(maxEntries).toList();
    } catch (e, st) {
      Log.warn(
        'DictationHistory',
        'Не удалось прочитать историю диктовок: $e',
        e,
        st,
      );
      return const [];
    }
  }

  /// Атомарно сохранить историю на диск с ограничением до [maxEntries].
  static void save(List<DictationEntry> entries) {
    try {
      final safeDir = Directory(supportDir);
      if (!safeDir.existsSync()) {
        safeDir.createSync(recursive: true);
      }
      final items = entries
          .where((e) => e.text.trim().isNotEmpty)
          .take(maxEntries)
          .map((e) => e.toJson())
          .toList();
      writeJsonAtomically(_file, {'items': items});
    } catch (e, st) {
      Log.warn(
        'DictationHistory',
        'Не удалось сохранить историю диктовок: $e',
        e,
        st,
      );
    }
  }

  /// Production writes are awaited by a single chain in DictationCubit,
  /// so the atomic temporary file cannot be shared by overlapping writes.
  static Future<void> write(List<DictationEntry> entries) async {
    await Directory(supportDir).create(recursive: true);
    final items = entries
        .where((e) => e.text.trim().isNotEmpty)
        .take(maxEntries)
        .map((e) => e.toJson())
        .toList();
    final target = _file;
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode({'items': items}), flush: true);
    await tmp.rename(target.path);
  }

  static Future<void> remove() async {
    if (await _file.exists()) await _file.delete();
  }

  /// Удалить файл истории с диска.
  static void clear() {
    try {
      if (_file.existsSync()) {
        _file.deleteSync();
      }
    } catch (e, st) {
      Log.warn(
        'DictationHistory',
        'Не удалось удалить историю диктовок: $e',
        e,
        st,
      );
    }
  }
}
