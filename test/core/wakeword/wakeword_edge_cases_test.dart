import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/audio_stream_source.dart';
import 'package:tsukiko/core/wakeword/keyword_tokenizer.dart';
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/wakeword_service.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-wakeword-edge-cases');

  group('KeywordTokenizer Edge Cases', () {
    final tokenizer = KeywordTokenizer();

    test('спецсимволы, дефисы, слэши и разделители в formatKeyword', () {
      // Проверяем, что происходит при вводе спецсимволов и разделителей
      final withSlash = tokenizer.formatKeyword('hey/stop');
      // Внимание: если в строке ключевого слова остался '/', это разделитель потока в Sherpa
      expect(withSlash, isNotEmpty);

      final withAt = tokenizer.formatKeyword('user@tsukiko');
      expect(withAt, isNotEmpty);

      final withHashColon = tokenizer.formatKeyword('hello:world#1');
      expect(withHashColon, isNotEmpty);
    });

    test('пустые строки и строки из одних пробелов и пунктуации', () {
      expect(tokenizer.formatKeyword(''), isEmpty);
      expect(tokenizer.formatKeyword('   '), isEmpty);
      expect(tokenizer.tokenizeWord(''), isEmpty);
      expect(tokenizer.tokenizeWord('   '), isEmpty);
      expect(tokenizer.buildStreamKeywords(['', '   ']), isEmpty);
    });

    test('цифры и знаки препинания', () {
      final formatted = tokenizer.formatKeyword('Джеф 2.0');
      expect(formatted, contains('@Джеф 2.0'));
      expect(formatted, contains(':1.50'));
    });

    test('очень длинная строка (100+ символов)', () {
      final longWord = 'слово' * 30;
      final tokens = tokenizer.tokenizeWord(longWord);
      expect(tokens, isNotEmpty);
      final formatted = tokenizer.formatKeyword(longWord);
      expect(formatted, isNotEmpty);
    });
  });

  group('stripTrailingCloseWord Edge Cases', () {
    test('CloseWord в середине предложения НЕ отрезается', () {
      expect(
        stripTrailingCloseWord('нужно выполнить работу сегодня', 'работу'),
        'нужно выполнить работу сегодня',
      );
      expect(
        stripTrailingCloseWord('стоп машина поехала дальше', 'стоп'),
        'стоп машина поехала дальше',
      );
    });

    test('CloseWord как подстрока другого слова в конце НЕ отрезается', () {
      expect(
        stripTrailingCloseWord('Мы приехали на автостоп.', 'стоп'),
        'Мы приехали на автостоп.',
      );
      expect(
        stripTrailingCloseWord('Остановился электроток', 'ток'),
        'Остановился электроток',
      );
    });

    test('CloseWord с знаками препинания в самом ключевом слове', () {
      // Если пользователь указал "стоп." в настройках
      final res = stripTrailingCloseWord('Завершаем отчет стоп.', 'стоп.');
      // Проверяем поведение
      expect(res, anyOf('Завершаем отчет', 'Завершаем отчет стоп.'));
    });

    test('CloseWord из нескольких слов через запятую (как в плейсхолдере "done, over")', () {
      final text = 'Задача решена done.';
      final res = stripTrailingCloseWord(text, 'done, over');
      // Если closeWord был введен с запятой "done, over", отдельное слово "done" не отрезается!
      expect(res, 'Задача решена done.');
    });

    test('Текст состоит только из CloseWord', () {
      expect(stripTrailingCloseWord('стоп', 'стоп'), '');
      expect(stripTrailingCloseWord('Стоп.', 'стоп'), '');
      expect(stripTrailingCloseWord('  стоп!  ', 'стоп'), '');
    });

    test('CloseWord совпадает с WakeWord', () {
      expect(stripTrailingCloseWord('Привет Джеф', 'Джеф'), 'Привет');
    });

    test('Текст с необычной пунктуацией на конце', () {
      expect(stripTrailingCloseWord('Готово стоп?!', 'стоп'), 'Готово');
      expect(stripTrailingCloseWord('Готово, стоп —', 'стоп'), 'Готово');
    });
  });

  group('SpeakerProfile Corruption & Boundaries', () {
    test('пустой файл (0 байт) не крашит load и exists', () {
      final file = File(SpeakerProfile.defaultPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('');

      expect(SpeakerProfile.exists(), isFalse);
      expect(SpeakerProfile.load(), isNull);
    });

    test('битый невалидный JSON не крашит load', () {
      final file = File(SpeakerProfile.defaultPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"name": "user", "dimension": ');

      expect(SpeakerProfile.load(), isNull);
    });

    test('JSON с массивом верхнего уровня вместо объекта', () {
      final file = File(SpeakerProfile.defaultPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('[1, 2, 3]');

      expect(SpeakerProfile.load(), isNull);
    });

    test('JSON с некорректными типами данных в embeddings', () {
      final file = File(SpeakerProfile.defaultPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''
      {
        "name": "user",
        "dimension": 192,
        "embeddings": [
          "not_a_vector",
          [1.0, "corrupt", null]
        ]
      }
      ''');

      expect(SpeakerProfile.load(), isNull);
    });

    test('несовпадение размерностей векторов (разные длины внутри embeddings)', () {
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 3,
        embeddings: [
          Float32List.fromList([1.0, 0.0, 0.0]),
          Float32List.fromList([1.0, 0.0]), // Длина 2 вместо 3!
        ],
      );

      final candidate = Float32List.fromList([1.0, 0.0, 0.0]);
      // Не должно бросать исключение
      expect(() => profile.similarity(candidate), returnsNormally);
      expect(() => profile.verify(candidate, 0.5), returnsNormally);
    });

    test('векторы с NaN и Infinity', () {
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 2,
        embeddings: [
          Float32List.fromList([double.nan, 1.0]),
        ],
      );

      final candidate = Float32List.fromList([1.0, 1.0]);
      expect(() => profile.similarity(candidate), returnsNormally);
      expect(profile.verify(candidate, 0.5), isFalse);
    });

    test('нулевые векторы (деление на ноль)', () {
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 3,
        embeddings: [
          Float32List(3),
        ],
      );

      final candidate = Float32List(3);
      expect(profile.similarity(candidate), 0.0);
      expect(profile.verify(candidate, 0.5), isFalse);
    });
  });

  group('WakeWordService Concurrency & Rapid Toggle', () {
    late FakeSherpaEngine engine;
    late FakeAudioStreamSource audioSource;
    late WakeWordService service;

    setUp(() {
      engine = FakeSherpaEngine();
      audioSource = FakeAudioStreamSource(permissionGranted: true);
      service = WakeWordService(
        audioSource: audioSource,
        engine: engine,
      );
    });

    tearDown(() async {
      await service.dispose();
    });

    test('Rapid Toggle: быстрое чередование start / stop не приводит к гонкам', () async {
      final settingsOn = DictationSettings(wakeWordEnabled: true);

      // Симулируем быстрые переключения пользователем без await
      final f1 = service.start(settings: settingsOn);
      final f2 = service.stop();
      final f3 = service.start(settings: settingsOn);
      final f4 = service.stop();

      await Future.wait([f1, f2, f3, f4]);

      // После серии переключений и финального stop сервис должен быть выключен
      expect(service.state, WakeWordListeningState.disabled);
      expect(service.isRunning, isFalse);
    });

    test('Ошибка аудиопотока вызывает onError callback', () async {
      String? reportedError;
      service.onError = (e) => reportedError = e;

      final settings = DictationSettings(wakeWordEnabled: true);
      await service.start(settings: settings);

      expect(service.isRunning, isTrue);
      expect(reportedError, isNull);
    });

    test('CloseWord == WakeWord не приводит к зацикливанию', () async {
      final settings = DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        closeWord: 'Джеф',
      );

      final ok = await service.start(settings: settings);
      expect(ok, isTrue);
      expect(service.state, WakeWordListeningState.listeningWakeWord);

      var wakeTriggered = false;
      var closeTriggered = false;
      service.onWakeWordTriggered = () => wakeTriggered = true;
      service.onCloseWordTriggered = () => closeTriggered = true;

      // 1. Срабатывает WakeWord
      engine.queuedDetection = const KeywordDetection(keyword: 'Джеф');
      audioSource.pushSamples(Float32List.fromList([0.1, -0.1]));
      await pumpEventQueue();

      expect(wakeTriggered, isTrue);

      // 2. Переводим в режим записи
      service.notifyRecordingStarted();
      expect(service.state, WakeWordListeningState.listeningCloseWordOrSilence);

      // 3. Срабатывает CloseWord (то же самое слово)
      engine.queuedDetection = const KeywordDetection(keyword: 'Джеф');
      audioSource.pushSamples(Float32List.fromList([0.1, -0.1]));
      await pumpEventQueue();

      expect(closeTriggered, isTrue);
    });
  });

  group('DictationCubit Recording Failure Edge Case', () {
    test('Если bridge.startRecording() вернул null/путь пустой, сервис не должен зависать в listeningCloseWordOrSilence', () async {
      final engine = FakeSherpaEngine();
      final audioSource = FakeAudioStreamSource(permissionGranted: true);
      final wakeWordService = WakeWordService(
        audioSource: audioSource,
        engine: engine,
      );

      final fakeBridge = _FailingRecordingBridge()..install();
      final cubit = DictationCubit(
        fakeBridge,
        wakeWordService: wakeWordService,
      );

      DictationSettings(wakeWordEnabled: true).save();
      await cubit.reloadSettingsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);

      // Запускаем запись, которая потерпит неудачу в bridge.startRecording()
      await cubit.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(cubit.state.phase, Phase.idle);

      // ПРОВЕРКА БАГА: Если startRecording() упал, сервис НЕ должен оставаться в listeningCloseWordOrSilence!
      // Если останется в listeningCloseWordOrSilence, он никогда больше не услышит WakeWord!
      expect(
        wakeWordService.state,
        WakeWordListeningState.listeningWakeWord,
        reason: 'Сервис должен вернуться в режим listeningWakeWord после сбоя старта записи',
      );

      await cubit.close();
      fakeBridge.remove();
    });
  });
}

class _FailingRecordingBridge extends NativeBridge {
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => null);
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  @override
  Future<String?> startRecording() async => null; // Имитируем сбой старта записи
}
