import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../design/design.dart';

typedef PaneBuilder =
    Widget Function(BuildContext context, ScrollController controller);

/// Трёхколоночная раскладка главного окна там, где нет материала macOS.
///
/// Пакетный [MacosWindow] вырезает левую колонку через BlendMode.clear,
/// чтобы показать NSVisualEffectView. На Windows за вырезом ничего нет,
/// и прежняя компенсация изолировала всё окно через saveLayer. Любая
/// анимация после этого заново рисовала полноэкранный буфер.
///
/// Здесь колонки обычные непрозрачные поверхности. Они сохраняют
/// изменение ширины, но не создают ни размытия, ни полноэкранного слоя.
class WindowsPaneLayout extends StatefulWidget {
  const WindowsPaneLayout({
    super.key,
    required this.leftBuilder,
    required this.leftBottom,
    required this.center,
    this.rightBuilder,
    this.leftWidth = 276,
    this.leftMinWidth = 248,
    this.leftMaxWidth = 400,
    this.rightWidth = 312,
    this.rightMinWidth = 290,
    this.rightMaxWidth = 380,
    this.topOffset = 51,
  });

  final PaneBuilder leftBuilder;
  final Widget leftBottom;
  final Widget center;
  final PaneBuilder? rightBuilder;
  final double leftWidth, leftMinWidth, leftMaxWidth;
  final double rightWidth, rightMinWidth, rightMaxWidth;
  final double topOffset;

  @override
  State<WindowsPaneLayout> createState() => _WindowsPaneLayoutState();
}

class _WindowsPaneLayoutState extends State<WindowsPaneLayout> {
  late double _left = widget.leftWidth;
  late double _right = widget.rightWidth;
  final _leftScroll = ScrollController();
  final _rightScroll = ScrollController();

  static const _dividerWidth = 7.0;
  static const _minimumCenter = 320.0;

  @override
  void dispose() {
    _leftScroll.dispose();
    _rightScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final hasRight =
          widget.rightBuilder != null &&
          bounds.maxWidth >=
              widget.leftMinWidth +
                  widget.rightMinWidth +
                  _minimumCenter +
                  _dividerWidth * 2;
      final right = hasRight
          ? _right.clamp(widget.rightMinWidth, widget.rightMaxWidth)
          : 0.0;
      final left = _left.clamp(
        widget.leftMinWidth,
        (bounds.maxWidth -
                right -
                _minimumCenter -
                _dividerWidth * (hasRight ? 2 : 1))
            .clamp(widget.leftMinWidth, widget.leftMaxWidth),
      );

      return ColoredBox(
        color: Surface.sidebar(context) ?? MacosTheme.of(context).canvasColor,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: left,
              child: _pane(
                context,
                controller: _leftScroll,
                builder: widget.leftBuilder,
                bottom: widget.leftBottom,
              ),
            ),
            _PaneDivider(onDrag: (dx) => setState(() => _left = left + dx)),
            Expanded(child: widget.center),
            if (hasRight) ...[
              _PaneDivider(onDrag: (dx) => setState(() => _right = right - dx)),
              SizedBox(
                width: right,
                child: _pane(
                  context,
                  controller: _rightScroll,
                  builder: widget.rightBuilder!,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _pane(
    BuildContext context, {
    required ScrollController controller,
    required PaneBuilder builder,
    Widget? bottom,
  }) => ColoredBox(
    color: Surface.sidebar(context) ?? MacosTheme.of(context).canvasColor,
    child: Column(
      children: [
        SizedBox(height: widget.topOffset),
        Expanded(
          child: MacosScrollbar(
            controller: controller,
            child: builder(context, controller),
          ),
        ),
        if (bottom != null)
          Padding(padding: const EdgeInsets.all(Gap.edge), child: bottom),
      ],
    ),
  );
}

class _PaneDivider extends StatelessWidget {
  const _PaneDivider({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (event) => onDrag(event.delta.dx),
      child: SizedBox(
        width: _WindowsPaneLayoutState._dividerWidth,
        child: Center(
          child: Container(width: 1, color: Surface.hairline(context)),
        ),
      ),
    ),
  );
}
