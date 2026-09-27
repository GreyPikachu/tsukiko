import 'dart:async';
import 'dart:typed_data';

import '../logger.dart';
import '../whisper_server.dart' show DictationSettings, PhraseCompletionMode;
import 'audio_stream_source.dart';
import 'keyword_tokenizer.dart';
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
/// Управляет аудиопотоком, персональным детектором ключевых слов и таймером
/// тишины для завершения фразы. Для старого профиля возможен Sherpa fallback.
class WakeWordService {
  WakeWordService({AudioStreamSource? audioSource, SherpaEngine? engine})
    : _audioSource = audioSource ?? MicrophoneAudioStreamSource(),
      _engine = engine ?? StreamingSherpaEngine();

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

  int _operationGeneration = 0;
  bool _triggeredInCurrentState = false;
  DateTime? _lastCompletionAt;
  static const Duration retriggerDelay = Duration(milliseconds: 700);

  /// Запустить сервис голосовой активации с указанными настройками.
  Future<bool> start({
    required DictationSettings settings,
    SpeakerProfile? profile,
  }) async {
    if (!settings.wakeWordEnabled) {
      await stop();
      return false;
    }

    final nextProfile = profile ?? SpeakerProfile.load();
    // A new calibration changes the detector itself, so rebuild its stream.
    if (_state != WakeWordListeningState.disabled &&
        _settings?.wakeWord == settings.wakeWord &&
        _settings?.closeWord == settings.closeWord &&
        _profile?.createdAt == nextProfile?.createdAt) {
      _settings = settings;
      _profile = nextProfile;
      return true;
    }

    final generation = ++_operationGeneration;
    await stop(invalidate: false);
    if (_operationGeneration != generation) return false;

    _settings = settings;
    _profile = nextProfile;

    final hasPerm = await _audioSource.hasPermission();
    if (_operationGeneration != generation) return false;
    if (!hasPerm) {
      Log.warn('WakeWord', 'Microphone permission not granted for WakeWord');
      onError?.call('Microphone permission not granted');
      return false;
    }

    // Инициализируем KWS
    final kwsOk = await _engine.initKeywordSpotter(
      wakeWord: settings.wakeWord,
      closeWord: settings.closeWord,
      profile: _profile,
    );
    if (_operationGeneration != generation) return false;

    if (!kwsOk) {
      Log.warn('WakeWord', 'Failed to initialize SherpaOnnx KeywordSpotter');
      onError?.call('Failed to initialize KeywordSpotter');
      return false;
    }

    // Инициализируем VAD
    await _engine.initVad();
    if (_operationGeneration != generation) return false;

    // Personal templates include the speaker's pronunciation. Legacy
    // aggregate voiceprints caused false rejections and are not used.
    await _engine.initSpeakerRecognition();
    if (_operationGeneration != generation) return false;

    // Запускаем аудиопоток
    try {
      final stream = await _audioSource.startStream(sampleRate: 16000);
      if (_operationGeneration != generation) {
        await _audioSource.stopStream();
        return false;
      }
      await _audioSub?.cancel();
      _audioSub = stream.listen(
        _onAudioFrame,
        onError: (Object e) {
          Log.error('WakeWord', 'Audio stream error: $e');
          onError?.call('$e');
        },
      );
      _state = WakeWordListeningState.listeningWakeWord;
      _triggeredInCurrentState = false;
      Log.info(
        'WakeWord',
        'WakeWord service listening for "${settings.wakeWord}"',
      );
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
    _triggeredInCurrentState = false;
    _lastSpeechTime = DateTime.now();
    _engine.resetKeywordStream();
    Log.info('WakeWord', 'Now listening for CloseWord or silence...');
  }

  /// Уведомить сервис, что запись завершилась (диктовка остановлена).
  void notifyRecordingStopped() {
    if (_state == WakeWordListeningState.disabled) return;
    _state = WakeWordListeningState.listeningWakeWord;
    _triggeredInCurrentState = false;
    _lastCompletionAt = DateTime.now();
    _lastSpeechTime = null;
    _engine.resetKeywordStream();
    Log.info('WakeWord', 'Returned to listening for WakeWord');
  }

  /// Обработка порции аудио с микрофона.
  void _onAudioFrame(Float32List samples) {
    if (_state == WakeWordListeningState.disabled || samples.isEmpty) return;

    // KWS получает и тихие кадры: они нужны для завершения слова.
    // isSpeech ниже отдельно обновляет адаптивный шумовой фон.
    _engine.acceptAudio(samples);

    final now = DateTime.now();
    final bool isSpeech = _engine.isSpeech(samples);
    if (isSpeech) {
      _lastSpeechTime = now;
    }

    // ── 1. Режим ожидания слова активации (WakeWord) ──────────────────────────
    if (_state == WakeWordListeningState.listeningWakeWord) {
      final detection = _engine.detectKeyword();
      if (detection != null && !_triggeredInCurrentState) {
        if (_lastCompletionAt != null &&
            now.difference(_lastCompletionAt!) < retriggerDelay) {
          return;
        }
        _lastSpeechTime = null;
        final detected = KeywordTokenizer.normalizeKeywordText(
          detection.keyword,
        );
        final expected = KeywordTokenizer.normalizeKeywordText(
          _settings?.wakeWord ?? '',
        );

        if (detected == expected) {
          Log.info(
            'WakeWord',
            'Spotted keyword: "$detected" (expected: "$expected")',
          );

          // Активируем диктовку
          _triggeredInCurrentState = true;
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
      final closeWord = KeywordTokenizer.normalizeKeywordText(
        settings.closeWord,
      );

      // Проверка на CloseWord
      if (closeWord.isNotEmpty &&
          (mode == PhraseCompletionMode.closeWordOnly ||
              mode == PhraseCompletionMode.hybrid)) {
        if (!_triggeredInCurrentState) {
          final detection = _engine.detectKeyword();
          if (detection != null) {
            final detected = KeywordTokenizer.normalizeKeywordText(
              detection.keyword,
            );
            if (detected == closeWord) {
              Log.info(
                'WakeWord',
                'CloseWord "$closeWord" detected! Stopping dictation.',
              );
              _triggeredInCurrentState = true;
              _lastCompletionAt = now;
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
            _triggeredInCurrentState = true;
            _lastCompletionAt = now;
            onSilenceTimeoutTriggered?.call();
            return;
          }
        }
      }
    }
  }

  /// Остановить сервис.
  Future<void> stop({bool invalidate = true}) async {
    if (invalidate) _operationGeneration++;
    _state = WakeWordListeningState.disabled;
    _triggeredInCurrentState = false;
    await _audioSub?.cancel();
    _audioSub = null;
    await _audioSource.stopStream();
    _engine.resetKeywordStream();
  }

  /// Полное освобождение памяти и процессов.
  Future<void> dispose() async {
    _operationGeneration++;
    await stop();
    await _audioSource.dispose();
    _engine.dispose();
  }
}
