import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/queue/menu_shortcuts.dart';
import 'package:tsukiko/platform/os.dart';

/// Сочетания клавиш там, где нет строки меню.
void main() {
  var added = 0, copied = 0, found = 0;

  List<PlatformMenuItem> menus() => [
        PlatformMenu(label: 'Файл', menus: [
          PlatformMenuItem(
            label: 'Добавить',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
            onSelected: () => added++,
          ),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Копировать',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC,
                  meta: true, shift: true),
              onSelected: () => copied++,
            ),
          ]),
          // Пункт без сочетания и пункт без действия в карту не попадают.
          PlatformMenuItem(label: 'О программе', onSelected: () {}),
          const PlatformMenuItem(
            label: 'Недоступно',
            shortcut: SingleActivator(LogicalKeyboardKey.keyP, meta: true),
          ),
        ]),
        PlatformMenu(label: 'Правка', menus: [
          PlatformMenuItem(
            label: 'Найти',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
            onSelected: () => found++,
          ),
        ]),
      ];

  test('сочетания собираются из тех же пунктов меню, вложенность и группы', () {
    final map = shortcutsFromMenus(menus(), swapMetaForControl: false);
    expect(map.length, 3, reason: 'пункты без сочетания или без действия мимо');
    map[const SingleActivator(LogicalKeyboardKey.keyF, meta: true)]!();
    expect(found, 1);
    map[const SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true)]!();
    expect(copied, 1, reason: 'группа — не пункт, но её содержимое считается');
  });

  test('⌘ становится Ctrl, остальные модификаторы остаются', () {
    final map = shortcutsFromMenus(menus(), swapMetaForControl: true);
    // Сравнивать сочетания как ключи нельзя: SingleActivator не value-тип,
    // и одинаковые по смыслу, но разные по ссылке не совпадут. Смотрим
    // на сами сочетания — CallbackShortcuts тоже перебирает их, а
    // не ищет по ключу.
    final keys = map.keys.cast<SingleActivator>().toList();
    expect(keys.every((k) => !k.meta), isTrue,
        reason: 'клавиша Windows на месте ⌘ была бы прямой ошибкой: '
            'её сочетания приложению не достаются');
    expect(keys.every((k) => k.control), isTrue);

    final o = keys.firstWhere((k) => k.trigger == LogicalKeyboardKey.keyO);
    map[o]!();
    expect(added, 1);

    final c = keys.firstWhere((k) => k.trigger == LogicalKeyboardKey.keyC);
    expect(c.shift, isTrue, reason: '⇧ никуда не девается');
  });

  test('список сочетаний собирается из того же дерева и по разделам', () {
    // На Windows строки меню нет вовсе: сочетания работают, а посмотреть
    // их негде. Список для этого берётся из того же дерева, что и сами
    // сочетания, — иначе подсказка разошлась бы с делом.
    final commands = menuCommands(menus());
    expect(commands.map((c) => c.label).toList(),
        ['Добавить', 'Копировать', 'Недоступно', 'Найти'],
        reason: 'пункт без сочетания в список не идёт, а недоступный — идёт: '
            'это справочник о клавишах, а не панель инструментов');
    expect(commands.map((c) => c.menu).toSet(), {'Файл', 'Правка'});
    // Подпись — словами той системы, на которой идёт тест: значки ⌘
    // на Windows человеку не говорят ничего.
    expect(commands.first.shortcut, os.menuShortcut(const ['cmd'], 'o'));
    expect(commands[1].shortcut, os.menuShortcut(const ['shift', 'cmd'], 'c'));
  });

  test('серые пункты из списка не пропадают', () {
    // Ровно та беда, ради которой проверка и стоит: на пустой очереди
    // недоступно почти всё, что делается с записями, — и список сочетаний
    // показывал четыре строки из пятнадцати. То есть был пуст ровно тогда,
    // когда в справку и заглядывают: до первой записи.
    final all = menuCommands(menus());
    expect(all.any((c) => c.label == 'Недоступно'), isTrue);
    expect(all.length, 4);
  });
}
