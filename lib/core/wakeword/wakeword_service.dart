import 'dart:async';
import 'dart:typed_data';

import '../logger.dart';
import '../whisper_server.dart' show DictationSettings, PhraseCompletionMode;
import 'audio_stream_source.dart';
import 'sherpa_engine.dart';
import 'speaker_profile.dart';

/// В каком состоянии находится голосовая активация.
enum WakeWordListeningState {
  disabled,
  listeningWakeWord,
  listeningCloseWordOrSilence,
}

/// Сервис фоновой голосовой активации (WakeWord) и завершающего слова (CloseWord).
///
/// Управляет аудиопотоком, распознаванием ключевых слов через Sherpa-ONNX,
/// верификацией профиля голоса и таймером тишины для завершения фразы.
class WakeWordService {
  WakeWordService({
    AudioStreamSource? audioSource,
    SherpaEngine? engine,
  })  : _audioSource = audioSource ?? MicrophoneAudioStreamSource(),
        _engine = engine ?? NativeSherpaEngine();

  final AudioStreamSource _audioSource;
  final SherpaEngine _engine;

  WakeWordListeningState _state = WakeWordListeningState.disabled;
  WakeWordListeningState get state => _state;

  StreamSubscription<Float32List>? _audioSub;
  DictationSettings? _settings;
  SpeakerProfile? _profile;

  // Обратные вызовы для кубита диктовки
  void Function()? onWakeWordTriggered;
  void Function()? onCloseWordTriggered;
  void Function()? onSilenceTimeoutTriggered;
  void Function(String error)? onError;

  /// Время последней зафиксированной речи для таймера тишины (2.0 секунды).
  DateTime? _lastSpeechTime;
  static const Duration silenceThreshold = Duration(milliseconds: 2000);

  /// Запущен ли сервис.
  bool get isRunning => _state != WakeWordListeningState.disabled;

  /// Запустить сервис голосовой активации с указанными настройками.
  Future<bool> start({
    required DictationSettings settings,
    SpeakerProfile? profile,
  }) async {
    await stop();
    _settings = settings;
    _profile = profile ?? SpeakerProfile.load();

    if (!settings.wakeWordEnabled) {
      _state = WakeWordListeningState.disabled;
      return false;
    }

    final hasPerm = await _audioSource.hasPermission();
    if (!hasPerm) {
      Log.warn('WakeWord', 'Microphone permission not granted for WakeWord');
      onError?.call('Microphone permission not granted');
      return false;
    }

    // Инициализируем KWS
    final kwsOk = await _engine.initKeywordSpotter(
      wakeWord: settings.wakeWord,
      closeWord: settings.closeWord,
    );

    if (!kwsOk) {
      Log.warn('WakeWord', 'Failed to initialize SherpaOnnx KeywordSpotter');
      onError?.call('Failed to initialize KeywordSpotter');
      return false;
    }

    // Инициализируем VAD
    await _engine.initVad();

    // Инициализируем верификацию спикера (если есть профиль)
    if (_profile != null && _profile!.embeddings.isNotEmpty) {
      await _engine.initSpeakerRecognition(
        enrolledEmbeddings: _profile!.embeddings,
      );
    }

    // Запускаем аудиопоток
    try {
      final stream = await _audioSource.startStream(sampleRate: 16000);
      _audioSub = stream.listen(
        _onAudioFrame,
        onError: (Object e) {
          Log.error('WakeWord', 'Audio stream error: $e');
          onError?.call('$e');
        },
      );
      _state = WakeWordListeningState.listeningWakeWord;
      Log.info('WakeWord', 'WakeWord service listening for "${settings.wakeWord}"');
      return true;
    } catch (e, st) {
      Log.error('WakeWord', 'Failed to start audio stream: $e', e, st);
      await stop();
      return false;
    }
  }

  /// Уведомить сервис, что началась запись фразы (диктовка активна).
  void notifyRecordingStarted() {
    if (_state == WakeWordListeningState.disabled) return;
    _state = WakeWordListeningState.listeningCloseWordOrSilence;
    _lastSpeechTime = DateTime.now();
    _engine.resetKeywordStream();
    Log.info('WakeWord', 'Now listening for CloseWord or silence...');
  }

  /// Уведомить сервис, что запись завершилась (диктовка остановлена).
  void notifyRecordingStopped() {
    if (_state == WakeWordListeningState.disabled) return;
    _state = WakeWordListeningState.listeningWakeWord;
    _lastSpeechTime = null;
    _engine.resetKeywordStream();
    Log.info('WakeWord', 'Returned to listening for WakeWord');
  }

  /// Обработка порции аудио с микрофона.
  void _onAudioFrame(Float32List samples) {
    if (_state == WakeWordListeningState.disabled || samples.isEmpty) return;

    // Быстрый фильтр энергии RMS для минимизации CPU в полной тишине
    double sum = 0.0;
    for (var i = 0; i < samples.length; i++) {
      sum += samples[i] * samples[i];
    }
    final rms = sum / samples.length;

    // Если комната абсолютно бесшумна, не грузим нейросеть
    final bool hasAudioEnergy = rms > 0.00005;
    if (hasAudioEnergy) {
      _engine.acceptAudio(samples);
    }

    final now = DateTime.now();
    final bool isSpeech = hasAudioEnergy && _engine.isSpeech(samples);
    if (isSpeech) {
      _lastSpeechTime = now;
    }

    // ── 1. Режим ожидания слова активации (WakeWord) ──────────────────────────
    if (_state == WakeWordListeningState.listeningWakeWord) {
      if (!hasAudioEnergy) return;

      final detection = _engine.detectKeyword();
      if (detection != null) {
        final detected = detection.keyword.trim().toLowerCase();
        final expected = (_settings?.wakeWord ?? '').trim().toLowerCase();

        if (detected == expected || detected.isNotEmpty) {
          Log.info('WakeWord', 'Spotted keyword: "$detected" (expected: "$expected")');

          // Верификация по профилю голоса
          final settings = _settings;
          if (settings != null &&
              settings.voiceCalibrationEnabled &&
              _profile != null &&
              _profile!.embeddings.isNotEmpty &&
              detection.samples != null) {
            final emb = _engine.extractSpeakerEmbedding(detection.samples!);
            if (emb != null) {
              final verified = _engine.verifySpeaker(emb, settings.speakerThreshold);
              if (!verified) {
                Log.info('WakeWord', 'Keyword detected but speaker verification failed (rejected)');
                return;
              }
              Log.info('WakeWord', 'Speaker verified successfully');
            }
          }

          // Активируем диктовку
          onWakeWordTriggered?.call();
        }
      }
      return;
    }

    // ── 2. Режим ожидания слова завершения (CloseWord) или тишины ──────────────
    if (_state == WakeWordListeningState.listeningCloseWordOrSilence) {
      final settings = _settings;
      if (settings == null) return;

      final mode = settings.completionMode;
      final closeWord = settings.closeWord.trim().toLowerCase();

      // Проверка на CloseWord
      if (closeWord.isNotEmpty &&
          (mode == PhraseCompletionMode.closeWordOnly ||
              mode == PhraseCompletionMode.hybrid)) {
        if (hasAudioEnergy) {
          final detection = _engine.detectKeyword();
          if (detection != null) {
            final detected = detection.keyword.trim().toLowerCase();
            if (detected == closeWord) {
              Log.info('WakeWord', 'CloseWord "$closeWord" detected! Stopping dictation.');
              onCloseWordTriggered?.call();
              return;
            }
          }
        }
      }

      // Проверка на тишину (2.0 секунды)
      if (mode == PhraseCompletionMode.silenceOnly ||
          mode == PhraseCompletionMode.hybrid ||
          closeWord.isEmpty) {
        if (_lastSpeechTime != null) {
          final silenceDuration = now.difference(_lastSpeechTime!);
          if (silenceDuration >= silenceThreshold) {
            Log.info(
              'WakeWord',
              'Silence timeout (${silenceDuration.inMilliseconds}ms >= ${silenceThreshold.inMilliseconds}ms). Stopping dictation.',
            );
            _lastSpeechTime = null;
            onSilenceTimeoutTriggered?.call();
            return;
          }
        }
      }
    }
  }

  /// Остановить сервис.
  Future<void> stop() async {
    _state = WakeWordListeningState.disabled;
    await _audioSub?.cancel();
    _audioSub = null;
    await _audioSource.stopStream();
    _engine.resetKeywordStream();
  }

  /// Полное освобождение памяти и процессов.
  Future<void> dispose() async {
    await stop();
    await _audioSource.dispose();
    _engine.dispose();
  }
}
