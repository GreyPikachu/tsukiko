import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверка приёма, которым чинится чёрная боковая колонка на Windows.
///
/// macos_ui заворачивает содержимое левой колонки в
/// `DecoratedBox(color: чёрный, backgroundBlendMode: BlendMode.clear)` —
/// нарочно вырезает в кадре дыру, чтобы сквозь неё был виден материал
/// окна. На Windows материала нет, и в дыре чернота. Закрасить дыру
/// изнутри целиком нельзя: часть её — поля, которые рисует сам macos_ui.
///
/// Приём в `home_page.dart` такой: вырезанию даётся свой слой
/// (RepaintBoundary), а подложка кладётся под него. Держится он ровно на
/// одном допущении — что BlendMode.clear чистит только свой слой и
/// не пробивает то, что нарисовано под ним. Допущение это про внутренности
/// Flutter, проверить его на Windows вслепую нельзя, а сломать его может
/// любое обновление. Поэтому оно проверено здесь.
void main() {
  testWidgets('вырезание дыры чистит свой слой, а не подложку', (tester) async {
    const ground = Color(0xFF112233);
    final key = GlobalKey();

    Widget scene({required bool isolated}) {
      const hole = DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFF000000),
          backgroundBlendMode: BlendMode.clear,
        ),
        child: SizedBox.expand(),
      );
      return RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 20,
          height: 20,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: ground)),
              Positioned.fill(
                child: isolated
                    ? const ClipRect(
                        clipBehavior: Clip.antiAliasWithSaveLayer, child: hole)
                    : hole,
              ),
            ],
          ),
        ),
      );
    }

    Future<int> pixel({required bool isolated}) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: scene(isolated: isolated)),
      ));
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return data!.buffer.asUint8List();
      });
      final b = bytes!;
      return (b[3] << 24) | (b[0] << 16) | (b[1] << 8) | b[2];
    }

    // Без своего слоя дыра пробивает подложку насквозь — это ровно то,
    // что видит хозяин: чёрная колонка вместо серой.
    expect(await pixel(isolated: false), 0x00000000);
    // Со своим слоем подложка цела.
    expect(await pixel(isolated: true), ground.toARGB32());
  });
}
