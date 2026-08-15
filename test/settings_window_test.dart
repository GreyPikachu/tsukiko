import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform_mac.dart';
import 'package:tsukiko/settings_window.dart';

/// Окно настроек живёт отдельным файлом теста намеренно: рисующий тест
/// заводит TestWidgetsFlutterBinding, а та подменяет HttpClient — рядом
/// с ней тесты загрузки моделей перестают видеть сеть.
void main() {
  testWidgets('окно настроек рисуется на всех четырёх вкладках', (tester) async {
    // Размер настоящего окна: раскладка обязана сходиться именно в нём.
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(SettingsApp(MacPlatform()));
    await tester.pump();

    expect(find.text('Диктовка'), findsOneWidget);
    expect(find.text('Держать и говорить'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'вкладка «Диктовка»');

    for (final (label, marker) in [
      ('Модели', 'МОЖНО ЗАГРУЗИТЬ'),
      ('Файлы', 'Сохранять готовый текст на диск'),
      ('Общие', 'Показывать значок в Dock'),
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
