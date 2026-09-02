import 'package:flutter/widgets.dart';

/// Сочетания клавиш из тех же пунктов меню, что рисует строка меню.
///
/// Нужны там, где строки меню нет. `PlatformMenuBar` — вещь macOS: на
/// Windows он рисует только своё содержимое, а меню и сочетания
/// не появляются вовсе. То есть всё, что делается с клавиатуры —
/// «Добавить», «Распознать», «Копировать», «Найти», — там не работало
/// ни одним нажатием.
///
/// Собираем их из того же дерева меню, а не списком рядом: два списка
/// разошлись бы на первой же правке.
Map<ShortcutActivator, VoidCallback> shortcutsFromMenus(
  List<PlatformMenuItem> menus, {
  required bool swapMetaForControl,
}) {
  final out = <ShortcutActivator, VoidCallback>{};

  // Обходим по типам узлов, а не по `descendants`: у группы пунктов
  // он отдаёт её саму, без содержимого, — половина сочетаний терялась бы
  // молча.
  void walk(Iterable<PlatformMenuItem> items) {
    for (final item in items) {
      if (item is PlatformMenu) walk(item.menus);
      if (item is PlatformMenuItemGroup) walk(item.members);
      final shortcut = item.shortcut;
      final onSelected = item.onSelected;
      if (shortcut == null || onSelected == null) continue;
      final activator = swapMetaForControl ? _toControl(shortcut) : shortcut;
      if (activator != null) out[activator] = onSelected;
    }
  }

  walk(menus);
  return out;
}

/// ⌘ на macOS — это Ctrl на Windows. Клавиша Windows на её месте была бы
/// прямой ошибкой: системные сочетания с ней приложению не достаются,
/// а привычные Ctrl+C и Ctrl+F не сработали бы.
ShortcutActivator? _toControl(MenuSerializableShortcut shortcut) {
  if (shortcut is! SingleActivator) return shortcut;
  if (!shortcut.meta) return shortcut;
  return SingleActivator(
    shortcut.trigger,
    control: true,
    shift: shortcut.shift,
    alt: shortcut.alt,
  );
}
