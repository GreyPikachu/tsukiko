
/// Разовый переезд с прежней установки.
///
/// Модели раньше искались в том числе в папке данных другого приложения —
/// на чужую папку приложение полагаться не должно: её могут удалить вместе
/// с той программой, и распознавать станет нечем. Поэтому модели оттуда
/// переносятся к нам (именно переносятся, не копируются: полтора гигабайта
/// в двух местах никому не нужны), а сама привязка убирается.
///
/// Файл временный: когда установки переедут, его можно удалить целиком
/// вместе с вызовами в `main()` и `runPanel()`. Больше нигде о прежней
/// папке не знает ничего.
library;

import 'dart:io';

import 'core/whisper_server.dart' show DictationSettings;
import 'platform/os.dart';
import 'core/settings.dart';

/// Папка моделей прежней установки. Единственное место, где этот путь
/// вообще упоминается.
String? get _legacyModelsDir => Platform.isMacOS
    ? os.join(os.home, 'Library/Application Support/app.dictara/models')
    : null;

/// Перенести модели к себе. Возвращает, сколько файлов переехало.
///
/// Идемпотентно: когда переносить нечего, не делает ничего и стоит одну
/// проверку существования папки. Зовётся из обеих точек входа, потому что
/// какая из них стартует первой — не наше дело.
Future<int> migrateLegacyModels() async {
  final from = _legacyModelsDir;
  if (from == null) return 0;
  final source = Directory(from);
  if (!source.existsSync()) return 0;

  final moved = <String, String>{};
  try {
    Directory(os.modelsDir).createSync(recursive: true);
    for (final entity in source.listSync(recursive: true)) {
      if (entity is! File) continue;
      final name = os.basename(entity.path);
      // Речевые модели и модель тишины — всё, что здесь вообще бывает.
      if (!name.startsWith('ggml-') || !name.endsWith('.bin')) continue;

      final dest = os.join(os.modelsDir, name);
      final target = File(dest);
      if (target.existsSync()) {
        // Такая модель у нас уже есть. Одинаковые по имени и размеру —
        // это один и тот же файл: имя модели однозначно, а размер служит
        // грубой проверкой, что файл целый.
        if (target.lengthSync() == entity.lengthSync()) {
          _delete(entity);
          moved[entity.path] = dest;
        }
        continue;
      }
      try {
        entity.renameSync(dest);
      } catch (_) {
        // Разные тома — переименование не работает, копируем и стираем.
        try {
          entity.copySync(dest);
          _delete(entity);
        } catch (_) {
          continue;
        }
      }
      moved[entity.path] = dest;
    }
  } catch (_) {
    // Нет прав, папка исчезла из-под рук — переезд не должен мешать запуску.
  }

  if (moved.isNotEmpty) await _repointSettings(moved);
  _removeIfEmpty(source);
  return moved.length;
}

void _delete(File file) {
  try {
    file.deleteSync();
  } catch (_) {}
}

/// Снять опустевшие папки — снизу вверх.
///
/// Модели там лежали не россыпью, а каждая в своей подпапке
/// (`models/whisper-large-v3-turbo/ggml-large-v3-turbo.bin`), поэтому
/// после переноса остаются пустые вложенные папки, и сама `models`
/// пустой не считается.
void _removeIfEmpty(Directory dir) {
  try {
    for (final inner in dir.listSync().whereType<Directory>()) {
      _removeIfEmpty(inner);
    }
    if (dir.listSync().isEmpty) dir.deleteSync();
  } catch (_) {}
}

/// Выбранная модель могла указывать на переехавший файл. Без этого
/// человек после обновления увидел бы «Не выбрана» и пустой список.
Future<void> _repointSettings(Map<String, String> moved) async {
  final app = Settings.load();
  final model = app['model'] as String?;
  if (model != null && moved.containsKey(model)) {
    await Settings.save({'model': moved[model]});
  }

  final dictation = DictationSettings.load();
  final own = dictation.model;
  if (own.isNotEmpty && moved.containsKey(own)) {
    dictation.model = moved[own]!;
    dictation.save();
  }
}
