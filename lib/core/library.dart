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
  // Где именно движок лежит внутри приложения, знает только граница
  // системы: у macOS и Windows это разные места.
  // Какие сборки бывают и какая из них годится этой машине — знает
  // граница системы. Здесь только «первая, которая нашлась и ещё
  // не показала себя нерабочей».
  for (final candidate in os.engineNames(name)) {
    final path = os.join(os.engineDir, candidate);
    if (_deadEngines.contains(path)) continue;
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Сборки движка, которые на этой машине не запускаются.
///
/// Проверять сборку файлом мало. На Windows их две — с Vulkan и без, — и
/// Vulkan-сборка падает не только там, где нет `vulkan-1.dll`: сломанный
/// или слишком старый драйвер видеокарты роняет `ggml_vk_instance_init`
/// изнутри, до первой нашей строчки. Снаружи это выглядит так: процесс
/// поднялся и умер, модель в память не попала, код возврата ненулевой —
/// и так на каждой записи подряд.
///
/// Поэтому запуск и есть проверка: не поднялась — вычёркиваем эту сборку
/// на весь сеанс и берём следующую по списку (процессорную). Помнить
/// дольше сеанса незачем: драйвер могли и починить, а лишний файл
/// с памятью о неудаче — это ещё одно место, где что-то протухает.
final _deadEngines = <String>{};

/// Эта сборка движка не запустилась — больше её не предлагать.
///
/// Возвращает true, если после вычёркивания есть чем заменить, — тогда
/// зовущему есть смысл попробовать ещё раз тем же вызовом.
bool engineFailedToStart(String path, String name) {
  _deadEngines.add(path);
  return bundledEngine(name) != null;
}

/// Забыть вычеркнутое. Нужно только тестам: в приложении сеанс один.
void forgetDeadEngines() => _deadEngines.clear();

/// Путь, который чужая программа на этой системе всё равно не откроет.
///
/// Короткие имена Windows чинят кириллицу в пути (см. `Os.processPath`),
/// но их создание можно на томе отключить — `fsutil 8dot3name query`, —
/// и тогда Windows молча отдаёт длинный путь. Чужую модель мы перекладывать
/// не вправе, а человеку гадать не по чему: движок скажет только
/// «failed to open». Значит надо сказать прямо.
bool pathBeyondEngine(String path) =>
    path.isNotEmpty && os.processPath(path).codeUnits.any((c) => c > 127);

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
  // Свой уже назван как надо (в том числе с .exe или суффиксами на Windows) — ссылка ни к чему.
  final base = os.basename(exe);
  if (base == as || base == '$as.exe' || base.startsWith('$as-')) return exe;
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
