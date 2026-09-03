import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/core/skill_install.dart';
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

    // Скилл живёт на вкладке «Приложение», ниже сгиба: список длинный,
    // и до раздела надо доехать. Проверяем, что он там вообще есть, —
    // иначе кнопка молча не появится ни у кого.
    await tester.tap(find.text('Приложение'));
    await tester.pump();
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно и стоит на экране.
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно стоит на экране.
    //
    // Едем до конца списка, а не до кнопки: кнопка есть только там, где
    // нашёлся хоть один нейросетевой агент. На сборочной машине их нет
    // вовсе, и там на месте кнопки стоит объяснение — раздел обязан
    // рисоваться в обоих случаях.
    await tester.dragUntilVisible(
      find.text('СКИЛЛ ДЛЯ НЕЙРОСЕТЕЙ'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('СКИЛЛ ДЛЯ НЕЙРОСЕТЕЙ'), findsOneWidget);

    // Кнопка стоит ниже списка найденных агентов, то есть ещё дальше
    // за сгибом: до неё надо доехать отдельно.
    if (skillAgents.any((a) => a.configDir() != null)) {
      await tester.dragUntilVisible(
        find.textContaining('Поставить скилл'),
        find.byType(ListView).first,
        const Offset(0, -120),
      );
      expect(find.textContaining('Поставить скилл'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    // Таймер опроса разрешений должен уйти вместе с окном.
    await tester.pumpWidget(const SizedBox());
  });
}
