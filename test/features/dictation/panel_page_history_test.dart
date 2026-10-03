import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_history.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/features/dictation/panel_page.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

class _FakeNative {
  final calls = <String>[];
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'permissions':
              return true;
            case 'level':
              return 0.2;
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

class _FakeServer extends WhisperServer {
  @override
  bool get up => false;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async => 'тест';

  @override
  Future<void> shutdown() async {}

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-panel-history-test');

  late _FakeNative native;
  late _FakeServer server;
  late DictationCubit cubit;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    NativeBridge.debugReset();
    cubit = DictationCubit(NativeBridge(), server: server);
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> pumpPanel(WidgetTester tester, {Locale locale = const Locale('ru')}) async {
    await tester.binding.setSurfaceSize(const Size(380, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider<DictationCubit>.value(
        value: cubit,
        child: MacosApp(
          locale: locale,
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: ThemeMode.system,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PanelBody(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1. Пустое состояние истории: заглушка видна, кнопок копирования и очистки нет', (tester) async {
    await pumpPanel(tester);

    expect(find.text('Последняя расшифровка'), findsOneWidget);
    expect(find.text('Пока ничего не надиктовано.'), findsOneWidget);
    expect(find.text('Скопировать'), findsNothing);
    expect(find.byIcon(CupertinoIcons.trash), findsNothing);
    expect(find.textContaining('Предыдущие записи'), findsNothing);
  });

  testWidgets('2. Одна запись: виден текст, время, кнопка Скопировать, аккордеон скрыт', (tester) async {
    final entry = DictationEntry(
      id: 'entry-1',
      text: 'Первая надиктованная фраза',
      createdAt: DateTime(2026, 10, 3, 14, 25),
    );
    DictationHistory.save([entry]);
    cubit.overrideState(cubit.state.copyWith(history: [entry], last: entry.text));

    await pumpPanel(tester);

    expect(find.text('Первая надиктованная фраза'), findsOneWidget);
    expect(find.text('Скопировать'), findsOneWidget);
    expect(find.text('14:25'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is MacosIcon && w.icon == CupertinoIcons.trash), findsOneWidget);
    expect(find.textContaining('Предыдущие записи'), findsNothing);
  });

  testWidgets('3. Несколько записей: аккордеон виден со счётчиком, раскрывается и показывает старые записи', (tester) async {
    final entries = [
      DictationEntry(id: 'entry-new', text: 'Свежая фраза', createdAt: DateTime(2026, 10, 3, 15, 0)),
      DictationEntry(id: 'entry-old-1', text: 'Старая фраза номер раз', createdAt: DateTime(2026, 10, 3, 14, 50)),
      DictationEntry(id: 'entry-old-2', text: 'Старая фраза номер два', createdAt: DateTime(2026, 10, 3, 14, 40)),
    ];
    DictationHistory.save(entries);
    cubit.overrideState(cubit.state.copyWith(history: entries, last: entries.first.text));

    await pumpPanel(tester);

    // Свежая видна
    expect(find.text('Свежая фраза'), findsOneWidget);

    // Аккордеон показывает 2 старые записи
    final accordionFinder = find.text('Предыдущие записи (2)');
    expect(accordionFinder, findsOneWidget);

    // До клика старых записей нет в дереве
    expect(find.text('Старая фраза номер раз'), findsNothing);

    // Кликаем по аккордеону
    await tester.tap(accordionFinder);
    await tester.pumpAndSettle();

    // Теперь старые записи видны
    expect(find.text('Старая фраза номер раз'), findsOneWidget);
    expect(find.text('Старая фраза номер два'), findsOneWidget);
    expect(find.text('14:50'), findsOneWidget);
    expect(find.text('14:40'), findsOneWidget);
  });

  testWidgets('4. Удаление единичной записи из истории через крестик в строке', (tester) async {
    final entries = [
      DictationEntry(id: 'entry-new', text: 'Свежая фраза', createdAt: DateTime(2026, 10, 3, 15, 0)),
      DictationEntry(id: 'entry-old-1', text: 'Удаляемая запись', createdAt: DateTime(2026, 10, 3, 14, 50)),
    ];
    DictationHistory.save(entries);
    cubit.overrideState(cubit.state.copyWith(history: entries, last: entries.first.text));

    await pumpPanel(tester);
    await tester.tap(find.text('Предыдущие записи (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Удаляемая запись'), findsOneWidget);

    // Нажимаем крестик удаления
    final deleteBtn = find.byWidgetPredicate((w) => w is MacosIcon && w.icon == CupertinoIcons.xmark);
    expect(deleteBtn, findsOneWidget);
    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();

    // Запись удалена
    expect(find.text('Удаляемая запись'), findsNothing);
    expect(cubit.state.history.length, 1);
  });

  testWidgets('5. Полная очистка истории по кнопке корзины возвращает пустое состояние', (tester) async {
    final entries = [
      DictationEntry(id: 'entry-1', text: 'Фраза перед очисткой', createdAt: DateTime(2026, 10, 3, 15, 0)),
    ];
    DictationHistory.save(entries);
    cubit.overrideState(cubit.state.copyWith(history: entries, last: entries.first.text));

    await pumpPanel(tester);

    expect(find.text('Фраза перед очисткой'), findsOneWidget);
    final trashBtn = find.byWidgetPredicate((w) => w is MacosIcon && w.icon == CupertinoIcons.trash);
    expect(trashBtn, findsOneWidget);

    await tester.tap(trashBtn);
    await tester.pumpAndSettle();

    expect(find.text('Пока ничего не надиктовано.'), findsOneWidget);
    expect(find.text('Фраза перед очисткой'), findsNothing);
    expect(cubit.state.history.isEmpty, isTrue);
  });
}

extension on DictationCubit {
  void overrideState(DictationState s) {
    // Вспомогательный метод для прямого применения стейта в тестах
    emit(s);
  }
}
