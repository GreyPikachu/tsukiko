import 'dart:io';

import '../models.dart' show modelPathFor;
import '../logger.dart';

/// Модели Sherpa-ONNX для голосовой активации (KWS), распознавания голоса (Speaker ID)
/// и детектора активности речи (VAD).
class WakeWordModelPaths {
  WakeWordModelPaths._();

  // ── KWS (Keyword Spotting) ──────────────────────────────────────────────────
  static const kwsArchiveName =
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2';
  static const kwsArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/$kwsArchiveName';

  static String get kwsDir => modelPathFor('kws_gigaspeech_full');
  static String get kwsEncoder =>
      '$kwsDir/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static String get kwsDecoder =>
      '$kwsDir/decoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static String get kwsJoiner =>
      '$kwsDir/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static String get kwsTokens => '$kwsDir/tokens.txt';
  static String get kwsBpe => '$kwsDir/bpe.model';

  static bool get isKwsInstalled => _validKwsDirectory(kwsDir);

  static bool _validKwsDirectory(String directory) {
    final files = <String, int>{
      kwsEncoder.split('/').last: 4 * 1024 * 1024,
      kwsDecoder.split('/').last: 100 * 1024,
      kwsJoiner.split('/').last: 100 * 1024,
      'tokens.txt': 1000,
      'bpe.model': 1000,
    };
    return files.entries.every((entry) {
      final file = File('$directory/${entry.key}');
      return file.existsSync() && file.lengthSync() >= entry.value;
    });
  }

  /// The KWS model is downloaded only when voice activation is enabled.
  /// Extract into a temporary directory so a cancelled download cannot look
  /// like a valid installation on the next launch.
  static Future<bool> ensureKwsInstalled() async {
    if (isKwsInstalled) return true;
    final archive = File('$kwsDir.download');
    final staging = Directory('$kwsDir.staging');
    final client = HttpClient();
    try {
      await archive.parent.create(recursive: true);
      if (staging.existsSync()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final request = await client.getUrl(Uri.parse(kwsArchiveUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('KWS download returned ${response.statusCode}');
      }
      await response.pipe(archive.openWrite());
      final result = await Process.run('tar', [
        '-xf',
        archive.path,
        '--strip-components=1',
        '-C',
        staging.path,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'tar',
          const [],
          '${result.stderr}',
          result.exitCode,
        );
      }
      if (!_validKwsDirectory(staging.path)) {
        throw const FormatException('Incomplete KWS model archive');
      }
      final installed = Directory(kwsDir);
      if (installed.existsSync()) await installed.delete(recursive: true);
      await staging.rename(kwsDir);
      return isKwsInstalled;
    } catch (e, st) {
      Log.error('WakeWord', 'Failed to install KWS model: $e', e, st);
      return false;
    } finally {
      client.close(force: true);
      if (archive.existsSync()) await archive.delete();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

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
      File(vadOnnxPath).existsSync() &&
      File(vadOnnxPath).lengthSync() > 100 * 1024;

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
