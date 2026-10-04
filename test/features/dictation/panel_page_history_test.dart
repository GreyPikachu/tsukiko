import 'dart:async';
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
  final heights = <double>[];
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'panelHeight':
              heights.add((call.arguments['height'] as num).toDouble());
              return null;
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
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async =>
      'тест';

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
    cubit = DictationCubit(
      NativeBridge(),
      server: server,
      historyWriter: (entries) async {
        if (entries.isEmpty) {
          DictationHistory.clear();
        } else {
          DictationHistory.save(entries);
        }
      },
    );
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    Locale locale = const Locale('ru'),
    ThemeMode mode = ThemeMode.system,
    bool reducedMotion = false,
  }) async {
    // Let bridge readiness futures created in setUp settle outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    await tester.binding.setSurfaceSize(const Size(380, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider<DictationCubit>.value(
        value: cubit,
        child: MacosApp(
          locale: locale,
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: mode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
          home: const PanelBody(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '1. Пустое состояние истории: заглушка видна, кнопок копирования и очистки нет',
    (tester) async {
      await pumpPanel(tester);

      expect(find.text('Последняя расшифровка'), findsOneWidget);
      expect(find.text('Пока ничего не надиктовано.'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosTooltip && w.message == 'Скопировать',
        ),
        findsNothing,
      );
      expect(find.byIcon(CupertinoIcons.trash), findsNothing);
      expect(find.textContaining('Предыдущие записи'), findsNothing);
    },
  );

  testWidgets(
    '2. Одна запись: виден текст, время, иконка копирования, аккордеон скрыт',
    (tester) async {
      final entry = DictationEntry(
        id: 'entry-1',
        text: 'Первая надиктованная фраза',
        createdAt: DateTime(2026, 10, 3, 14, 25),
      );
      DictationHistory.save([entry]);
      cubit.overrideState(
        cubit.state.copyWith(history: [entry], last: entry.text),
      );

      await pumpPanel(tester);

      expect(find.text('Первая надиктованная фраза'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosTooltip && w.message == 'Скопировать',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.doc_on_doc,
        ),
        findsOneWidget,
      );
      expect(find.text('14:25'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Предыдущие записи'), findsNothing);
    },
  );

  testWidgets(
    '3. Несколько записей: аккордеон виден со счётчиком, раскрывается и показывает старые записи',
    (tester) async {
      final entries = [
        DictationEntry(
          id: 'entry-new',
          text: 'Свежая фраза',
          createdAt: DateTime(2026, 10, 3, 15, 0),
        ),
        DictationEntry(
          id: 'entry-old-1',
          text: 'Старая фраза номер раз',
          createdAt: DateTime(2026, 10, 3, 14, 50),
        ),
        DictationEntry(
          id: 'entry-old-2',
          text: 'Старая фраза номер два',
          createdAt: DateTime(2026, 10, 3, 14, 40),
        ),
      ];
      DictationHistory.save(entries);
      cubit.overrideState(
        cubit.state.copyWith(history: entries, last: entries.first.text),
      );

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
    },
  );

  testWidgets(
    '4. Удаление единичной записи из истории через крестик в строке',
    (tester) async {
      final entries = [
        DictationEntry(
          id: 'entry-new',
          text: 'Свежая фраза',
          createdAt: DateTime(2026, 10, 3, 15, 0),
        ),
        DictationEntry(
          id: 'entry-old-1',
          text: 'Удаляемая запись',
          createdAt: DateTime(2026, 10, 3, 14, 50),
        ),
      ];
      DictationHistory.save(entries);
      cubit.overrideState(
        cubit.state.copyWith(history: entries, last: entries.first.text),
      );

      await pumpPanel(tester);
      await tester.tap(find.text('Предыдущие записи (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Удаляемая запись'), findsOneWidget);

      // Нажимаем крестик удаления
      final deleteBtn = find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.xmark,
      );
      expect(deleteBtn, findsOneWidget);
      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      await cubit.flushHistoryForTesting();
      // Запись удалена
      expect(find.text('Удаляемая запись'), findsNothing);
      expect(cubit.state.history.length, 1);
    },
  );

  testWidgets(
    '5. Полная очистка истории по кнопке корзины возвращает пустое состояние',
    (tester) async {
      final entries = [
        DictationEntry(
          id: 'entry-1',
          text: 'Фраза перед очисткой',
          createdAt: DateTime(2026, 10, 3, 15, 0),
        ),
      ];
      DictationHistory.save(entries);
      cubit.overrideState(
        cubit.state.copyWith(history: entries, last: entries.first.text),
      );

      await pumpPanel(tester);

      expect(find.text('Фраза перед очисткой'), findsOneWidget);
      final trashBtn = find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      );
      expect(trashBtn, findsOneWidget);

      await tester.tap(trashBtn);
      await tester.pumpAndSettle();

      expect(find.text('Пока ничего не надиктовано.'), findsOneWidget);
      expect(find.text('Фраза перед очисткой'), findsNothing);
      expect(cubit.state.history.isEmpty, isTrue);
    },
  );

  testWidgets(
    '6. Локализация на английском языке (en): отображаются корректные английские строки и тултипы',
    (tester) async {
      final entries = [
        DictationEntry(
          id: 'entry-1',
          text: 'Latest english text',
          createdAt: DateTime(2026, 10, 3, 15, 0),
        ),
        DictationEntry(
          id: 'entry-2',
          text: 'Older english text 1',
          createdAt: DateTime(2026, 10, 3, 14, 50),
        ),
        DictationEntry(
          id: 'entry-3',
          text: 'Older english text 2',
          createdAt: DateTime(2026, 10, 3, 14, 40),
        ),
      ];
      DictationHistory.save(entries);
      cubit.overrideState(
        cubit.state.copyWith(history: entries, last: entries.first.text),
      );

      await pumpPanel(tester, locale: const Locale('en'));

      expect(find.text('Last Transcript'), findsOneWidget);
      expect(find.text('Latest english text'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is MacosTooltip && w.message == 'Copy'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.doc_on_doc,
        ),
        findsOneWidget,
      );
      expect(find.text('Previous transcripts (2)'), findsOneWidget);

      final clearTooltip = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Clear History',
      );
      expect(clearTooltip, findsOneWidget);
    },
  );

  testWidgets(
    '7. Клик по иконке копирования последней записи переключает иконку на галочку и обновляет тултип',
    (tester) async {
      final entry = DictationEntry(
        id: 'entry-1',
        text: 'Фраза для копирования',
        createdAt: DateTime(2026, 10, 3, 14, 25),
      );
      DictationHistory.save([entry]);
      cubit.overrideState(
        cubit.state.copyWith(history: [entry], last: entry.text),
      );

      await pumpPanel(tester);

      final copyBtn = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Скопировать',
      );
      expect(copyBtn, findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
        ),
        findsNothing,
      );

      // Кликаем по кнопке копирования
      await tester.tap(copyBtn);
      await tester.pump();

      // Теперь видна галочка и тултип Скопировано
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosTooltip && w.message == 'Скопировано',
        ),
        findsOneWidget,
      );

      // Спустя 1.2с состояние возвращается обратно
      await tester.pump(const Duration(milliseconds: 1300));
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
        ),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.doc_on_doc,
        ),
        findsOneWidget,
      );
    },
  );
  List<DictationEntry> entries() => List.generate(
    3,
    (i) => DictationEntry(
      id: 'test-$i',
      text: 'Фраза $i',
      createdAt: DateTime(2026, 10, 4, 12, 35 - i),
    ),
  );

  testWidgets('короткие и многострочные расшифровки имеют общий левый край', (
    tester,
  ) async {
    final history = [
      DictationEntry(
        id: 'aligned-latest',
        text: 'Короткая запись',
        createdAt: DateTime(2026, 10, 4, 12, 35),
      ),
      DictationEntry(
        id: 'aligned-older',
        text:
            'Длинная предыдущая расшифровка, которая переносится на несколько строк.',
        createdAt: DateTime(2026, 10, 4, 12, 32),
      ),
      DictationEntry(
        id: 'aligned-short',
        text: 'Да',
        createdAt: DateTime(2026, 10, 4, 12, 28),
      ),
    ];
    cubit.overrideState(cubit.state.copyWith(history: history));
    await pumpPanel(tester);
    await tester.binding.setSurfaceSize(const Size(320, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Предыдущие записи (2)'));
    await tester.pumpAndSettle();

    final left = tester.getTopLeft(find.text('Последняя расшифровка')).dx;
    for (final text in [
      'Предыдущие записи (2)',
      ...history.map((entry) => entry.text),
      '12:35',
      '12:32',
      '12:28',
    ]) {
      expect(tester.getTopLeft(find.text(text)).dx, left, reason: text);
    }
    for (final entry in history) {
      expect(
        tester.widget<Text>(find.text(entry.text)).textAlign,
        TextAlign.left,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'раскрытие и быстрое повторное сворачивание меняют нативную высоту',
    (tester) async {
      final history = entries();
      cubit.overrideState(
        cubit.state.copyWith(history: history, last: history.first.text),
      );
      await pumpPanel(tester);
      final collapsed = native.heights.last;
      await tester.tap(find.text('Предыдущие записи (2)'));
      await tester.pumpAndSettle();
      expect(native.heights.last, greaterThan(collapsed));
      await tester.tap(find.text('Предыдущие записи (2)'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Предыдущие записи (2)'));
      await tester.pumpAndSettle();
      expect(native.heights.last, greaterThan(collapsed));
      await tester.tap(find.text('Предыдущие записи (2)'));
      await tester.pumpAndSettle();
      expect(native.heights.last, collapsed);
    },
  );

  testWidgets(
    'копирование ждёт буфер и показывает галочку только после успеха',
    (tester) async {
      final history = entries().take(1).toList();
      cubit.overrideState(
        cubit.state.copyWith(history: history, last: 'Весь пакет диктовок'),
      );
      await pumpPanel(tester);
      final gate = Completer<void>();
      String? copied;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
            await gate.future;
          }
          return null;
        },
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is MacosTooltip && w.message == 'Скопировать',
        ),
      );
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
        ),
        findsNothing,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(copied, history.first.text);
      expect(
        find.byWidgetPredicate(
          (w) => w is MacosTooltip && w.message == 'Скопировано',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1300));
    },
  );

  testWidgets('ошибка буфера не выдаётся за успешное копирование', (
    tester,
  ) async {
    final history = entries().take(1).toList();
    cubit.overrideState(cubit.state.copyWith(history: history));
    await pumpPanel(tester);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Скопировать',
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip && w.message == 'Не удалось скопировать текст.',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('предыдущие записи раскрываются с клавиатуры', (tester) async {
    final history = entries();
    cubit.overrideState(cubit.state.copyWith(history: history));
    await pumpPanel(tester);
    Focus.of(tester.element(find.text('Предыдущие записи (2)'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Фраза 1'), findsOneWidget);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('20 записей помещаются в узкую панель — $mode', (tester) async {
      final history = List.generate(
        20,
        (i) => DictationEntry(
          id: 'long-$i',
          text:
              'Длинная надиктованная фраза номер $i, которая переносится на несколько строк.',
          createdAt: DateTime(2026, 10, 4, 12, i),
        ),
      );
      cubit.overrideState(cubit.state.copyWith(history: history));
      await pumpPanel(tester, mode: mode);
      await tester.binding.setSurfaceSize(const Size(320, 600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предыдущие записи (19)'));
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      expect(tester.getSize(list).height, lessThanOrEqualTo(180));
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('уменьшение движения сохраняет раскрытие и правильную высоту', (
    tester,
  ) async {
    final history = entries();
    cubit.overrideState(cubit.state.copyWith(history: history));
    await pumpPanel(tester, reducedMotion: true);
    final collapsed = native.heights.last;
    await tester.tap(find.text('Предыдущие записи (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Фраза 1'), findsOneWidget);
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
      const Duration(milliseconds: 150),
    );
    expect(native.heights.last, greaterThan(collapsed));
  });
}

extension on DictationCubit {
  void overrideState(DictationState s) {
    // Вспомогательный метод для прямого применения стейта в тестах
    emit(s);
  }
}
