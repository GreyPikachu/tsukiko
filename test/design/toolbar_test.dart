import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/design/toolbar.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

/// Панель инструментов: список спрятанного открывается многоточием,
/// а не «»».
///
/// Ради этого значка панель и унаследована от пакетной (см. `toolbar.dart`),
/// а раз унаследована — надо проверить и то, что остальное дерево от этого
/// не рассыпалось: кнопки на месте, значок нашего списка на месте, чужого
/// нет вовсе.
///
/// Что именно сейчас видно, а что спрятано, проверить отсюда нельзя:
/// `OverflowHandler` прячет лишнее на отрисовке, а в дереве держит всех.
/// Проверяем то, ради чего форк и сделан, — каким значком открывается
/// спрятанное.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // macos_ui рисует значки своим MacosIcon, а не Icon, и find.byIcon
  // мимо них проходит.
  Finder icon(IconData data) =>
      find.byWidgetPredicate((w) => w is MacosIcon && w.icon == data);

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
  });

  List<ToolbarItem> buttons(int count) => [
        for (var i = 0; i < count; i++)
          ToolBarIconButton(
            label: 'кнопка $i',
            icon: const MacosIcon(CupertinoIcons.add),
            showLabel: false,
            onPressed: () {},
          ),
      ];

  Future<void> pump(WidgetTester tester, ToolBar bar) async {
    await binding.setSurfaceSize(const Size(620, 300));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(MacosApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Column(children: [SizedBox(height: 52, child: bar)]),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('спрятанное открывается многоточием, а не «»»', (tester) async {
    await pump(
      tester,
      AppToolBar(
        title: const Text('tsukiko'),
        titleWidth: 240,
        enableBlur: true,
        actions: buttons(8),
      ),
    );

    expect(icon(CupertinoIcons.add), findsNWidgets(8),
        reason: 'наследование не должно было потерять сами пункты');
    expect(icon(CupertinoIcons.ellipsis), findsOneWidget);
    // Значок пакета читался как «свернуть правую колонку»: за него и
    // нажимали, ожидая свернуть панель, а получали меню экспорта.
    expect(icon(CupertinoIcons.chevron_right_2), findsNothing);
  });

  test('пункт под многоточием не теряет выбранный формат', () {
    expect(checkedOverflowLabel('Текст', checked: true), '✓ Текст');
    expect(checkedOverflowLabel('Субтитры SRT', checked: false), '  Субтитры SRT');
  });

  testWidgets('список форматов выглядит доступным', (tester) async {
    await pump(
      tester,
      AppToolBar(
        actions: [
          AppToolBarPullDownButton(
            label: 'Формат копирования',
            icon: CupertinoIcons.doc_on_clipboard,
            items: [
              MacosPulldownMenuItem(
                label: 'Текст',
                title: const Text('Текст'),
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );

    final theme = tester.widget<MacosPulldownButtonTheme>(
      find.byType(MacosPulldownButtonTheme),
    );
    final context = tester.element(find.byType(MacosPulldownButton));
    expect(
      theme.data.iconColor,
      Surface.toolbarIcon(context, enabled: true),
    );
  });
}
