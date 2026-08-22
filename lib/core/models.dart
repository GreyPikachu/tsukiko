import 'dart:io';

import 'package:equatable/equatable.dart';

import '../platform/os.dart';

/// Модели распознавания: где их искать, что из них годится, как они
/// называются для человека, что можно докачать и как это качается.

/// Файл модели распознавания. Имя VAD-модели устроено так же
/// (ggml-silero-….bin), но речь она не распознаёт — в списке моделей ей
/// не место, иначе её можно выбрать и получить пустую расшифровку.
bool looksLikeSpeechModel(String name) =>
    name.startsWith('ggml-') && name.endsWith('.bin') && !name.contains('silero');

/// Модель, лежащая на диске, со всем, что о ней надо знать до выбора.
///
/// Раньше список моделей был просто списком путей, и из него нельзя было
/// понять ни размера, ни того, цел ли файл: битую или недокачанную модель
/// показывали наравне с рабочей, и узнавалось это только при запуске
/// распознавания — руганью whisper про тензоры.
/// Сравнивается по значениям: обход диска каждый раз создаёт новые
/// объекты, и без этого список выглядел бы изменившимся на каждом опросе.
class InstalledModel extends Equatable {
  const InstalledModel({
    required this.path,
    required this.sizeBytes,
    required this.problem,
    required this.ours,
  });

  final String path;

  /// Размер файла. Ноль — прочитать не удалось.
  final int sizeBytes;

  /// Почему файл не годится в модель распознавания. Пусто — годится.
  final String? problem;

  /// Лежит в нашей папке моделей, а не в общем кеше whisper.cpp.
  /// Чужую папку делят с другими программами, и трогать её надо осторожнее.
  final bool ours;

  String get name => modelDisplayName(path);
  String get folder => os.dirname(path);
  bool get broken => problem != null;

  String get sizeLabel =>
      sizeBytes <= 0 ? '' : sizeLabelMb(sizeBytes ~/ (1024 * 1024));

  @override
  List<Object?> get props => [path, sizeBytes, problem, ours];
}

/// Что лежит на диске — с проверкой каждого файла.
///
/// Проверка стоит чтения восьми байт и размера, то есть ничего: моделей
/// единицы, а показать битую как рабочую дороже.
List<InstalledModel> scanModels() {
  final out = <InstalledModel>[];
  final seen = <String>{};
  for (final d in [os.modelsDir, ...os.sharedModelDirs]) {
    final dir = Directory(d);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !looksLikeSpeechModel(os.basename(f.path))) continue;
      if (!seen.add(f.path)) continue;
      var size = 0;
      try {
        size = f.lengthSync();
      } catch (_) {}
      out.add(InstalledModel(
        path: f.path,
        sizeBytes: size,
        problem: modelFileProblem(f.path),
        ours: f.path.startsWith(os.modelsDir),
      ));
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// Только пути и только годных: тому, кто собирается распознавать, битая
/// модель в списке ни к чему.
List<String> findModels() =>
    [for (final m in scanModels()) if (!m.broken) m.path];

/// Подпись, по которой две модели не спутать.
///
/// Имя собирается из имени файла, поэтому одна и та же «Large v3 Turbo»
/// в разных папках выглядела в списке двумя одинаковыми строками, и какая
/// из них выбрана — понять было нельзя. Когда имя не одно, дописываем папку.
String modelLabel(String path, List<String> all) {
  final name = modelDisplayName(path);
  final sameName =
      all.where((p) => modelDisplayName(p) == name).length > 1;
  if (!sameName) return name;
  final dir = os.dirname(path);
  final where = dir.startsWith(os.modelsDir)
      ? appName
      : os.basename(dir).replaceFirst(RegExp(r'^\.'), '');
  return '$name · $where';
}

// ── откуда берутся модели ───────────────────────────────────────────────────
//
// Без файла модели приложение бесполезно, а взять его новому человеку
// неоткуда. Поэтому качаем сами — в свою папку, которую findModels() уже
// просматривает.

const _modelRepo = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

/// VAD лежит в другом репозитории: в ggerganov/whisper.cpp этого файла нет,
/// оттуда приходит 404.
const vadModelFile = 'ggml-silero-v5.1.2.bin';
const vadModelUrl =
    'https://huggingface.co/ggml-org/whisper-vad/resolve/main/$vadModelFile';

String modelPathFor(String file) => os.join(os.modelsDir, file);

String get vadModelPath => modelPathFor(vadModelFile);

String sizeLabelMb(int mb) => mb >= 1024
    ? '${(mb / 1024).toStringAsFixed(1).replaceAll('.', ',')} ГБ'
    : '$mb МБ';

/// Имя модели, одно на всё приложение: загрузчик, панель, переключатель,
/// инспектор и диалоги называют «ggml-large-v3-turbo.bin» одинаково —
/// «Large v3 Turbo». Модель может быть и не из каталога (свой файл, чужая
/// папка), поэтому имя разбирается из имени файла, а не ищется в списке:
/// слова из букв — с заглавной, версии и квантование — как есть.
String modelDisplayName(String path) {
  final file = os.basename(path);
  final stem = file
      .replaceFirst(RegExp(r'^ggml-'), '')
      .replaceFirst(RegExp(r'\.bin$'), '')
      .trim();
  if (stem.isEmpty) return file;
  return stem
      .split(RegExp(r'[-\s.]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => RegExp(r'^[a-zA-Zа-яА-Я]+$').hasMatch(w)
          ? w[0].toUpperCase() + w.substring(1).toLowerCase()
          : w)
      .join(' ');
}

/// Годится ли выбранный файл в модель распознавания. Возвращает null,
/// если годится, иначе — фразу для человека.
///
/// Расширения «.bin» мало: под ним лежит что угодно, а whisper-cli
/// на чужом файле падает с английской руганью про тензоры. Настоящая
/// модель ggml начинается с числа «ggml» (на диске это байты «lmgg»),
/// а следом идёт размер словаря — у модели речи он десятки тысяч слов,
/// у модели тишины десять. По этим двум числам речевая модель отличается
/// и от мусора, и от VAD.
String? modelFileProblem(String path) {
  final file = File(path);
  final name = os.basename(path);
  if (!file.existsSync()) return 'Файла «$name» больше нет на диске.';

  final size = file.lengthSync();
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final head = raf.readSync(8);
    if (head.length < 8 || String.fromCharCodes(head.sublist(0, 4)) != 'lmgg') {
      return '«$name» — не модель распознавания речи: у файлов ggml '
          'в начале стоит своя метка, а здесь её нет.';
    }
    // Little-endian uint32 сразу за меткой.
    final vocab = head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24);
    if (vocab < 1000) {
      return '«$name» — модель ggml, но не речевая: в ней $vocab '
          'слов словаря. Так выглядит модель распознавания тишины (VAD), '
          'речь она не расшифровывает.';
    }
  } catch (_) {
    return 'Файл «$name» не удалось прочитать.';
  } finally {
    raf?.closeSync();
  }

  // Самая маленькая речевая модель — tiny, 74 МБ; квантованная чуть меньше.
  if (size < 20 * 1024 * 1024) {
    return '«$name» слишком мал для модели распознавания: '
        '${sizeLabelMb(size ~/ (1024 * 1024))}, а самая маленькая весит 74 МБ.';
  }
  return null;
}

/// Модель, которую приложение умеет достать само. Размер записан здесь,
/// а не спрашивается у сервера: выбирать надо до загрузки, а не после.
class ModelOffer {
  const ModelOffer(this.file, this.mb, this.about);
  final String file, about;
  final int mb;

  /// Имя общее со всем приложением: отдельное поле разошлось бы с ним.
  String get title => modelDisplayName(file);
  String get url => '$_modelRepo/$file';
  String get path => modelPathFor(file);
  bool get present => File(path).existsSync();
  String get size => sizeLabelMb(mb);
}

/// Каталог один на всё приложение: и вкладка «Модели», и выпадающий список
/// в инспекторе, и он же в настройках диктовки берут модели отсюда.
///
/// Large v1 и v2 в каталог не попали намеренно: это те же три гигабайта,
/// что и v3, только обучены раньше, и на русском v3 их обходит. Три почти
/// одинаковые трёхгигабайтные строки в списке — не выбор, а помеха.
const modelCatalog = [
  ModelOffer('ggml-tiny.bin', 74, 'Попробовать, что всё работает'),
  ModelOffer('ggml-base.bin', 141, 'Быстрая, но путает слова'),
  ModelOffer('ggml-small.bin', 465, 'Разумный минимум для русского'),
  ModelOffer('ggml-medium.bin', 1463, 'Точнее Small, заметно медленнее'),
  ModelOffer('ggml-large-v3-turbo.bin', 1549, 'Лучшая и при этом быстрая'),
  ModelOffer('ggml-large-v3.bin', 2952,
      'Точнее Turbo на трудной записи, но вдвое тяжелее и медленнее'),
];

/// Есть ли эта модель уже на диске.
///
/// По имени файла, а не по пути: одна и та же модель лежит то в нашей папке,
/// то в общем кеше whisper.cpp — путь каждый раз свой, файл один. Со
/// сравнением путей приложение предлагало скачать полтора гигабайта того,
/// что у человека уже стоит.
bool haveModel(List<String> installed, ModelOffer m) =>
    installed.any((p) => os.basename(p) == m.file);

/// Что из каталога ещё можно загрузить. Пусто — значит есть всё.
List<ModelOffer> modelOffers(List<String> installed) =>
    modelCatalog.where((m) => !haveModel(installed, m)).toList();

/// Загрузка файла с докачкой. Пишем в «.part» рядом и переименовываем только
/// в конце: обрыв на полутора гигабайтах не должен оставить огрызок, который
/// findModels() покажет как готовую модель.
class Download {
  Download(this.url, this.dest, {this.title = ''});

  final String url, dest, title;

  /// Байты: сколько уже есть и сколько всего. Ноль в [total] — сервер
  /// не сказал длину, тогда процент показывать не из чего.
  int got = 0, total = 0;
  bool cancelled = false;

  /// Почему не вышло — человеческими словами, для показа на экране.
  /// Пусто, пока всё идёт хорошо или пока загрузку отменили сами.
  String? error;

  int get percent => total > 0 ? (got * 100 ~/ total).clamp(0, 100) : 0;

  String get progressLabel {
    const mb = 1024 * 1024;
    final done = (got / mb).round();
    return total > 0 ? '$percent % · $done из ${(total / mb).round()} МБ'
                     : '$done МБ';
  }

  void cancel() => cancelled = true;

  /// Метка версии файла на сервере (ETag, иначе Last-Modified), сохранённая
  /// рядом с «.part».
  ///
  /// Без неё докачка небезопасна: между двумя заходами файл в репозитории
  /// могли перезалить, и хвост новой версии, дописанный к началу старой,
  /// даёт мусор, который переименовывается в готовую модель. Метка уходит
  /// в `If-Range`: не совпала — сервер сам отдаёт файл целиком, и мы
  /// начинаем сначала.
  File get _tagFile => File('$dest.part.id');

  String? _readTag() {
    try {
      final tag = _tagFile.readAsStringSync().trim();
      return tag.isEmpty ? null : tag;
    } catch (_) {
      return null;
    }
  }

  static String? _tagOf(HttpHeaders headers) =>
      headers.value(HttpHeaders.etagHeader) ??
      headers.value(HttpHeaders.lastModifiedHeader);

  void _forgetPart(File part) {
    try {
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
    try {
      if (_tagFile.existsSync()) _tagFile.deleteSync();
    } catch (_) {}
  }

  /// Возвращает путь к готовому файлу или null: отменили, оборвалось,
  /// сервер ответил не тем. Недокачанное остаётся в «.part» — следующий
  /// заход продолжит с того же места, если файл на сервере тот же.
  Future<String?> run({void Function()? onProgress}) async {
    if (File(dest).existsSync()) return dest;
    error = null;
    final uri = Uri.parse(url);
    final part = File('$dest.part');
    try {
      part.parent.createSync(recursive: true);
    } catch (_) {
      error = 'некуда положить файл: папка ${part.parent.path} недоступна';
      return null;
    }

    // Продолжаем только то, у чего есть метка версии. Огрызок без метки
    // достался от старой сборки или от оборванной записи — начинаем заново.
    var have = part.existsSync() ? part.lengthSync() : 0;
    var tag = have > 0 ? _readTag() : null;
    if (have > 0 && tag == null) {
      _forgetPart(part);
      have = 0;
    }

    final client = HttpClient()
      // Без таймаутов повисшее соединение висит вечно, и единственный
      // признак беды — что счётчик мегабайт перестал расти.
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(uri);
      if (have > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        req.headers.set(HttpHeaders.ifRangeHeader, tag!);
      }
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        error = '${uri.host} ответил ${res.statusCode}';
        return null;
      }
      // Полный ответ вместо куска значит одно из двух: докачку не поняли
      // или файл на сервере сменился. И там и там начинаем сначала —
      // дороже, но верно.
      if (res.statusCode == HttpStatus.ok) have = 0;
      tag = _tagOf(res.headers) ?? tag;
      got = have;
      total = res.contentLength > 0 ? have + res.contentLength : 0;

      final sink = part.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
      var shown = -1;
      try {
        // Метку пишем до первого байта: оборвись загрузка сразу, «.part»
        // без метки следующий заход просто выбросит.
        if (tag != null) {
          try {
            _tagFile.writeAsStringSync(tag);
          } catch (_) {}
        }
        await for (final chunk in res) {
          if (cancelled) return null;
          sink.writeFromSync(chunk);
          got += chunk.length;
          // Кусок приходит десятками килобайт: на полутора гигабайтах это
          // двадцать тысяч перерисовок. Дёргаем экран только на новом проценте.
          if (percent != shown) {
            shown = percent;
            onProgress?.call();
          }
        }
      } finally {
        sink.closeSync();
      }
      if (total > 0 && got < total) {
        error = 'связь оборвалась на $percent %';
        return null;
      }
      part.renameSync(dest);
      try {
        if (_tagFile.existsSync()) _tagFile.deleteSync();
      } catch (_) {}
      return dest;
    } catch (e) {
      // Текст исключения показывать нельзя: он английский и про сокеты.
      // Человеку важно другое — сеть или сервер, и что делать дальше.
      error = e is SocketException
          ? 'нет связи с ${uri.host}'
          : 'не удалось скачать с ${uri.host}';
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
