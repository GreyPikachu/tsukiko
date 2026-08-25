import 'dart:io';

import '../platform/os.dart';
import 'app_locale.dart';


// ── занятость модели ────────────────────────────────────────────────────────
//
// Замка «модель занята» в системе нет, поэтому судим по косвенным
// признакам. Первая версия смотрела только на память: кто держит больше
// половины веса модели, тот её и загрузил. На whisper-cli это работает
// (large-v3-turbo — около 1,8 ГБ резидентной памяти), но не на всех: замер
// соседнего распознавателя во время диктовки дал пик 139 МБ при модели
// в 1,6 ГБ и ни одного открытого дескриптора — модель у него не лежит
// в резидентной памяти целиком.
//
// Единственный признак, который не может отсутствовать у того, кто прямо
// сейчас распознаёт речь, — это потраченное процессорное время. Поэтому
// главный сигнал теперь такой: сколько CPU-секунд процесс сжёг между двумя
// опросами. Фоновый распознаватель в простое тратит около 0,2 % ядра,
// работающий — на порядки больше, так что порог различает их с запасом.

enum ModelState { free, loading, busy }

/// Насколько ядра должен потратить процесс между опросами, чтобы считаться
/// работающим. Замер фонового распознавателя в простое — 0,002 ядра, так что
/// запас стократный; выше поднимать нельзя — часть работы может уходить
/// на отдельный ускоритель, и процессор её не увидит.
const _busyCpuShare = 0.20;

/// На сколько должна вырасти резидентная память между опросами, чтобы это
/// значило «читают модель». Второй признак нужен затем, что он не зависит
/// от порога по процессору: у соседнего распознавателя во время диктовки
/// память идёт с 42 МБ до 139 МБ, и такой скачок виден, даже если считает
/// не процессор.
const _loadingGrowthKb = 40 * 1024;

/// Снимок кандидатов на момент опроса. Сам по себе он ни о чём не говорит —
/// важна разница между двумя замерами.
class CpuSample {
  const CpuSample(this.at, this.byPid);
  const CpuSample.empty() : at = null, byPid = const {};

  final DateTime? at;

  /// pid → накопленное процессорное время в секундах и резидентная память в КБ.
  final Map<int, ({double cpu, int rssKb})> byPid;
}

class ModelUse {
  const ModelUse(
    this.state, {
    this.by = '',
    this.pid = 0,
    this.rssKb = 0,
    this.share = 0,
    this.learned = const {},
    this.cpu = const CpuSample.empty(),
  });

  final ModelState state;
  final String by;

  /// Кто именно занял модель. Имя процесса для этого не годится: у соседа
  /// может работать свой whisper-server, а гасить нам можно только свой.
  final int pid;

  final int rssKb;

  /// Сколько ядер процесс занимал между двумя последними опросами.
  final double share;

  final Set<String> learned;
  final CpuSample cpu;

  bool get busy => state != ModelState.free;

  String get label {
    final l10n = currentL10n();
    return switch (state) {
      ModelState.free => l10n.modelFree,
      ModelState.loading => l10n.modelLoading(by),
      ModelState.busy => l10n.modelBusy(by),
    };
  }

  /// Подробности для подсказки: по чему именно видно, что процесс работает.
  String get detail {
    final l10n = currentL10n();
    return switch (state) {
      ModelState.free => l10n.modelFreeDetail,
      ModelState.loading => l10n.modelLoadingDetail(by),
      ModelState.busy => share >= _busyCpuShare
          ? l10n.modelBusyDetailCpu(by, (share * 100).round())
          : l10n.modelBusyDetailMemory(by, (rssKb / 1024).round()),
    };
  }
}

/// Приложение обычно хранит модель у себя в Application Support — по пути
/// к файлу можно догадаться, кто её хозяин, ещё до первой встречи.
String? ownerFromModelPath(String modelPath) => os.appOwnerOf(modelPath);

/// Кто сейчас распознаёт речь на этой машине.
///
/// [modelPath] — выбранная модель, по её весу считается порог по памяти.
/// [others] — остальные известные модели: чужое приложение может держать
/// свою, а не нашу, и раньше мы такого соседа не видели вовсе.
/// [previous] — замер CPU с прошлого опроса, без него признак работы
/// посчитать не из чего.
/// [probeHolders] — запускать ли lsof (самая дорогая часть опроса, около
/// 150 мс); он нужен только чтобы поймать короткий момент загрузки.
Future<ModelUse> modelUsage({
  required String modelPath,
  List<String> others = const [],
  Set<String> learned = const {},
  int? ignorePid,
  CpuSample previous = const CpuSample.empty(),
  bool probeHolders = true,
}) async {
  final paths = <String>{if (modelPath.isNotEmpty) modelPath, ...others}
      .where((p) => File(p).existsSync())
      .toList();
  if (paths.isEmpty) {
    return ModelUse(ModelState.free, learned: learned, cpu: previous);
  }
  try {
    // Порог по памяти — от размера выбранной модели: половину её веса
    // случайный процесс в памяти не держит. Признак сильный, но не
    // обязательный: кто-то грузит модель целиком, кто-то читает её кусками.
    final selected = File(paths.contains(modelPath) ? modelPath : paths.first);
    final thresholdKb = selected.lengthSync() ~/ 2048;

    final names = {...learned};
    for (final p in paths) {
      final owner = ownerFromModelPath(p);
      // Скачанные модели лежат в нашей же папке, и владельцем по пути
      // угадываемся мы сами. Себя в соседи записывать нельзя: вторая копия
      // и так не запускается, а первая — это мы.
      if (owner != null && owner != appName) names.add(owner);
    }

    final holders = probeHolders ? await os.holdersOf(paths) : const <int>[];
    final candidates = <int>{...holders};
    candidates.addAll(await os.pidsMatching('whisper'));
    for (final n in names) {
      candidates.addAll(await os.pidsNamed(n));
    }
    candidates.remove(pid);
    if (ignorePid != null) candidates.remove(ignorePid);
    if (candidates.isEmpty) {
      // Замер прошлого опроса сохраняем, а не сбрасываем: сосед, который
      // на один опрос исчез из кандидатов и вернулся (whisper-cli
      // перезапускается на каждом файле очереди), иначе оставался бы без
      // базы для разницы и не считался бы работающим ещё 700 мс.
      return ModelUse(ModelState.free, learned: learned, cpu: previous);
    }

    final now = DateTime.now();
    final samples = await os.sample(candidates);

    final sampled = <int, ({double cpu, int rssKb})>{};
    final seen = <String>{...learned};
    final gap = previous.at == null
        ? 0.0
        : now.difference(previous.at!).inMilliseconds / 1000;

    var best = const ModelUse(ModelState.free);
    var bestScore = 0.0;

    for (final s in samples) {
      final procPid = s.pid;
      final rss = s.rssKb;
      final cpu = s.cpuSeconds;
      final name = s.name;
      if (holders.contains(procPid)) seen.add(name.toLowerCase());
      sampled[procPid] = (cpu: cpu, rssKb: rss);

      // Сколько ядер процесс занимал с прошлого опроса. Слишком короткий
      // промежуток не измеряем — там сплошная погрешность округления ps.
      final was = previous.byPid[procPid];
      final measurable = was != null && gap >= 0.25;
      final share = measurable ? ((cpu - was.cpu) / gap).clamp(0.0, 64.0) : 0.0;
      final growthKb = measurable ? rss - was.rssKb : 0;

      // Три независимых признака. Память целиком ловит whisper-cli и всё,
      // что разворачивает модель классически; процессор и резкий рост
      // памяти — тех, кто читает её кусками.
      final byMemory = rss > thresholdKb;
      final byCpu = share >= _busyCpuShare;
      final byGrowth = growthKb >= _loadingGrowthKb;

      if (byMemory || byCpu || byGrowth) {
        final score = byMemory ? rss / thresholdKb : (byCpu ? share : 1.0);
        if (score > bestScore) {
          bestScore = score;
          best = ModelUse(ModelState.busy,
              by: name, pid: procPid, rssKb: rss, share: share, learned: seen);
        }
        continue;
      }

      // Файл открыт прямо сейчас, а работы ещё не видно — читают модель.
      if (holders.contains(procPid) && bestScore <= 0) {
        best = ModelUse(ModelState.loading,
            by: name, pid: procPid, rssKb: rss, learned: seen);
      }
    }

    final cpu = CpuSample(now, sampled);
    return ModelUse(best.state,
        by: best.by,
        pid: best.pid,
        rssKb: best.rssKb,
        share: best.share,
        learned: seen,
        cpu: cpu);
  } catch (_) {
    return ModelUse(ModelState.free, learned: learned, cpu: previous);
  }
}

/// ogg/opus, m4a, mp3… → 16 кГц моно WAV. Чем именно — дело системы:
/// whisper-cli сам читает только wav/mp3/ogg-vorbis/flac и падает на opus,
/// поэтому перекладываем всегда; не осилили — отдаём исходник как есть.
Future<String> toWav(String src, String dst) => os.toWav(src, dst);
