import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/features/api/api_server.dart';
import 'package:tsukiko/features/queue/queue_bloc.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/platform/os.dart';

import '../../support/fake_os.dart';

/// Местное API. Проверяется именно охрана: расшифровка целиком упирается
/// в настоящий whisper.cpp и настоящий звук — это уже ручная проверка
/// через curl, она описана в `docs/задача-местное-api.md`. А вот отказы
/// должны работать всегда и без движка, и цена ошибки в них высокая:
/// открытый порт с доступом к файлам это не мелочь.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  useTempSupportDir('tsukiko-api');

  late _FakeNative native;
  late QueueBloc bloc;
  late String key;

  /// Порт нулевой: система выдаст любой свободный, и две проверки,
  /// запущенные разом, не подерутся за 8756 — ни между собой, ни
  /// с настоящим приложением, если оно сейчас работает.
  Future<void> enable() async {
    key = newApiKey();
    await Settings.save({
      apiEnabledSetting: true,
      apiKeySetting: key,
      apiPortSetting: 0,
    });
    await bloc.api.sync();
  }

  setUp(() async {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    NativeBridge.debugReset();
    bloc = QueueBloc(NativeBridge());
    await enable();
  });

  tearDown(() async {
    await bloc.close();
    native.remove();
  });

  /// Обычный запрос: с ключом, без Origin, на 127.0.0.1.
  Future<HttpClientResponse> ask(
    String method,
    String path, {
    String? auth,
    String? origin,
    String? host,
    Object? body,
  }) async =>
      // Тестовый движок Flutter подменяет HttpClient заглушкой, которая
      // на всё отвечает 400 и никуда не ходит. Здесь нужен настоящий:
      // мы проверяем свой же сервер на своей же машине.
      HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final req = await client.open(method, '127.0.0.1', bloc.api.port, path);
        final bearer = auth ?? 'Bearer $key';
        if (bearer.isNotEmpty) req.headers.set('authorization', bearer);
        if (origin != null) req.headers.set('origin', origin);
        if (host != null) req.headers.set('host', host);
        // Именно байтами: в путях кириллица, а `write` берёт только латиницу.
        if (body != null) req.add(utf8.encode(jsonEncode(body)));
        return req.close();
      }, _RealHttp());

  Future<Map<String, Object?>> json(HttpClientResponse res) async =>
      jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, Object?>;

  test('выключенное API не слушает ничего', () async {
    await Settings.save({apiEnabledSetting: false, apiKeySetting: ''});
    await bloc.api.sync();
    expect(bloc.api.port, 0);
  });

  test('с ключом отвечает и называет себя', () async {
    final res = await ask('GET', '/status');
    expect(res.statusCode, 200);
    expect((await json(res))['app'], appName);
  });

  test('без ключа — 401', () async {
    expect((await ask('GET', '/status', auth: '')).statusCode, 401);
    expect((await ask('GET', '/status', auth: 'Bearer wrong-key')).statusCode, 401);
  });

  test('запрос со страницы в браузере не проходит даже с ключом', () async {
    final res = await ask('GET', '/status', origin: 'https://example.com');
    expect(res.statusCode, 403);
  });

  test('чужое имя в Host — подмена DNS, отказ', () async {
    final res = await ask('GET', '/status', host: 'tsukiko.example.com');
    expect(res.statusCode, 403);
  });

  group('какие файлы берём', () {
    Future<Map<String, Object?>> post(String path) async =>
        json(await ask('POST', '/transcribe', body: {'file': path}));

    test('чужой файл вне домашней папки не берём', () async {
      expect((await post('/etc/passwd'))['error'], isNotNull);
      // Настоящий звуковой файл, но лежит там, где человек записи не
      // держит: домашняя папка в проверке подменена временной.
      final outside = File(os.join(Directory.current.path, 'чужой.m4a'))
        ..writeAsStringSync('звук');
      try {
        final err = (await post(outside.path))['error'] as String;
        expect(err, contains('вне домашней'));
      } finally {
        outside.deleteSync();
      }
    });

    test('не звук не берём — и говорим почему', () async {
      final txt = File(os.join(os.home, 'заметка.txt'))
        ..writeAsStringSync('не звук');
      final err = (await post(txt.path))['error'] as String;
      expect(err, contains('.txt'));
    });

    test('несуществующий файл не выдаёт, что его нет, в виде сбоя', () async {
      final err = (await post(os.join(os.home, 'нет.m4a')))['error'] as String;
      expect(err, contains('нет'));
    });
  });

  test('чужой метод — 404 со списком того, что есть', () async {
    final res = await ask('GET', '/выдумка');
    expect(res.statusCode, 404);
    expect((await json(res))['methods'], contains('POST /transcribe'));
  });
}

/// Настоящий HttpClient вместо заглушки тестового движка.
class _RealHttp extends HttpOverrides {}

class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => switch (call.method) {
              'requestModel' => true,
              'permissions' => true,
              _ => null,
            });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
