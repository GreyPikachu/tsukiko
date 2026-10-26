import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../logger.dart';
import '../models.dart' show Download, modelPathFor;
import 'sha256.dart';

/// Модель режима «Несколько голосов» — NVIDIA Nemotron-3-Diarization
/// (Sortformer третьего поколения, до 8 голосов, понимает перебивки).
///
/// Выбрана замером на десяти настоящих записях — четыре встречи AMI и
/// шесть записей VoxConverse на 5–9 голосов: средняя ошибка 0.25 на
/// встречах и 0.05 на многоголосых, число голосов почти везде верное.
/// Прежняя схема (сегментация pyannote + TitaNet + порог) дробила тех же
/// людей на 17–46 «голосов» — см. `docs/diarization-engine.md`.
///
/// Считает её `nemo-speech diarize`, тот же NeMo-Speech.cpp, что уже
/// распознаёт Parakeet и Nemotron ASR, — второго движка не нужно.
/// Лицензия модели — OpenMDW 1.1 (коммерческое использование разрешено),
/// подтверждения на Hugging Face она не требует.
class DiarizationModels {
  DiarizationModels._();

  static const file = 'Nemotron-3-Diarization.q8_0.gguf';

  /// Ревизия закреплена: по `main` однажды придёт другой файл, и сумма
  /// перестанет сходиться — лучше честная ошибка, чем чужая модель.
  static const url =
      'https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/'
      'f667ed73aee57d40cc39428eb768b4fd87a0a29e/$file';

  /// LFS-сумма файла из API Hugging Face, пересчитанная заново на
  /// скачанной копии.
  static const sha256 =
      '08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1';

  static const bytes = 107012128;

  /// Размер загрузки — его показывают до начала, в диалоге включения.
  static const mb = 102;

  static const license = 'OpenMDW-1.1';

  static String get path => modelPathFor(file);

  static bool get isInstalled {
    final f = File(path);
    return f.existsSync() && f.lengthSync() == bytes;
  }

  /// Сколько мегабайт осталось скачать.
  static int downloadMb() => isInstalled ? 0 : mb;

  /// Загрузка, что идёт сейчас, — одна на всё приложение: режим включили,
  /// загрузка пошла, и первая же расшифровка ждёт её, а не качает вторую.
  static Future<String?>? _running;
  static Download? current;

  /// Процент текущей загрузки для инспектора; null — ничего не качается.
  static final percent = ValueNotifier<int?>(null);

  /// Почему прошлая загрузка не удалась; null — не было беды.
  static final failure = ValueNotifier<String?>(null);

  /// Начать загрузку сразу, как режим включили, а не на первой записи.
  static void prefetch() {
    if (!isInstalled) unawaited(ensureInstalled());
  }

  /// Скачать модель. Возвращает null, если всё на месте, иначе — почему
  /// не вышло (для журнала и подписи; текст движка не переводится).
  ///
  /// [onProgress] получает долю от 0 до 1.
  static Future<String?> ensureInstalled({
    void Function(double share)? onProgress,
    bool Function()? cancelled,
  }) async {
    if (isInstalled) return null;
    void forward() {
      if (cancelled?.call() ?? false) current?.cancel();
      if (percent.value case final p?) onProgress?.call(p / 100);
    }

    percent.addListener(forward);
    try {
      return await (_running ??= _fetch());
    } finally {
      percent.removeListener(forward);
    }
  }

  static Future<String?> _fetch() async {
    failure.value = null;
    final download = current = Download(url, path, title: file);
    percent.value = 0;
    try {
      final result = await download.run(
        onProgress: () => percent.value = download.percent,
      );
      if (result == null) {
        if (download.cancelled) return 'download cancelled';
        return failure.value = download.error ?? 'download failed';
      }
      final sum = await sha256OfFile(path);
      if (sum != sha256) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        return failure.value = 'sha256 mismatch for $file: $sum';
      }
      return null;
    } finally {
      if (failure.value case final problem?) {
        Log.error('Diarization', 'Model not installed: $problem');
      }
      current = null;
      _running = null;
      percent.value = null;
    }
  }
}
