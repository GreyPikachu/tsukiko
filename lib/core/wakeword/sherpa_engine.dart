import 'dart:math' as math;
import 'dart:typed_data';

import '../logger.dart';
import 'acoustic_feature_extractor.dart';
import 'adaptive_noise_filter.dart';
import 'speech_verifier.dart';

/// Результат распознавания ключевого слова.
class KeywordDetection {
  const KeywordDetection({
    required this.keyword,
    this.samples,
  });

  final String keyword;
  final Float32List? samples;
}

/// Абстракция над движком распознавания ключевых слов и голоса.
///
/// Позволяет подменять движок в тестах (`FakeSherpaEngine`),
/// гарантируя полную изоляцию от микрофона и файловой системы.
abstract class SherpaEngine {
  bool get isReady;

  /// Инициализировать детектор ключевых слов.
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
  });

  /// Инициализировать детектор активности речи (VAD).
  Future<bool> initVad();

  /// Инициализировать систему верификации спикера.
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  });

  /// Передать порцию сэмплов в движок (16 кГц, моно).
  void acceptAudio(Float32List samples);

  /// Проверить наличие речи в аудио.
  bool isSpeech(Float32List samples);

  /// Проверить, сработало ли ключевое слово на текущем шаге.
  KeywordDetection? detectKeyword();

  /// Сбросить состояние потока ключевых слов.
  void resetKeywordStream();

  /// Извлечь эмбеддинг спикера из аудиофрагмента.
  Float32List? extractSpeakerEmbedding(Float32List audio);

  /// Проверить, принадлежит ли голос пользователю по порогу сходства.
  bool verifySpeaker(Float32List embedding, double threshold);

  /// Освободить ресурсы.
  void dispose();
}

/// Реальная реализация на базе встроенного в Tsukiko движка распознавания
/// и акустического фильтра фонового шума.
class NativeSherpaEngine implements SherpaEngine {
  NativeSherpaEngine({
    SpeechVerifier? verifier,
    AdaptiveNoiseFilter? noiseFilter,
  })  : _verifier = verifier ?? SpeechVerifier(),
        _noiseFilter = noiseFilter ?? AdaptiveNoiseFilter();

  final SpeechVerifier _verifier;
  final AdaptiveNoiseFilter _noiseFilter;

  String _wakeWord = '';
  String _closeWord = '';
  bool _ready = false;

  final List<Float32List> _enrolledEmbeddings = [];

  // Кольцевой пред-буфер для сохранения начала слова (200 мс = 3200 сэмплов)
  final List<Float32List> _preRoll = [];
  int _preRollSamples = 0;
  static const int _maxPreRollSamples = 3200;

  // Буфер для накопления речи при обнаружении активности
  final List<Float32List> _speechBuffer = [];
  int _speechBufferSamples = 0;
  static const int _maxSpeechBufferSamples = 16000 * 3; // до 3 секунд
  static const int _minSpeechBufferSamples = 16000 ~/ 4; // от 0.25 секунды

  int _silenceSamples = 0;
  KeywordDetection? _lastDetection;
  bool _isProcessing = false;

  @override
  bool get isReady => _ready;

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
  }) async {
    _wakeWord = wakeWord.trim();
    _closeWord = closeWord.trim();
    _preRoll.clear();
    _preRollSamples = 0;
    _speechBuffer.clear();
    _speechBufferSamples = 0;
    _silenceSamples = 0;
    _lastDetection = null;
    _ready = true;
    Log.info('NativeWakeWordEngine', 'Initialized with wakeWord: "$_wakeWord", closeWord: "$_closeWord"');
    return true;
  }

  @override
  Future<bool> initVad() async {
    _noiseFilter.reset();
    return true;
  }

  @override
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  }) async {
    _enrolledEmbeddings.clear();
    if (enrolledEmbeddings != null) {
      _enrolledEmbeddings.addAll(enrolledEmbeddings);
    }
    return true;
  }

  @override
  void acceptAudio(Float32List samples) {
    if (!_ready || samples.isEmpty) return;

    final speechActive = _noiseFilter.isSpeech(samples);

    if (speechActive) {
      _silenceSamples = 0;

      // Если речь только началась, прицепляем пред-буфер (чтобы не отрезать начало слова)
      if (_speechBuffer.isEmpty && _preRoll.isNotEmpty) {
        _speechBuffer.addAll(_preRoll);
        _speechBufferSamples += _preRollSamples;
        _preRoll.clear();
        _preRollSamples = 0;
      }

      _speechBuffer.add(samples);
      _speechBufferSamples += samples.length;

      // Если фраза затянулась дольше максимального окна, обрабатываем накопленное
      if (_speechBufferSamples >= _maxSpeechBufferSamples && !_isProcessing) {
        _processSpeechBurst();
      }
    } else {
      // Ведём кольцевой пред-буфер на случай начала речи
      _preRoll.add(samples);
      _preRollSamples += samples.length;
      while (_preRollSamples > _maxPreRollSamples && _preRoll.isNotEmpty) {
        final removed = _preRoll.removeAt(0);
        _preRollSamples -= removed.length;
      }

      if (_speechBufferSamples > 0) {
        _silenceSamples += samples.length;

        // Захватываем хвостик тишины (до 200 мс), чтобы не обрезать конечное согласное
        if (_silenceSamples <= 3200) {
          _speechBuffer.add(samples);
          _speechBufferSamples += samples.length;
        }

        // Если после речи наступила пауза >= 300 мс тишины (4800 сэмплов) — фраза завершилась
        if (_silenceSamples >= 4800 && !_isProcessing) {
          _processSpeechBurst();
        }
      }
    }
  }

  void _processSpeechBurst() {
    if (_speechBufferSamples < _minSpeechBufferSamples) {
      _speechBuffer.clear();
      _speechBufferSamples = 0;
      _silenceSamples = 0;
      return;
    }

    final total = _speechBufferSamples;
    final combined = Float32List(total);
    var offset = 0;
    for (final chunk in _speechBuffer) {
      combined.setAll(offset, chunk);
      offset += chunk.length;
    }

    _speechBuffer.clear();
    _speechBufferSamples = 0;
    _silenceSamples = 0;
    _isProcessing = true;

    // Асинхронно проверяем через Whisper
    _verifier.verifySamples(combined, targetWord: _wakeWord).then((res) {
      _isProcessing = false;
      if (res.matched) {
        _lastDetection = KeywordDetection(keyword: _wakeWord, samples: combined);
      } else if (_closeWord.isNotEmpty) {
        // Проверяем CloseWord
        if (SpeechVerifier.matchesKeyword(res.recognizedText, _closeWord)) {
          _lastDetection = KeywordDetection(keyword: _closeWord, samples: combined);
        }
      }
    }).catchError((Object e) {
      _isProcessing = false;
      Log.error('NativeWakeWordEngine', 'Error verifying speech burst: $e');
    });
  }

  @override
  bool isSpeech(Float32List samples) {
    return _noiseFilter.isSpeech(samples);
  }

  @override
  KeywordDetection? detectKeyword() {
    final det = _lastDetection;
    _lastDetection = null;
    return det;
  }

  @override
  void resetKeywordStream() {
    _preRoll.clear();
    _preRollSamples = 0;
    _speechBuffer.clear();
    _speechBufferSamples = 0;
    _silenceSamples = 0;
    _lastDetection = null;
  }

  @override
  Float32List? extractSpeakerEmbedding(Float32List audio) {
    if (audio.isEmpty) return null;
    try {
      return AcousticFeatureExtractor.extract(audio);
    } catch (e) {
      Log.error('NativeWakeWordEngine', 'Error extracting acoustic embedding: $e');
      return null;
    }
  }

  @override
  bool verifySpeaker(Float32List embedding, double threshold) {
    if (_enrolledEmbeddings.isEmpty) return true;

    double maxSim = -1.0;
    double sum = 0.0;
    for (final enrolled in _enrolledEmbeddings) {
      final sim = _cosineSimilarity(enrolled, embedding);
      if (sim > maxSim) maxSim = sim;
      sum += sim;
    }

    final avg = sum / _enrolledEmbeddings.length;
    final score = 0.7 * maxSim + 0.3 * avg;
    return score >= threshold;
  }

  static double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      dot += x * y;
      normA += x * x;
      normB += y * y;
    }

    if (normA <= 0.0 || normB <= 0.0) return 0.0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  @override
  void dispose() {
    _ready = false;
    _speechBuffer.clear();
    _speechBufferSamples = 0;
    _enrolledEmbeddings.clear();
    _lastDetection = null;
  }
}

/// Тестовая реализация для юнит-тестов (офлайн).
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
    return Float32List(192);
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
