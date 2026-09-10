import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/core/whisper.dart';

import '../../support/fake_os.dart';

/// Логика диктовки, которую до выноса из виджета проверять было нечем.
///
/// Родная сторона подменена: канал отвечает нашими значениями, и весь
/// разговор с macOS сводится к списку вызовов, который можно прочитать.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  useTempSupportDir('tsukiko-dictation-commands');

  late _FakeNative native;
  late _FakeServer server;
  late DictationCubit cubit;

  setUp(() {
    // Строки из кубита идут через currentL10n(), который читает системный
    // локаль. Тестовый движок отдаёт en_US — здесь же тексты сверены
    // с русским, поэтому закрепляем его явно.
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    // Мост в приложении один на изолят, и он это стережёт. Каждому тесту
    // нужен свой — снимаем сторожа.
    NativeBridge.debugReset();
    cubit = DictationCubit(NativeBridge(), server: server);
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  /// Дать очереди микрозадач провернуться: почти всё в кубите асинхронно.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('запись', () {
    test('фраза команды передаётся модели вместе с подсказкой', () async {
      await Settings.save({
        textCommandsSetting: [
          const TextCommand('адрес офиса', 'Минск').toJson(),
        ],
        dictationCommandsEnabledSetting: true,
      });
      await cubit.reloadSettingsForTesting();

      expect(cubit.optionsForTesting.effectivePrompt, contains('адрес офиса'));
    });

    test('начинается и переходит в распознавание', () async {
      await cubit.start();
      expect(cubit.state.phase, Phase.recording);
      expect(native.calls, contains('record'));

      await cubit.stop();
      expect(cubit.state.phase, Phase.idle);
    });

    test('второе нажатие во время записи ничего не начинает заново', () async {
      await cubit.start();
      final startedAt = cubit.state.elapsed;
      await cubit.start();
      expect(cubit.state.phase, Phase.recording);
      expect(cubit.state.elapsed, startedAt);
      // Микрофон просили ровно один раз.
      expect(native.calls.where((c) => c == 'record').length, 1);
    });

    test('отмена во время записи уходит молча и без вставки', () async {
      await cubit.start();
      await cubit.cancel();

      expect(cubit.state.phase, Phase.idle);
      expect(cubit.state.failure, isNull, reason: 'передумал — не беда');
      expect(native.calls, isNot(contains('paste')));
      expect(native.hudStates.last, 'hidden');
    });

    test('короткое нажатие не оставляет панель в «Записываю»', () async {
      // Между «нажали» и «микрофон пишет» проходит время. Клавишу успевали
      // отпустить в этом промежутке: stop видел покой и выходил, а start
      // следом ставил «запись» — и панель писала её вечно.
      native.recordDelay = const Duration(milliseconds: 60);

      final starting = cubit.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        cubit.state.phase,
        Phase.recording,
        reason: 'реакция видна сразу, пока система поднимает микрофон',
      );
      await cubit.stop();
      await starting;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(cubit.state.phase, Phase.idle, reason: 'микрофон уже молчит');
    });

    test(
      'ошибка запуска микрофона не выдаётся за сохранённую запись',
      () async {
        native.recordPath = '';

        await cubit.start();

        expect(cubit.state.phase, Phase.idle);
        expect(cubit.state.failure, contains('Не удалось запустить микрофон'));
        expect(native.hudStates.last, 'failed');
        expect(native.calls, isNot(contains('stopRecord')));
      },
    );

    test('отмена не из записи ничего не делает', () async {
      await cubit.cancel();
      expect(cubit.state.phase, Phase.idle);
      expect(native.calls, isNot(contains('stopRecord')));
    });
  });

  group('вставка текста', () {
    test('голосовая команда заменяется перед вставкой', () async {
      await Settings.save({
        textCommandsSetting: [
          const TextCommand('сказанное вслух', 'Минск, Немига, 1').toJson(),
        ],
        dictationCommandsEnabledSetting: true,
      });
      await cubit.reloadSettingsForTesting();

      await cubit.start();
      await cubit.stop();

      expect(cubit.state.last, 'Минск, Немига, 1');
      expect(native.pasted, 'Минск, Немига, 1');
    });

    test(
      'выключатель диктовки оставляет распознанную фразу как есть',
      () async {
        await Settings.save({
          textCommandsSetting: [
            const TextCommand('сказанное вслух', 'замена').toJson(),
          ],
          dictationCommandsEnabledSetting: false,
        });
        await cubit.reloadSettingsForTesting();

        await cubit.start();
        await cubit.stop();

        expect(cubit.state.last, 'сказанное вслух');
        expect(native.pasted, 'сказанное вслух');
      },
    );

    test(
      'не удалась — текст не теряется, а уходит в буфер и в предупреждение',
      () async {
        native.pasteSucceeds = false;
        await cubit.start();
        await cubit.stop();

        // Раньше сторона macOS отвечала «получилось» всегда, и панель
        // показывала галочку над пропавшим текстом.
        expect(cubit.state.failure, contains('буфер обмена'));
        expect(
          cubit.state.failurePath,
          isNull,
          reason: 'запись тут ни при чём',
        );
        expect(native.hudStates.last, 'copied');
      },
    );

    test('удалась — панель говорит «Готово» и молчит про беду', () async {
      await cubit.start();
      await cubit.stop();

      expect(cubit.state.failure, isNull);
      expect(native.hudStates.last, 'done');
    });
  });

  group('отмена распознавания', () {
    test('работает только в фазе распознавания', () async {
      await cubit.abortTranscription();
      expect(native.calls, isNot(contains('hud')));

      await cubit.start();
      await cubit.abortTranscription();
      expect(
        cubit.state.phase,
        Phase.recording,
        reason: 'во время записи отменяют иначе — кнопкой «Отменить»',
      );
    });
  });

  group('разрешения', () {
    test('одному «нет» не верим, третьему верим', () async {
      await settle();
      native.permitted = false;

      // Сразу после запуска система отвечает «нет» и тем, кто всё давно
      // разрешил: процесс ещё не осел. Плашка на пустом месте пугает зря.
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'первому отказу не верим');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'второму тоже');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isFalse, reason: 'третий отказ — уже правда');

      // А любому «да» верим сразу.
      native.permitted = true;
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue);
    });
  });

  group('состояние', () {
    test('равные снимки не заставляют панель перерисовываться', () {
      const a = DictationState(phase: Phase.idle, last: 'раз');
      const b = DictationState(phase: Phase.idle, last: 'раз');
      // На этом держится вся экономия: во время записи снимок приходит
      // десять раз в секунду, и одинаковые перерисовывать нечего.
      expect(a, b);
      expect(a.copyWith(last: 'два'), isNot(b));
    });

    test('очистка полей отличима от «не передали»', () {
      const withFailure = DictationState(
        failure: 'беда',
        failurePath: '/tmp/a.wav',
      );
      expect(withFailure.copyWith(last: 'x').failure, 'беда');
      expect(withFailure.copyWith(clearFailure: true).failure, isNull);
      expect(withFailure.copyWith(clearFailure: true).failurePath, isNull);
    });

    test('выбирать модель есть из чего при любом их числе', () {
      // Раньше здесь была пара «быстрая · точная», и выбор показывался,
      // только когда моделей ровно две. Одна или три — и переключателя
      // не было вовсе, хотя выбирать было из чего.
      expect(const DictationState().hasModels, isFalse);
      expect(const DictationState(models: ['/m.bin']).hasModels, isTrue);
      const three = DictationState(models: ['/a.bin', '/b.bin', '/c.bin']);
      expect(three.models.length, 3);
      // Список входит в сравнение состояний: без этого смена набора
      // моделей не доходила бы до перерисовки панели.
      expect(
        three == const DictationState(models: ['/a.bin', '/b.bin']),
        isFalse,
      );
    });
  });
}

/// Подставной сервер: настоящий поднял бы процесс и прочитал в память
/// полтора гигабайта модели — в тестах это ни к чему.
class _FakeServer extends WhisperServer {
  /// Что «распознала» модель. null — не удалось, как при обрыве.
  String? text = 'сказанное вслух';
  var shutdowns = 0;

  @override
  bool get up => false;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async => text;

  @override
  Future<void> shutdown() async => shutdowns++;

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

/// Подставная родная сторона: отвечает на вызовы канала и запоминает их.
class _FakeNative {
  final calls = <String>[];
  final hudStates = <String>[];

  bool permitted = true;
  bool pasteSucceeds = true;
  String? pasted;

  /// Насколько система тянет с ответом «микрофон готов».
  Duration recordDelay = Duration.zero;
  String? recordPath = '/tmp/тест-диктовки.wav';

  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'record':
              if (recordDelay > Duration.zero) {
                await Future<void>.delayed(recordDelay);
              }
              return recordPath;
            case 'stopRecord':
              return null;
            case 'level':
              return 0.3;
            case 'permissions':
              return permitted;
            case 'paste':
              pasted = (call.arguments as Map)['text'] as String?;
              return pasteSucceeds;
            case 'hud':
              hudStates.add((call.arguments as Map)['state'] as String);
              return null;
            case 'requestModel':
              return true;
            case 'trash':
              return true;
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
