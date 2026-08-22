import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/platform/bridge.dart';

/// Окно настроек. До выноса из виджета проверять было нечем: каждая галка
/// сидела в `setState` и не отделялась от раскладки.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late SettingsCubit cubit;
  late Map<String, dynamic> before;
  late DictationSettings dictationBefore;

  setUp(() {
    // Настройки живут в настоящей папке приложения — возвращаем как было.
    before = Settings.load();
    dictationBefore = DictationSettings.load();
    native = _FakeNative()..install();
    NativeBridge.debugReset();
    cubit = SettingsCubit(NativeBridge());
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
    await Settings.save(before);
    dictationBefore.save();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

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

    test('«как у расшифровщика» — это пустая своя модель', () async {
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
  });

  group('библиотека', () {
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

  group('общие', () {
    test('значок в Dock переключается и на лету, и в файле', () async {
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

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'permissions' => permitted,
        'loginItem' => loginItemAllowed,
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
