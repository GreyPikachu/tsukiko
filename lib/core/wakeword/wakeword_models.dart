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
  static Future<bool> ensureKwsInstalled() =>
      _ensureArchive(kwsDir, kwsArchiveUrl, _validKwsDirectory);

  // ── Russian keyword verifier (small offline zipformer, Vosk-derived) ──────
  // Second stage for Russian keywords: 26 ms per candidate in-process versus
  // ~0.2 s for a whisper process, with the same accuracy on diagnostic replay.
  static const ruAsrArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-small-zipformer-ru-2024-09-18.tar.bz2';
  static String get ruAsrDir => modelPathFor('asr_zipformer_ru_small');
  static String get ruAsrEncoder => '$ruAsrDir/encoder.int8.onnx';
  static String get ruAsrDecoder => '$ruAsrDir/decoder.onnx';
  static String get ruAsrJoiner => '$ruAsrDir/joiner.int8.onnx';
  static String get ruAsrTokens => '$ruAsrDir/tokens.txt';

  static bool get isRuAsrInstalled => _validRuAsrDirectory(ruAsrDir);

  static bool _validRuAsrDirectory(String directory) {
    final files = <String, int>{
      'encoder.int8.onnx': 20 * 1024 * 1024,
      'decoder.onnx': 1024 * 1024,
      'joiner.int8.onnx': 100 * 1024,
      'tokens.txt': 1000,
    };
    return files.entries.every((entry) {
      final file = File('$directory/${entry.key}');
      return file.existsSync() && file.lengthSync() >= entry.value;
    });
  }

  static Future<bool> ensureRuAsrInstalled() async {
    if (!await _ensureArchive(
      ruAsrDir,
      ruAsrArchiveUrl,
      _validRuAsrDirectory,
    )) {
      return false;
    }
    // The archive also ships a 90 MB fp32 encoder and test audio.
    for (final name in [
      'encoder.onnx',
      'joiner.onnx',
      'decoder.int8.onnx',
      'test_wavs',
    ]) {
      final entity = FileSystemEntity.typeSync('$ruAsrDir/$name');
      if (entity == FileSystemEntityType.notFound) continue;
      await (entity == FileSystemEntityType.directory
              ? Directory('$ruAsrDir/$name')
              : File('$ruAsrDir/$name'))
          .delete(recursive: true);
    }
    return isRuAsrInstalled;
  }

  static Future<bool> _ensureArchive(
    String targetDir,
    String url,
    bool Function(String directory) valid,
  ) async {
    if (valid(targetDir)) return true;
    final archive = File('$targetDir.download');
    final staging = Directory('$targetDir.staging');
    final client = HttpClient();
    try {
      await archive.parent.create(recursive: true);
      if (staging.existsSync()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download returned ${response.statusCode}: $url');
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
      if (!valid(staging.path)) {
        throw FormatException('Incomplete model archive: $url');
      }
      final installed = Directory(targetDir);
      if (installed.existsSync()) await installed.delete(recursive: true);
      await staging.rename(targetDir);
      return valid(targetDir);
    } catch (e, st) {
      Log.error('WakeWord', 'Failed to install model $url: $e', e, st);
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
