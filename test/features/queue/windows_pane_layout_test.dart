import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/features/queue/windows_pane_layout.dart';

void main() {
  testWidgets('раскладка Windows не создаёт полноэкранный saveLayer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosApp(
        home: SizedBox(
          width: 1100,
          height: 700,
          child: WindowsPaneLayout(
            leftBuilder: (_, controller) => ListView(controller: controller),
            leftBottom: const Text('Добавить'),
            center: const ColoredBox(color: Color(0xFF112233)),
            rightBuilder: (_, controller) => ListView(controller: controller),
          ),
        ),
      ),
    );

    final clips = tester.allRenderObjects.whereType<RenderClipRect>();
    expect(
      clips.any((clip) => clip.clipBehavior == Clip.antiAliasWithSaveLayer),
      isFalse,
    );
    expect(find.text('Добавить'), findsOneWidget);
  });

  testWidgets('ширина левой колонки меняется перетаскиванием', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        home: SizedBox(
          width: 1100,
          height: 700,
          child: WindowsPaneLayout(
            leftBuilder: (_, controller) => ListView(controller: controller),
            leftBottom: const SizedBox.shrink(),
            center: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final before = tester.getSize(find.byType(ListView).first).width;
    await tester.dragFrom(Offset(before + 2, 300), const Offset(60, 0));
    await tester.pump();
    final after = tester.getSize(find.byType(ListView).first).width;
    expect(after, greaterThan(before));
  });

  testWidgets(
    'раскладка отключает подкраску обоями на Windows и красит центр в canvasColor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MacosApp(
          home: SizedBox(
            width: 1100,
            height: 700,
            child: WindowsPaneLayout(
              leftBuilder: (_, controller) => ListView(controller: controller),
              leftBottom: const SizedBox.shrink(),
              center: const Text('Центр'),
              rightBuilder: (_, controller) => ListView(controller: controller),
            ),
          ),
        ),
      );

      final coloredBoxes = tester.widgetList<ColoredBox>(
        find.byType(ColoredBox),
      );
      // Центр имеет фон canvasColor
      expect(
        coloredBoxes.any(
          (b) =>
              b.color == const Color.fromRGBO(40, 40, 40, 1.0) ||
              b.color == const Color.fromRGBO(246, 246, 246, 1.0),
        ),
        isTrue,
      );
      // Правая колонка присутствует
      expect(find.byType(ListView), findsNWidgets(2));
    },
  );
}
