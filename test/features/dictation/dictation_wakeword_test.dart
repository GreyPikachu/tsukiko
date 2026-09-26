import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/audio_stream_source.dart';
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';
import 'package:tsukiko/core/wakeword/wakeword_service.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-dictation-wakeword');

  late _FakeNative native;
  late _FakeServer server;
  late FakeSherpaEngine engine;
  late FakeAudioStreamSource audioSource;
  late WakeWordService wakeWordService;
  late DictationCubit cubit;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    engine = FakeSherpaEngine();
    audioSource = FakeAudioStreamSource(permissionGranted: true);
    wakeWordService = WakeWordService(
      audioSource: audioSource,
      engine: engine,
    );

    NativeBridge.debugReset();
    cubit = DictationCubit(
      NativeBridge(),
      server: server,
      wakeWordService: wakeWordService,
    );
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('при включении wakeWord в настройках сервис запускает прослушивание', () async {
    expect(wakeWordService.isRunning, isFalse);

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
      closeWord: 'стоп',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    expect(wakeWordService.isRunning, isTrue);
    expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
    expect(engine.configuredWakeWord, 'Джеф');
    expect(engine.configuredCloseWord, 'стоп');
  });

  test('срабатывание WakeWord запускает запись диктовки', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    expect(cubit.state.recording, isFalse);

    // Имитируем триггер WakeWord от сервиса
    wakeWordService.onWakeWordTriggered?.call();
    await settle();

    expect(cubit.state.recording, isTrue);
    expect(wakeWordService.state, WakeWordListeningState.listeningCloseWordOrSilence);
  });

  test('срабатывание CloseWord останавливает запись и отрезает хвостовое слово', () async {
    server.text = 'Запиши встречу на завтра стоп.';

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
      closeWord: 'стоп',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    // Запускаем запись
    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(cubit.state.recording, isTrue);

    // Имитируем триггер CloseWord от сервиса
    wakeWordService.onCloseWordTriggered?.call();
    await cubit.stream.firstWhere((s) => s.phase == Phase.idle);

    expect(cubit.state.recording, isFalse);
    // Хвостовое слово «стоп.» должно быть отрезано из итогового текста
    expect(cubit.state.last, 'Запиши встречу на завтра');
    expect(native.pasted, 'Запиши встречу на завтра');
  });

  test('таймаут тишины останавливает запись', () async {
    server.text = 'Привет мир';

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(cubit.state.recording, isTrue);

    // Срабатывает таймаут тишины
    wakeWordService.onSilenceTimeoutTriggered?.call();
    await cubit.stream.firstWhere((s) => s.phase == Phase.idle);

    expect(cubit.state.recording, isFalse);
    expect(cubit.state.last, 'Привет мир');
  });

  test('отмена диктовки возвращает сервис в режим ожидания WakeWord', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(wakeWordService.state, WakeWordListeningState.listeningCloseWordOrSilence);

    await cubit.cancel();
    await settle();
    expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
  });

  test('выключение wakeWord в настройках останавливает сервис', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();
    expect(wakeWordService.isRunning, isTrue);

    DictationSettings(
      wakeWordEnabled: false,
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();
    expect(wakeWordService.isRunning, isFalse);
  });
}

class _FakeServer extends WhisperServer {
  String? text = 'распознанный текст';

  @override
  bool get up => false;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async => text;

  @override
  Future<void> shutdown() async {}

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

class _FakeNative {
  final calls = <String>[];
  String? pasted;
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'record':
          return '/tmp/test_dict.wav';
        case 'stopRecord':
          return null;
        case 'level':
          return 0.2;
        case 'permissions':
          return true;
        case 'paste':
          pasted = (call.arguments as Map)['text'] as String?;
          return true;
        case 'hud':
          return null;
        default:
          return null;
      }
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
