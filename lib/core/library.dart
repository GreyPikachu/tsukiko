import 'dart:io';

import '../platform/os.dart';

/// Где лежат файлы приложения и куда ложатся готовые расшифровки:
/// раскладка по месяцам и выбор свободного имени.

String get home => os.home;

String get supportDir => os.supportDir;

/// Библиотека расшифровок — обычная папка, которую видно в проводнике.
String get defaultLibraryPath => os.defaultLibraryPath;

String monthFolder(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

/// Куда и под каким именем лечь файлам одной записи.
class Placement {
  const Placement(this.dir, this.stem);
  final String dir, stem;

  String pathFor(String ext) => os.join(dir, '$stem$ext');
}

String _free(String path, bool Function(String) taken) {
  if (!taken(path)) return path;
  final slash = path.lastIndexOf(Platform.pathSeparator);
  final dotAt = path.lastIndexOf('.');
  final hasExt = dotAt > slash;
  final head = hasExt ? path.substring(0, dotAt) : path;
  final ext = hasExt ? path.substring(dotAt) : '';
  for (var n = 2; n < 1000; n++) {
    final candidate = '$head $n$ext';
    if (!taken(candidate)) return candidate;
  }
  return '$head ${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// Один формат — файл лежит прямо в папке месяца. Форматов несколько —
/// у записи появляется своя папка, иначе месяц превращается в свалку.
Placement planPlacement({
  required String root,
  required String stem,
  required int formatCount,
  DateTime? now,
}) {
  final month = os.join(root, monthFolder(now ?? DateTime.now()));
  if (formatCount > 1) {
    final dir = _free(os.join(month, stem), (p) => Directory(p).existsSync());
    return Placement(dir, stem);
  }
  return Placement(month, stem);
}

/// Свободное имя внутри папки: «Запись 2.txt», если «Запись.txt» уже занято.
String freeStem(String dir, String stem, String ext) =>
    freeStemFor(dir, stem, [ext]);

/// То же для набора форматов сразу: имя выбирается такое, при котором
/// ни один из [suffixes] не ляжет поверх чужого файла.
///
/// Отдельной функции здесь быть не должно бы, но проверять каждый формат
/// по очереди нельзя: «Запись.txt» свободно, «Запись.srt» занято — и
/// экспорт двух форматов затирал бы субтитры, оставляя текст рядом.
String freeStemFor(String dir, String stem, List<String> suffixes) {
  // Расширение первого формата нужно только чтобы отрезать его от готового
  // имени: _free приписывает номер к основе, а не к концу строки.
  final ext = suffixes.first;
  final path = _free(
    os.join(dir, '$stem$ext'),
    (p) {
      final base = p.substring(0, p.length - ext.length);
      return suffixes.any((s) => File('$base$s').existsSync());
    },
  );
  final name = os.basename(path);
  return name.substring(0, name.length - ext.length);
}

/// Показать файл в проводнике системы.
Future<void> revealInFinder(String path) => os.reveal(path);

String? findWhisper() => os.findExecutable('whisper-cli');
