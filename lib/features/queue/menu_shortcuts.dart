import 'package:flutter/widgets.dart';

import '../../platform/os.dart';

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

/// Одна команда меню: в каком разделе живёт, как называется и каким
/// сочетанием вызывается.
typedef MenuCommand = ({String menu, String label, String shortcut});

/// Все команды с сочетаниями — списком, разделами, как в самом меню.
///
/// Нужны там же, где и [shortcutsFromMenus], и по той же причине, но
/// с другой стороны: сочетания на Windows работают, а посмотреть их
/// негде — строки меню там нет вовсе, и человек о них попросту не знает.
/// Собираем из того же дерева, а не списком рядом: подсказка, разошедшаяся
/// с делом, хуже отсутствующей.
///
/// Без сочетания пункт не берём: до всего остального можно дотянуться
/// кнопкой, а этот список — именно про клавиши. А вот доступен пункт
/// прямо сейчас или нет — не важно вовсе: это справочник, а не панель
/// инструментов. Раньше здесь стояла проверка `onSelected != null`, и на
/// пустой очереди список показывал четыре строки из пятнадцати — всё,
/// что делается с записями, из него пропадало ровно тогда, когда человек
/// и открывает справку: до первой записи.
List<MenuCommand> menuCommands(List<PlatformMenuItem> menus) {
  final out = <MenuCommand>[];

  void walk(Iterable<PlatformMenuItem> items, String section) {
    for (final item in items) {
      if (item is PlatformMenu) {
        walk(item.menus, section.isEmpty ? item.label : section);
        continue;
      }
      if (item is PlatformMenuItemGroup) {
        walk(item.members, section);
        continue;
      }
      final label = menuShortcutLabel(item.shortcut);
      if (label == null) continue;
      out.add((menu: section, label: item.label, shortcut: label));
    }
  }

  walk(menus, '');
  return out;
}

/// Подпись сочетания словами той системы, на которой мы работаем.
///
/// Модификаторы называются по-макосному — так они и записаны в пунктах
/// меню; в слова и значки их переводит граница системы.
String? menuShortcutLabel(MenuSerializableShortcut? shortcut) {
  if (shortcut is! SingleActivator) return null;
  return os.menuShortcut([
    if (shortcut.control) 'ctrl',
    if (shortcut.alt) 'opt',
    if (shortcut.shift) 'shift',
    if (shortcut.meta) 'cmd',
  ], shortcut.trigger.keyLabel);
}
