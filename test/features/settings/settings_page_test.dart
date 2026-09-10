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
      ('Модели', 'АКТИВНЫЕ МОДЕЛИ'),
      ('Приложение', 'Показывать значок в ${os.appIconAreaName}'),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.text(marker), findsOneWidget, reason: 'вкладка «$label»');
      expect(tester.takeException(), isNull, reason: 'вкладка «$label»');
    }

    // Каталог длиннее окна, но все движки и ограничения доступны после
    // прокрутки, а не спрятаны в одном непрозрачном выпадающем списке.
    await tester.tap(find.text('Модели'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.textContaining('Parakeet TDT 0.6b v3'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('25 языков Европы'), findsOneWidget);
    expect(find.text('Без словарных подсказок'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'каталог моделей');

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
    // Раздел свёрнут: сам он на месте всегда, а содержимое появляется
    // только по щелчку — тому, кто нейросетями не пользуется, оно
    // мозолило бы глаза на каждом открытии настроек.
    // Заголовок раскрывашки написан обычными буквами — от заголовка
    // раздела (он прописными) отличается именно этим.
    await tester.dragUntilVisible(
      find.text('Скилл для нейросетей'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('СКИЛЛ ДЛЯ НЕЙРОСЕТЕЙ'), findsOneWidget);
    expect(find.text('Установлено для:'), findsNothing);

    await tester.tap(find.text('Скилл для нейросетей'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Поставить скилл'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('Установлено для:'), findsOneWidget);
    // Ненайденный агент в списке есть — и его галку можно поставить
    // самому: человек вправе поставить агента следом за нами.
    expect(find.textContaining('не найден'), findsWidgets);

    expect(tester.takeException(), isNull);

    // Таймер опроса разрешений должен уйти вместе с окном.
    await tester.pumpWidget(const SizedBox());
  });
}
