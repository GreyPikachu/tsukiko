import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late NativeBridge bridge;
  String? mockHudStateResponse;

  setUp(() {
    NativeBridge.debugReset();
    mockHudStateResponse = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        if (call.method == 'getHudState') {
          return mockHudStateResponse;
        }
        return null;
      },
    );
    bridge = NativeBridge();
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      null,
    );
  });

  group('currentHudState', () {
    test('возвращает null если канал вернул null', () async {
      mockHudStateResponse = null;
      final state = await bridge.currentHudState();
      expect(state, isNull);
    });

    test('возвращает корректный HudState для известных состояний', () async {
      mockHudStateResponse = 'recording';
      expect(await bridge.currentHudState(), HudState.recording);

      mockHudStateResponse = 'transcribing';
      expect(await bridge.currentHudState(), HudState.transcribing);

      mockHudStateResponse = 'done';
      expect(await bridge.currentHudState(), HudState.done);

      mockHudStateResponse = 'hidden';
      expect(await bridge.currentHudState(), HudState.hidden);
    });

    test('возвращает HudState.hidden для неизвестного состояния', () async {
      mockHudStateResponse = 'some_unrecognized_state';
      expect(await bridge.currentHudState(), HudState.hidden);
    });
  });
}
