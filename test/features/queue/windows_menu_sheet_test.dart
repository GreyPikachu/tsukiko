import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/queue/windows_menu_sheet.dart';

void main() {
  test('меню Windows берёт все команды из системного дерева', () {
    final sections = windowsMenuSections([
      PlatformMenu(
        label: 'Файл',
        menus: [
          PlatformMenuItem(label: 'Открыть', onSelected: () {}),
          const PlatformMenuItem(label: 'Сохранить'),
          PlatformMenu(
            label: 'Недавние',
            menus: [PlatformMenuItem(label: 'голос.ogg', onSelected: () {})],
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          ),
        ],
      ),
    ]);

    expect(sections.single.label, 'Файл');
    expect(sections.single.commands.map((c) => c.label), [
      'Открыть',
      'Сохранить',
      'голос.ogg',
    ]);
    expect(
      sections.single.commands[1].onSelected,
      isNull,
      reason: 'недоступная сейчас команда всё равно видна',
    );
    expect(sections.single.commands.last.group, 'Недавние');
  });
}
