import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/audio_stream_source.dart';
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/wakeword_service.dart';
import 'package:tsukiko/core/whisper_server.dart';

void main() {
  late FakeSherpaEngine engine;
  late FakeAudioStreamSource audioSource;
  late WakeWordService service;

  setUp(() {
    engine = FakeSherpaEngine();
    audioSource = FakeAudioStreamSource(permissionGranted: true);
    service = WakeWordService(audioSource: audioSource, engine: engine);
  });

  tearDown(() async {
    await service.dispose();
  });

  // Вспомогательный буфер со звуковой энергией (RMS > 0.00005)
  Float32List makeAudio({double amp = 0.1, int length = 512}) {
    final list = Float32List(length);
    for (var i = 0; i < length; i++) {
      list[i] = (i % 2 == 0) ? amp : -amp;
    }
    return list;
  }

  // Буфер полной тишины (RMS == 0.0)
  Float32List makeSilence({int length = 512}) => Float32List(length);

  group('WakeWordService - запуск и остановка', () {
    test('не запускается, если wakeWordEnabled == false', () async {
      final settings = DictationSettings(wakeWordEnabled: false);
      final ok = await service.start(settings: settings);

      expect(ok, isFalse);
      expect(service.isRunning, isFalse);
      expect(service.state, WakeWordListeningState.disabled);
    });

    test('завершается с ошибкой, если микрофон запрещён', () async {
      audioSource.permissionGranted = false;
      String? reportedError;
      service.onError = (e) => reportedError = e;

      final settings = DictationSettings(wakeWordEnabled: true);
      final ok = await service.start(settings: settings);

      expect(ok, isFalse);
      expect(reportedError, contains('Microphone permission'));
      expect(service.isRunning, isFalse);
    });

    test('успешно стартует при наличии прав и включённой настройке', () async {
      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        closeWord: 'стоп',
      );

      final ok = await service.start(settings: settings);
      expect(ok, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.state, WakeWordListeningState.listeningWakeWord);
      expect(engine.configuredWakeWord, 'Джеф');
      expect(engine.configuredCloseWord, 'стоп');
    });

    test('stop() сбрасывает состояние в disabled', () async {
      final settings = DictationSettings(wakeWordEnabled: true);
      await service.start(settings: settings);
      expect(service.isRunning, isTrue);

      await service.stop();
      expect(service.isRunning, isFalse);
      expect(service.state, WakeWordListeningState.disabled);
      expect(engine.isReady, isFalse);
    });

    test(
      'diagnostics captures the detector stream and stops with service',
      () async {
        final root = Directory.systemTemp.createTempSync('wake-service-diag-');
        try {
          final settings = DictationSettings(
            wakeWordEnabled: true,
            wakeWord: 'Джефф',
            closeWord: 'Отбой',
          );
          await service.start(settings: settings);
          final path = service.startDiagnostics(root: root.path)!;
          service.markDiagnostics('wake');
          audioSource.pushSamples(makeAudio(length: 1600));
          await pumpEventQueue();
          service.notifyRecordingStarted();
          service.markDiagnostics('close');
          engine.queuedDetection = const KeywordDetection(keyword: 'Отбой');
          audioSource.pushSamples(makeAudio(length: 1600));
          await pumpEventQueue();
          await service.stop();

          expect(service.isDiagnosing, isFalse);
          expect(engine.isReady, isFalse);
          final wav = File('$path/audio.wav').readAsBytesSync();
          expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 6400);
          final events = File('$path/events.jsonl')
              .readAsLinesSync()
              .map((line) => jsonDecode(line) as Map<String, dynamic>)
              .toList();
          expect(
            events.where((event) => event['type'] == 'mark'),
            hasLength(2),
          );
          expect(
            events.any((event) => event['type'] == 'close_triggered'),
            isTrue,
          );
        } finally {
          root.deleteSync(recursive: true);
        }
      },
    );
  });

  group('WakeWordService - детекция слова активации', () {
    test('вызывает onWakeWordTriggered при распознавании wakeWord', () async {
      var triggered = false;
      service.onWakeWordTriggered = () => triggered = true;

      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
      );
      await service.start(settings: settings);

      // Очередь на распознавание слова
      engine.queuedDetection = const KeywordDetection(keyword: 'Джеф');

      // Подаём аудиофрейм
      audioSource.pushSamples(makeAudio());
      await pumpEventQueue();

      expect(triggered, isTrue);
    });

    test('результат KWS на тихом хвосте речи не теряется', () async {
      var triggered = false;
      service.onWakeWordTriggered = () => triggered = true;

      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
      );
      await service.start(settings: settings);

      engine.queuedDetection = KeywordDetection(keyword: 'Джеф');

      // Подаём нулевую тишину
      audioSource.pushSamples(makeSilence());
      await pumpEventQueue();

      // Потоковой модели нужны тихие кадры для завершения слова.
      expect(triggered, isTrue);
    });
  });

  group('WakeWordService - личная калибровка', () {
    test('устаревший голосовой профиль не блокирует найденное слово', () async {
      var triggered = false;
      service.onWakeWordTriggered = () => triggered = true;

      final profile = SpeakerProfile(
        name: 'user',
        dimension: 192,
        embeddings: [Float32List(192)],
      );

      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        voiceCalibrationEnabled: true,
        speakerThreshold: 0.70,
      );

      await service.start(settings: settings, profile: profile);

      engine.queuedDetection = KeywordDetection(
        keyword: 'Джеф',
        samples: makeAudio(length: 16000),
      );
      // Legacy aggregate voiceprints were unreliable on a moving stream.
      engine.forcedVerificationResult = 0.50;

      audioSource.pushSamples(makeAudio());
      await pumpEventQueue();

      expect(triggered, isTrue);
    });

    test('пропускает активацию, если верификация голоса успешна', () async {
      var triggered = false;
      service.onWakeWordTriggered = () => triggered = true;

      final profile = SpeakerProfile(
        name: 'user',
        dimension: 192,
        embeddings: [Float32List(192)],
      );

      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        voiceCalibrationEnabled: true,
        speakerThreshold: 0.70,
      );

      await service.start(settings: settings, profile: profile);

      engine.queuedDetection = KeywordDetection(
        keyword: 'Джеф',
        samples: makeAudio(length: 16000),
      );
      // Сходство выше порога
      engine.forcedVerificationResult = 0.85;

      audioSource.pushSamples(makeAudio());
      await pumpEventQueue();

      expect(triggered, isTrue, reason: 'Свой голос должен быть принят');
    });
  });

  group('WakeWordService - детекция CloseWord и таймер тишины', () {
    test(
      'notifyRecordingStarted переводит состояние в listeningCloseWordOrSilence',
      () async {
        final settings = DictationSettings(
          wakeWordEnabled: true,
          wakeWord: 'Джеф',
          closeWord: 'стоп',
        );
        await service.start(settings: settings);

        service.notifyRecordingStarted();
        expect(
          service.state,
          WakeWordListeningState.listeningCloseWordOrSilence,
        );

        service.notifyRecordingStopped();
        expect(service.state, WakeWordListeningState.listeningWakeWord);
      },
    );

    test(
      'вызывает onCloseWordTriggered при обнаружении слова завершения',
      () async {
        var closeTriggered = false;
        service.onCloseWordTriggered = () => closeTriggered = true;

        final settings = DictationSettings(
          wakeWordEnabled: true,
          wakeWord: 'Джеф',
          closeWord: 'стоп',
          completionMode: PhraseCompletionMode.hybrid,
        );
        await service.start(settings: settings);
        service.notifyRecordingStarted();

        engine.queuedDetection = KeywordDetection(keyword: 'стоп');
        audioSource.pushSamples(makeAudio());
        await pumpEventQueue();

        expect(closeTriggered, isTrue);
      },
    );

    test('в режиме silenceOnly детекция CloseWord игнорируется', () async {
      var closeTriggered = false;
      service.onCloseWordTriggered = () => closeTriggered = true;

      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        closeWord: 'стоп',
        completionMode: PhraseCompletionMode.silenceOnly,
      );
      await service.start(settings: settings);
      service.notifyRecordingStarted();

      engine.queuedDetection = KeywordDetection(keyword: 'стоп');
      audioSource.pushSamples(makeAudio());
      await pumpEventQueue();

      expect(closeTriggered, isFalse);
    });

    test(
      'срабатывает onSilenceTimeoutTriggered при паузе более 2 секунд',
      () async {
        var silenceTriggered = false;
        service.onSilenceTimeoutTriggered = () => silenceTriggered = true;

        final settings = DictationSettings(
          wakeWordEnabled: true,
          wakeWord: 'Джеф',
          completionMode: PhraseCompletionMode.silenceOnly,
        );
        await service.start(settings: settings);
        service.notifyRecordingStarted();

        // Обозначаем начало речи
        engine.speechDetected = true;
        audioSource.pushSamples(makeAudio());
        await pumpEventQueue();

        // Речь прекратилась
        engine.speechDetected = false;

        // Ждём 2100мс
        await Future<void>.delayed(const Duration(milliseconds: 2100));

        // Приходит следующий аудиофрейм тишины/шума
        audioSource.pushSamples(makeAudio());
        await pumpEventQueue();

        expect(silenceTriggered, isTrue);
      },
    );

    test(
      'в режиме closeWordOnly таймер тишины не останавливает запись',
      () async {
        var silenceTriggered = false;
        service.onSilenceTimeoutTriggered = () => silenceTriggered = true;

        final settings = DictationSettings(
          wakeWordEnabled: true,
          wakeWord: 'Джеф',
          closeWord: 'стоп',
          completionMode: PhraseCompletionMode.closeWordOnly,
        );
        await service.start(settings: settings);
        service.notifyRecordingStarted();

        // Обозначаем начало речи
        engine.speechDetected = true;
        audioSource.pushSamples(makeAudio());
        await pumpEventQueue();

        engine.speechDetected = false;
        await Future<void>.delayed(const Duration(milliseconds: 2100));

        audioSource.pushSamples(makeAudio());
        await pumpEventQueue();

        expect(silenceTriggered, isFalse);
      },
    );
  });
}
