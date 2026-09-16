import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/dictation/hud_page.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

/// Плавающая панель записи. Проверяется то, ради чего она есть: что она
/// говорит человеку в каждом состоянии и что нажатие кнопки доходит
/// до диктовки.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    NativeBridge.debugReset();
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        calls.add(call);
        // Уровень сигнала панель спрашивает сама, тридцать раз в секунду.
        if (call.method == 'level') return 0.5;
        return null;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('tsukiko/dictation'), null);
  });

  /// Прислать панели состояние так же, как это делает родная сторона.
  Future<void> send(WidgetTester tester, HudState state) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tsukiko/dictation',
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('hudState', state.name)),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> show(WidgetTester tester) async {
    // Шире настоящих 372: в тестах Flutter рисует своим шрифтом, где
    // каждый знак — квадрат в кегль. «Остановить» выходит 120 точек
    // вместо примерно семидесяти, и панель переполняется от одного этого.
    // Проверяем поведение, а не раскладку.
    await tester.binding.setSurfaceSize(const Size(600, 52));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MacosApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HudView(bridge: NativeBridge()),
    ));
    await tester.pump();
  }

  testWidgets('в каждом состоянии панель говорит своё', (tester) async {
    await show(tester);

    await send(tester, HudState.recording);
    expect(find.text('Отменить'), findsOneWidget);
    expect(find.text('Остановить'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget, reason: 'время идёт с нуля');

    await send(tester, HudState.transcribing);
    expect(find.text('Распознаю…'), findsOneWidget);
    // Прервать долгий счёт можно только отсюда.
    expect(find.text('Отменить'), findsNothing);

    // Молча исчезнуть после неудачи — значит соврать, что всё в порядке.
    await send(tester, HudState.failed);
    expect(find.text('Не распознано · запись сохранена'), findsOneWidget);

    await send(tester, HudState.copied);
    expect(find.text('Не вставилось · текст в буфере, Ctrl+V'), findsOneWidget);

    await send(tester, HudState.cancelled);
    expect(find.text('Отменено · запись сохранена'), findsOneWidget);

    await send(tester, HudState.done);
    expect(find.text('Готово'), findsOneWidget);

    await send(tester, HudState.hidden);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('нажатие доходит до диктовки, а уровень спрашивается сам',
      (tester) async {
    await show(tester);
    await send(tester, HudState.recording);

    // Полоски уровня должны шевелиться: молчащая панель неотличима
    // от сломанного микрофона.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();
    expect(calls.any((c) => c.method == 'level'), isTrue);

    await tester.tap(find.text('Остановить'));
    await tester.pump();
    expect(
      calls.where((c) => c.method == 'hudAction').map((c) => c.arguments),
      contains('stop'),
    );

    await tester.tap(find.text('Отменить'));
    await tester.pump();
    expect(
      calls.where((c) => c.method == 'hudAction').map((c) => c.arguments),
      contains('cancel'),
    );

    await send(tester, HudState.hidden);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('подхватывает начальное состояние при открытии', (tester) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        calls.add(call);
        if (call.method == 'getHudState') return 'recording';
        if (call.method == 'level') return 0.5;
        return null;
      },
    );
    await show(tester);
    expect(find.text('Отменить'), findsOneWidget);
    expect(find.text('Остановить'), findsOneWidget);
  });
}
