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

/// Показать файл в проводнике системы. Возвращает false, если показывать
/// нечего: файл убрали мимо приложения.
///
/// [createIfMissing] — только для папки библиотеки: её человек может ещё
/// ни разу не наполнить, и «показать» разумно понимать как «заведи и
/// покажи». Ко всему остальному это не относится: создавать файл, который
/// пропал, значит показывать подделку вместо него.
Future<bool> revealInFinder(String path, {bool createIfMissing = false}) async {
  if (createIfMissing && !Directory(path).existsSync()) {
    try {
      Directory(path).createSync(recursive: true);
    } catch (_) {}
  }
  return os.reveal(path);
}

/// Имена движка. Они же — имена процессов в «Мониторинге системы»:
/// гигабайт памяти должен числиться за понятным именем, а не за
/// безымянным whisper-cli, про который не скажешь, чей он.
const recognizerExeName = 'tsukiko-recognizer';
const dictationExeName = 'tsukiko-dictation';

/// Свой движок — тот, что лежит внутри самого приложения.
///
/// Он главнее системного, и это не гордость, а совместимость: мы передаём
/// модели флаги, которых в старых сборках whisper.cpp нет вовсе (`--vad`,
/// `-mc`, `--carry-initial-prompt`). На чужой сборке распознавание либо
/// падает, либо молча работает хуже — а какая она у человека, мы не знаем.
///
/// Заодно отсюда следует, что приложение нечем сломать снаружи: снесённый
/// Homebrew на него не влияет, потому что своего движка он не касается.
/// И наоборот — чужой мы не ставим, не правим и не удаляем.
String? bundledEngine(String name) {
  // .../tsukiko.app/Contents/MacOS/tsukiko → .../Contents/Helpers/имя.
  // Helpers — то место, куда macOS велит класть вложенные программы,
  // и подписываются они вместе с приложением.
  final path = os.join(
      os.dirname(os.dirname(Platform.resolvedExecutable)), 'Helpers', name);
  return File(path).existsSync() ? path : null;
}

String? findWhisper() =>
    bundledEngine(recognizerExeName) ?? os.findExecutable('whisper-cli');

/// Работаем на своём движке, а не на системном. Разница видна человеку
/// в одной строке — и она честная: на чужой сборке мы за поведение
/// не отвечаем.
bool get engineIsOurs => bundledEngine(recognizerExeName) != null;

/// Имя, под которым движок работает у нас.
///
/// В «Мониторинге системы» гигабайт памяти числился за `whisper-cli`, и по
/// этой строке нельзя было понять, чей он: tsukiko поднял или соседняя
/// программа на том же whisper.cpp. Спрашивают об этом ровно тогда, когда
/// память кончается, — то есть когда разбираться некогда.
///
/// Ссылка, а не копия: копия теряет свои библиотеки (они ищутся рядом
/// с самим файлом) и ломает подпись, а по ссылке система запускает тот же
/// бинарник и называет процесс её именем.
String? runnableWhisper(String? exe, String as) {
  if (exe == null) return null;
  // Свой уже назван как надо — ссылка ни к чему.
  if (os.basename(exe) == as) return exe;
  try {
    final dir = Directory(os.join(os.supportDir, 'bin'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final link = Link(os.join(dir.path, as));
    // Движок могли обновить или переставить — ссылка обязана вести туда же,
    // куда ведёт поиск, иначе запустится вчерашний.
    if (link.existsSync()) {
      if (link.targetSync() == exe) return link.path;
      link.deleteSync();
    }
    link.createSync(exe);
    return link.path;
  } catch (e) {
    // Не вышло — работаем под чужим именем: имя в мониторе не стоит
    // того, чтобы из-за него не считалось вовсе.
    stderr.writeln('tsukiko: ссылка на движок не создалась — $e');
    return exe;
  }
}
