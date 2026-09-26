import 'dart:io';

import '../models.dart' show modelPathFor;
import '../logger.dart';

/// Модели Sherpa-ONNX для голосовой активации (KWS), распознавания голоса (Speaker ID)
/// и детектора активности речи (VAD).
class WakeWordModelPaths {
  WakeWordModelPaths._();

  // ── KWS (Keyword Spotting) ──────────────────────────────────────────────────
  static const kwsArchiveName =
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01-mobile.tar.bz2';
  static const kwsArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/$kwsArchiveName';

  static String get kwsDir => modelPathFor('kws_gigaspeech');
  static String get kwsEncoder =>
      '$kwsDir/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static String get kwsDecoder =>
      '$kwsDir/decoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static String get kwsJoiner =>
      '$kwsDir/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static String get kwsTokens => '$kwsDir/tokens.txt';

  static bool get isKwsInstalled =>
      File(kwsEncoder).existsSync() &&
      File(kwsDecoder).existsSync() &&
      File(kwsJoiner).existsSync() &&
      File(kwsTokens).existsSync();

  // ── Speaker Recognition (Voiceprint) ───────────────────────────────────────
  static const speakerModelFile =
      '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';
  static const speakerModelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$speakerModelFile';

  static String get speakerModelPath => modelPathFor(speakerModelFile);

  static bool get isSpeakerModelInstalled =>
      File(speakerModelPath).existsSync() &&
      File(speakerModelPath).lengthSync() > 10 * 1024 * 1024;

  // ── VAD ────────────────────────────────────────────────────────────────────
  static const vadOnnxFile = 'silero_vad.onnx';
  static const vadOnnxUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$vadOnnxFile';

  static String get vadOnnxPath => modelPathFor(vadOnnxFile);

  static bool get isVadInstalled =>
      File(vadOnnxPath).existsSync() && File(vadOnnxPath).lengthSync() > 100 * 1024;

  /// Проверить наличие всех необходимых моделей для WakeWord.
  static bool get areAllInstalled =>
      isKwsInstalled && isSpeakerModelInstalled && isVadInstalled;

  /// Распаковать скачанный архив KWS.
  static Future<bool> unpackKws(String archivePath) async {
    try {
      final outDir = Directory(kwsDir);
      if (!outDir.existsSync()) outDir.createSync(recursive: true);

      final res = await Process.run('tar', [
        '-xf',
        archivePath,
        '--strip-components=1',
        '-C',
        outDir.path,
      ]);

      if (res.exitCode != 0) {
        // Fallback without strip-components
        await Process.run('tar', ['-xf', archivePath, '-C', outDir.path]);
      }

      return isKwsInstalled;
    } catch (e, st) {
      Log.error('WakeWord', 'Failed to unpack KWS archive: $e', e, st);
      return false;
    }
  }
}
