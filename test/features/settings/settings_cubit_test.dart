import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/api/api_server.dart' show apiKeySetting;
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/features/settings/settings_state.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

/// Окно настроек. До выноса из виджета проверять было нечем: каждая галка
/// сидела в `setState` и не отделялась от раскладки.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late SettingsCubit cubit;

  // Настройки живут в папке приложения, и без подмены тест правил бы
  // настоящие настройки пользователя.
  useTempSupportDir('tsukiko-settings-app');

  setUp(() {
    // Строки из кубита идут через currentL10n(), который читает системный
    // локаль. Тестовый движок сбрасывает её перед каждым тестом на en_US —
    // здесь же тексты сверены с русским, поэтому закрепляем его явно.
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    NativeBridge.debugReset();
    cubit = SettingsCubit(NativeBridge());
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('в списке потоков всегда есть нынешнее значение', () {
    // Иначе выпадающий список macos_ui падает с «нет пункта с таким
    // значением», и окно настроек не открывается вовсе. Значение
    // выпадает из ряда запросто: настройки переехали с машины, где ядер
    // было больше, или их правили руками в файле.
    for (final current in [1, 2, 3, 4, 999]) {
      expect(threadChoices(current), contains(current),
          reason: 'потоков $current');
    }
    // Ряд остаётся возрастающим и без повторов — это всё-таки список
    // на выбор, а не свалка.
    final list = threadChoices(6);
    expect(list, orderedEquals(list.toSet().toList()..sort()));
  });

  group('настройки диктовки', () {
    test('правка уходит на диск и соседям — перечитать', () async {
      cubit.setThreads(8);
      await settle();

      expect(cubit.state.threads, 8);
      expect(DictationSettings.load().threads, 8, reason: 'на диске тоже');
      // Те же настройки читают панель и главное окно: без «reload»
      // половина правок доходила бы только до следующего запуска.
      expect(native.calls, contains('settingsChanged'));
    });

    test('подсказка и пунктуация ходят порознь', () async {
      cubit.setPrompt('Минина, Сытый двор');
      cubit.setPunctuate(false);
      await settle();

      expect(cubit.state.prompt, 'Минина, Сытый двор');
      expect(cubit.state.punctuate, isFalse);
      expect(DictationSettings.load().prompt, 'Минина, Сытый двор');
    });

    test('«та же, что у расшифровщика» — это пустая своя модель', () async {
      cubit.setDictationModel('/своя.bin');
      await settle();
      expect(cubit.state.dictationModel, '/своя.bin');

      cubit.setDictationModel('');
      await settle();
      expect(cubit.state.dictationModel, isEmpty);
    });
  });

  group('модели', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tsukiko-set'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('чужой .bin не становится моделью, а объясняет почему', () async {
      final fake = File('${tmp.path}/ggml-обманка.bin')
        ..writeAsBytesSync(List<int>.filled(64, 7));

      cubit.pickModel(fake.path);
      await settle();

      // whisper-cli на таком файле падает с руганью про тензоры —
      // человеку из неё не понять, что он выбрал не то.
      expect(cubit.state.problem, isNotNull);
      expect(cubit.state.models, isNot(contains(fake.path)));
      expect(cubit.state.dictationModel, isNot(fake.path));
    });

    test('исчезнувший файл тоже не молчит', () async {
      cubit.pickModel('${tmp.path}/такого-нет.bin');
      await settle();
      expect(cubit.state.problem, contains('больше нет на диске'));
    });

    test('удаление снимает выбор, если убрали выбранную', () async {
      final path = '${tmp.path}/ggml-условная.bin';
      File(path).writeAsBytesSync(List.filled(16, 1));
      cubit.setDictationModel(path);
      await settle();
      expect(cubit.state.dictationModel, path);

      await cubit.deleteModel(path);
      await settle();

      // Иначе диктовка осталась бы с путём, за которым ничего нет.
      expect(cubit.state.dictationModel, isEmpty);
      expect(native.calls, contains('trash'));
      // Список моделей стал другим — соседним окнам надо перечитать.
      expect(native.calls, contains('settingsChanged'));
    });

    test('система отказала — говорим об этом, а выбор не трогаем', () async {
      native.trashAllowed = false;
      final path = '${tmp.path}/ggml-условная.bin';
      File(path).writeAsBytesSync(List.filled(16, 1));
      cubit.setDictationModel(path);
      await settle();

      await cubit.deleteModel(path);
      expect(cubit.state.problem, contains('Корзину'));
      expect(cubit.state.dictationModel, path, reason: 'файл на месте');
    });
  });

  group('файлы расшифровок', () {
    test('форматы кнопок пишутся в общий источник настроек', () async {
      cubit.setCopyFormat('md');
      cubit.setSaveFormat('srt');
      await settle();

      expect(cubit.state.copyFormat, 'md');
      expect(cubit.state.saveFormat, 'srt');
      expect(Settings.load()['copyFormat'], 'md');
      expect(Settings.load()['saveFormat'], 'srt');
      expect(native.calls, contains('settingsChanged'));
    });

    test('последний формат снять нельзя: сохранять было бы нечего', () async {
      cubit.toggleFormat('srt', true);
      await settle();
      expect(cubit.state.libraryFormats, containsAll(['txt', 'srt']));

      cubit.toggleFormat('srt', false);
      await settle();
      expect(cubit.state.libraryFormats, ['txt']);

      cubit.toggleFormat('txt', false);
      await settle();
      expect(cubit.state.libraryFormats, ['txt'], reason: 'один остаётся');
    });

    test('папка библиотеки пишется в общие настройки', () async {
      cubit.setLibraryPath('/куда-нибудь');
      await settle();
      expect(cubit.state.libraryPath, '/куда-нибудь');
      expect(Settings.load()['libraryPath'], '/куда-нибудь');
    });
  });

  group('приложение', () {
    test('значок приложения переключается и на лету, и в файле', () async {
      cubit.setDockIcon(false);
      await settle();

      expect(cubit.state.dockIcon, isFalse);
      expect(Settings.load()['dockIcon'], isFalse);
      // LSUIElement спрятал бы значок навсегда — переключает только Dart.
      expect(native.calls, contains('dockIcon'));
    });

    test('автозапуск показывает ответ системы, а не наше желание', () async {
      native.loginItemAllowed = false;

      await cubit.setLoginItem(true);
      // Система могла и отказать: галка обязана показывать её ответ.
      expect(cubit.state.loginItem, isFalse);

      native.loginItemAllowed = true;
      await cubit.setLoginItem(true);
      expect(cubit.state.loginItem, isTrue);
    });
  });

  group('местное API', () {
    test('включение рождает ключ, выключение его стирает', () async {
      cubit.setApiEnabled(true);
      await settle();
      final key = cubit.state.apiKey;
      expect(cubit.state.apiEnabled, isTrue);
      expect(key.length, greaterThan(20));
      expect(Settings.load()[apiKeySetting], key);

      // Отдельной кнопки «сменить ключ» нет: старый обязан переставать
      // работать сам, иначе утёкший ключ живёт вечно.
      cubit.setApiEnabled(false);
      await settle();
      expect(cubit.state.apiKey, isEmpty);
      expect(Settings.load()[apiKeySetting], '');

      cubit.setApiEnabled(true);
      await settle();
      expect(cubit.state.apiKey, isNot(key));
    });
  });

  group('чья модель', () {
    // Главная путаница приложения: модель у расшифровщика и у диктовки
    // выбирается порознь, а пустой выбор диктовки означает «та же, что
    // у расшифровщика». В списке моделей это должно быть написано.
    test('пустой выбор диктовки — это модель расшифровщика', () {
      final s = SettingsState(queueModel: '/большая.bin');
      expect(s.dictationModelInUse, '/большая.bin');
      expect(s.userOf('/большая.bin'), 'расшифровщик и диктовка');
    });

    test('свой выбор диктовки разводит их по разным файлам', () {
      final s = SettingsState(
          queueModel: '/большая.bin', dictationModel: '/мелкая.bin');
      expect(s.userOf('/большая.bin'), 'расшифровщик');
      expect(s.userOf('/мелкая.bin'), 'диктовка');
      expect(s.userOf('/лишняя.bin'), isNull, reason: 'ею никто не работает');
    });
  });

  group('разрешения', () {
    test('одному «нет» не верим, третьему верим', () async {
      await settle();
      native.permitted = false;

      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'первому отказу не верим');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue);
      await cubit.checkPermission();
      expect(cubit.state.allowed, isFalse, reason: 'третий — уже правда');

      native.permitted = true;
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'любому «да» — сразу');
    });

    test('опрос идёт только пока окно на экране', () async {
      // Движок настроек переживает закрытие окна: без этого опрос тикал бы
      // до выхода из приложения.
      cubit.setVisible(true);
      await settle();
      final asked = native.calls.where((c) => c == 'permissions').length;

      cubit.setVisible(false);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(native.calls.where((c) => c == 'permissions').length, asked,
          reason: 'закрытое окно ни о чём не спрашивает');
    });
  });
}

/// Подставная родная сторона.
class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');
  final calls = <String>[];

  bool permitted = true;
  bool loginItemAllowed = true;
  bool trashAllowed = true;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'permissions' => permitted,
        'loginItem' => loginItemAllowed,
        'trash' => trashAllowed,
        'initialTab' => 'dictation',
        _ => null,
      };
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
