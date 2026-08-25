import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/features/settings/settings_page.dart';

/// Окно настроек живёт отдельным файлом теста намеренно: рисующий тест
/// заводит TestWidgetsFlutterBinding, а та подменяет HttpClient — рядом
/// с ней тесты загрузки моделей перестают видеть сеть.
void main() {
  testWidgets('окно настроек рисуется на всех четырёх вкладках', (tester) async {
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
      ('Модели', 'УСТАНОВЛЕНЫ'),
      ('Приложение', 'Показывать значок в ${os.appIconAreaName}'),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.text(marker), findsOneWidget, reason: 'вкладка «$label»');
      expect(tester.takeException(), isNull, reason: 'вкладка «$label»');
    }

    // Таймер опроса разрешений должен уйти вместе с окном.
    await tester.pumpWidget(const SizedBox());
  });
}
