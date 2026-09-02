import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/queue/menu_shortcuts.dart';

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
          const PlatformMenuItem(label: 'Недоступно'),
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
}
