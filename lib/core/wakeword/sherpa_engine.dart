import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'keyword_tokenizer.dart';
import 'wakeword_models.dart';
import '../logger.dart';

/// Результат распознавания ключевого слова.
class KeywordDetection {
  const KeywordDetection({
    required this.keyword,
    this.samples,
  });

  final String keyword;
  final Float32List? samples;
}

/// Абстракция над нативными возможностями sherpa-onnx.
///
/// Позволяет подменять нативный движок в тестах (`FakeSherpaEngine`),
/// гарантируя изоляцию тестов от нативных библиотек и файловой системы.
abstract class SherpaEngine {
  bool get isReady;

  /// Инициализировать детектор ключевых слов.
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
  });

  /// Инициализировать детектор пауз (VAD).
  Future<bool> initVad();

  /// Инициализировать извлекатель эмбеддингов спикера (Speaker ID).
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  });

  /// Передать порцию сэмплов в движок (16 кГц, моно).
  void acceptAudio(Float32List samples);

  /// Проверить наличие речи в аудио через VAD.
  bool isSpeech(Float32List samples);

  /// Проверить, сработало ли ключевое слово на текущем шаге.
  KeywordDetection? detectKeyword();

  /// Сбросить состояние потока ключевых слов.
  void resetKeywordStream();

  /// Извлечь эмбеддинг спикера из аудиофрагмента.
  Float32List? extractSpeakerEmbedding(Float32List audio);

  /// Проверить, принадлежит ли голос пользователю по порогу сходства.
  bool verifySpeaker(Float32List embedding, double threshold);

  /// Освободить все нативные ресурсы и память.
  void dispose();
}

/// Реальная реализация на базе библиотеки Sherpa-ONNX через `dart:ffi`.
class NativeSherpaEngine implements SherpaEngine {
  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _kwsStream;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.SpeakerEmbeddingExtractor? _speakerExtractor;
  sherpa.SpeakerEmbeddingManager? _speakerManager;

  bool _bindingsInitialized = false;
  final List<Float32List> _recentAudioHistory = [];
  int _historySamplesCount = 0;
  static const int _maxHistorySamples = 16000 * 3; // 3 секунды буфера для эмбеддинга

  void _ensureBindings() {
    if (_bindingsInitialized) return;
    try {
      sherpa.initBindings();
      _bindingsInitialized = true;
    } catch (e) {
      Log.error('SherpaEngine', 'Failed to init sherpa bindings: $e');
    }
  }

  @override
  bool get isReady => _spotter != null;

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
  }) async {
    _ensureBindings();
    if (!WakeWordModelPaths.isKwsInstalled) return false;

    try {
      _kwsStream?.free();
      _kwsStream = null;
      _spotter?.free();
      _spotter = null;

      final tokenizer = File(WakeWordModelPaths.kwsTokens).existsSync()
          ? KeywordTokenizer.fromTokensFile(
              File(WakeWordModelPaths.kwsTokens).readAsStringSync())
          : KeywordTokenizer();

      final keywordsList = [
        if (wakeWord.trim().isNotEmpty) wakeWord.trim(),
        if (closeWord.trim().isNotEmpty) closeWord.trim(),
      ];

      final keywordsStr = tokenizer.buildStreamKeywords(keywordsList);
      if (keywordsStr.isEmpty) return false;

      final config = sherpa.KeywordSpotterConfig(
        feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: WakeWordModelPaths.kwsEncoder,
            decoder: WakeWordModelPaths.kwsDecoder,
            joiner: WakeWordModelPaths.kwsJoiner,
          ),
          tokens: WakeWordModelPaths.kwsTokens,
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        maxActivePaths: 4,
        keywordsThreshold: 0.25,
        keywordsScore: 1.5,
      );

      _spotter = sherpa.KeywordSpotter(config);
      _kwsStream = _spotter!.createStream(keywords: keywordsStr);
      Log.info('SherpaEngine', 'KWS initialized with keywords: $keywordsStr');
      return true;
    } catch (e, st) {
      Log.error('SherpaEngine', 'initKeywordSpotter error: $e', e, st);
      return false;
    }
  }

  @override
  Future<bool> initVad() async {
    _ensureBindings();
    if (!WakeWordModelPaths.isVadInstalled) return false;

    try {
      _vad?.free();
      _vad = null;

      final vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: WakeWordModelPaths.vadOnnxPath,
          threshold: 0.25,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          windowSize: 512,
        ),
        sampleRate: 16000,
        numThreads: 1,
        provider: 'cpu',
      );

      _vad = sherpa.VoiceActivityDetector(
        config: vadConfig,
        bufferSizeInSeconds: 30,
      );
      return true;
    } catch (e, st) {
      Log.error('SherpaEngine', 'initVad error: $e', e, st);
      return false;
    }
  }

  @override
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  }) async {
    _ensureBindings();
    if (!WakeWordModelPaths.isSpeakerModelInstalled) return false;

    try {
      _speakerManager?.free();
      _speakerManager = null;
      _speakerExtractor?.free();
      _speakerExtractor = null;

      final extractorConfig = sherpa.SpeakerEmbeddingExtractorConfig(
        model: WakeWordModelPaths.speakerModelPath,
        numThreads: 1,
        provider: 'cpu',
      );

      final extractor = sherpa.SpeakerEmbeddingExtractor(config: extractorConfig);
      _speakerExtractor = extractor;

      final manager = sherpa.SpeakerEmbeddingManager(extractor.dim);
      _speakerManager = manager;

      if (enrolledEmbeddings != null && enrolledEmbeddings.isNotEmpty) {
        manager.addMulti(name: 'user', embeddingList: enrolledEmbeddings);
        Log.info('SherpaEngine', 'Enrolled ${enrolledEmbeddings.length} speaker embeddings');
      }

      return true;
    } catch (e, st) {
      Log.error('SherpaEngine', 'initSpeakerRecognition error: $e', e, st);
      return false;
    }
  }

  @override
  void acceptAudio(Float32List samples) {
    if (samples.isEmpty) return;

    // Ведём кольцевой буфер недавнего аудио для эмбеддинга спикера
    _recentAudioHistory.add(samples);
    _historySamplesCount += samples.length;
    while (_historySamplesCount > _maxHistorySamples && _recentAudioHistory.isNotEmpty) {
      final removed = _recentAudioHistory.removeAt(0);
      _historySamplesCount -= removed.length;
    }

    if (_vad != null) {
      _vad!.acceptWaveform(samples);
    }

    if (_spotter != null && _kwsStream != null) {
      _kwsStream!.acceptWaveform(samples: samples, sampleRate: 16000);
    }
  }

  @override
  bool isSpeech(Float32List samples) {
    if (_vad != null) {
      return _vad!.isDetected();
    }
    // Простой RMS fallback для энергоэффективности
    if (samples.isEmpty) return false;
    double sum = 0.0;
    for (var i = 0; i < samples.length; i++) {
      sum += samples[i] * samples[i];
    }
    final rms = sum / samples.length;
    return rms > 0.0001; // ~ -40 dB
  }

  @override
  KeywordDetection? detectKeyword() {
    final spotter = _spotter;
    final stream = _kwsStream;
    if (spotter == null || stream == null) return null;

    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      final res = spotter.getResult(stream);
      if (res.keyword.isNotEmpty) {
        final detected = res.keyword;
        spotter.reset(stream);

        // Собираем недавнее аудио для проверки голоса
        final totalLen = _historySamplesCount;
        final audioBuffer = Float32List(totalLen);
        var offset = 0;
        for (final chunk in _recentAudioHistory) {
          audioBuffer.setAll(offset, chunk);
          offset += chunk.length;
        }

        return KeywordDetection(keyword: detected, samples: audioBuffer);
      }
    }
    return null;
  }

  @override
  void resetKeywordStream() {
    if (_spotter != null && _kwsStream != null) {
      _spotter!.reset(_kwsStream!);
    }
  }

  @override
  Float32List? extractSpeakerEmbedding(Float32List audio) {
    final extractor = _speakerExtractor;
    if (extractor == null || audio.isEmpty) return null;

    try {
      final stream = extractor.createStream();
      stream.acceptWaveform(samples: audio, sampleRate: 16000);
      stream.inputFinished();
      if (!extractor.isReady(stream)) {
        stream.free();
        return null;
      }
      final emb = extractor.compute(stream);
      stream.free();
      return emb;
    } catch (e) {
      Log.error('SherpaEngine', 'extractSpeakerEmbedding error: $e');
      return null;
    }
  }

  @override
  bool verifySpeaker(Float32List embedding, double threshold) {
    final manager = _speakerManager;
    if (manager == null || manager.numSpeakers == 0) return true;
    try {
      return manager.verify(
        name: 'user',
        embedding: embedding,
        threshold: threshold,
      );
    } catch (e) {
      Log.error('SherpaEngine', 'verifySpeaker error: $e');
      return true;
    }
  }

  @override
  void dispose() {
    _kwsStream?.free();
    _kwsStream = null;
    _spotter?.free();
    _spotter = null;
    _vad?.free();
    _vad = null;
    _speakerManager?.free();
    _speakerManager = null;
    _speakerExtractor?.free();
    _speakerExtractor = null;
    _recentAudioHistory.clear();
    _historySamplesCount = 0;
  }
}

/// Тестовая реализация для юнит-тестов (работает полностью офлайн без FFI).
class FakeSherpaEngine implements SherpaEngine {
  bool spotterInitialized = false;
  bool vadInitialized = false;
  bool speakerInitialized = false;

  String configuredWakeWord = '';
  String configuredCloseWord = '';
  KeywordDetection? queuedDetection;
  bool speechDetected = false;
  double? forcedVerificationResult;

  @override
  bool get isReady => spotterInitialized;

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
  }) async {
    configuredWakeWord = wakeWord;
    configuredCloseWord = closeWord;
    spotterInitialized = true;
    return true;
  }

  @override
  Future<bool> initVad() async {
    vadInitialized = true;
    return true;
  }

  @override
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  }) async {
    speakerInitialized = true;
    return true;
  }

  @override
  void acceptAudio(Float32List samples) {}

  @override
  bool isSpeech(Float32List samples) => speechDetected;

  @override
  KeywordDetection? detectKeyword() {
    final res = queuedDetection;
    queuedDetection = null;
    return res;
  }

  @override
  void resetKeywordStream() {}

  @override
  Float32List? extractSpeakerEmbedding(Float32List audio) {
    return Float32List(192); // fake 192-dim embedding
  }

  @override
  bool verifySpeaker(Float32List embedding, double threshold) {
    if (forcedVerificationResult != null) {
      return forcedVerificationResult! >= threshold;
    }
    return true;
  }

  @override
  void dispose() {
    spotterInitialized = false;
    vadInitialized = false;
    speakerInitialized = false;
  }
}
