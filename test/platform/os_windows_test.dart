import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_windows.dart';

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
  });
}
