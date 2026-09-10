import 'package:flutter/cupertino.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/features/settings/settings_page.dart';
import 'package:tsukiko/features/settings/settings_state.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

class _FakeSettingsCubit extends Cubit<SettingsState> implements SettingsCubit {
  _FakeSettingsCubit([SettingsState? initial])
    : super(initial ?? SettingsState(tab: 'models'));

  void beginDownload() => emit(
    state.copyWith(
      downloadTitle: 'Parakeet',
      downloadProgress: '0 МБ из 640 МБ',
      downloadPercent: 0,
    ),
  );

  @override
  void setVisible(bool visible) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Окно настроек живёт отдельным файлом теста намеренно: рисующий тест
/// заводит TestWidgetsFlutterBinding, а та подменяет HttpClient — рядом
/// с ней тесты загрузки моделей перестают видеть сеть.
void main() {
  testWidgets('редактор команды использует обычную кнопку и ровные поля', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    final cubit = _FakeSettingsCubit(
      SettingsState(
        tab: 'dictation',
        textCommands: const [TextCommand('адрес офиса', 'Минск')],
      ),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    await tester.pump();
    await tester.dragUntilVisible(
      find.text('Добавить команду'),
      find.byType(ListView).first,
      const Offset(0, -180),
    );

    final add = tester.widget<PushButton>(
      find.widgetWithText(PushButton, 'Добавить команду'),
    );
    expect(add.controlSize, ControlSize.small);
    expect(find.text('Что сказать'), findsOneWidget);
    expect(find.text('Что вставить'), findsOneWidget);
    expect(find.textContaining('Автоматически добавлено'), findsNothing);
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey(0)),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.padding, const EdgeInsets.all(Gap.item));
    final phrase = tester.getRect(find.text('Что сказать'));
    final replacement = tester.getRect(find.text('Что вставить'));
    expect((phrase.top - replacement.top).abs(), lessThan(1));
    final trash = find.byWidgetPredicate(
      (widget) => widget is MacosIcon && widget.icon == CupertinoIcons.trash,
    );
    expect(trash, findsOneWidget);
    expect(tester.getSize(trash).width, IconSize.toolbar);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('начало загрузки возвращает список к индикатору', (tester) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    final cubit = _FakeSettingsCubit();
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    await tester.pump();

    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = position.pixels;
    expect(before, greaterThan(500));

    cubit.beginDownload();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Загрузка: Parakeet'), findsOneWidget);
    expect(position.pixels, lessThan(before));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('окно настроек рисуется на всех четырёх вкладках', (
    tester,
  ) async {
    // Размер настоящего окна: раскладка обязана сходиться именно в нём.
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Тестовый движок по умолчанию отдаёт en_US — тексты ниже сверены
    // с русским, поэтому закрепляем его явно.
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    NativeBridge.debugReset();
    await tester.pumpWidget(const SettingsApp());
    await tester.pump();

    // Вкладки названы по хозяину настройки: сперва два потребителя
    // моделей, потом общий склад и само приложение.
    for (final (label, marker) in [
      ('Расшифровщик', 'Сохранять готовый текст на диск'),
      ('Диктовка', 'Держать и говорить'),
      ('Модели', 'АКТИВНЫЕ МОДЕЛИ'),
      ('Приложение', 'Показывать значок в ${os.appIconAreaName}'),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.text(marker), findsOneWidget, reason: 'вкладка «$label»');
      expect(tester.takeException(), isNull, reason: 'вкладка «$label»');
    }

    // Каталог длиннее окна, но все движки и ограничения доступны после
    // прокрутки, а не спрятаны в одном непрозрачном выпадающем списке.
    await tester.tap(find.text('Модели'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.textContaining('Parakeet TDT 0.6b v3'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('25 языков Европы'), findsOneWidget);
    expect(find.text('Без словарных подсказок'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'каталог моделей');

    // Скилл живёт на вкладке «Приложение», ниже сгиба: список длинный,
    // и до раздела надо доехать. Проверяем, что он там вообще есть, —
    // иначе кнопка молча не появится ни у кого.
    await tester.tap(find.text('Приложение'));
    await tester.pump();
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно и стоит на экране.
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно стоит на экране.
    //
    // Раздел свёрнут: сам он на месте всегда, а содержимое появляется
    // только по щелчку — тому, кто нейросетями не пользуется, оно
    // мозолило бы глаза на каждом открытии настроек.
    // Заголовок раскрывашки написан обычными буквами — от заголовка
    // раздела (он прописными) отличается именно этим.
    await tester.dragUntilVisible(
      find.text('Скилл для нейросетей'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('СКИЛЛ ДЛЯ НЕЙРОСЕТЕЙ'), findsOneWidget);
    expect(find.text('Установлено для:'), findsNothing);

    await tester.tap(find.text('Скилл для нейросетей'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Поставить скилл'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('Установлено для:'), findsOneWidget);
    // Ненайденный агент в списке есть — и его галку можно поставить
    // самому: человек вправе поставить агента следом за нами.
    expect(find.textContaining('не найден'), findsWidgets);

    expect(tester.takeException(), isNull);

    // Таймер опроса разрешений должен уйти вместе с окном.
    await tester.pumpWidget(const SizedBox());
  });
}
