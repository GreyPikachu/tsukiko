import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_windows.dart';
import 'package:tsukiko/core/labels.dart';

void main() {
  final win = WindowsOs();

  group('WindowsOs пути и имена', () {
    test('разделители путей и имена папок', () {
      expect(win.join(r'C:\Users\test', 'Documents', 'tsukiko'),
          r'C:\Users\test\Documents\tsukiko');
      expect(win.basename(r'C:\Program Files\tsukiko\tsukiko.exe'),
          'tsukiko.exe');
      expect(win.basename(r'C:/Users/test/model.bin'), 'model.bin');
      expect(win.dirname(r'C:\Program Files\tsukiko\tsukiko.exe'),
          r'C:\Program Files\tsukiko');
    });

    test('системные подписи и элементы интерфейса', () {
      expect(win.fileManagerName, 'Проводник');
      expect(win.appIconAreaName, 'панель задач');
      expect(win.menuBarName, 'область уведомлений');
      expect(win.settingsShortcut, 'Ctrl+,');
      expect(win.accessibilityName, 'специальные возможности');
    });

    test('модификаторы клавиш и сочетания в Windows-стиле', () {
      expect(win.modifierLabel('ctrl'), 'Ctrl');
      expect(win.modifierLabel('cmd'), 'Win');
      expect(win.modifierLabel('opt'), 'Alt');
      expect(win.modifierLabel('alt'), 'Alt');
      expect(win.modifierLabel('shift'), 'Shift');
      expect(win.modifierLabel('fn'), 'Fn');

      // Порядок модификаторов на Windows: Ctrl + Alt + Shift + Win + Fn
      expect(win.shortcutLabel(['shift', 'ctrl'], ['Пробел']),
          'Ctrl + Shift + Пробел');
      expect(win.shortcutLabel(['cmd', 'ctrl', 'alt'], ['O']),
          'Ctrl + Alt + Win + O');
    });

    test('движок выбирается по тому, запустится ли Vulkan-сборка', () {
      // Проверка идёт по загрузчику Vulkan в системе. Тест бежит на macOS,
      // где его нет, — значит Vulkan-сборка не предлагается вовсе, а не
      // предлагается первой: запустить её всё равно не вышло бы, Windows
      // убивает такой процесс до первой строки кода.
      final names = win.engineNames('tsukiko-recognizer');
      expect(names.contains('tsukiko-recognizer-vulkan.exe'), isFalse);
      expect(names.first, 'tsukiko-recognizer-cpu.exe');
      // Имя без суффикса остаётся запасным: подхватится и собранное руками.
      expect(names, contains('tsukiko-recognizer.exe'));
    });
  });
}
