import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/text.dart';
import '../../../design/design.dart';

/// Обвязка окна: заголовок в панели инструментов, значок занятости
/// модели в строке состояния и заглушка пустого экрана.
class ToolbarTitle extends StatelessWidget {
  const ToolbarTitle({
    super.key,this.subtitle});
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(appName, style: Type.navTitle),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
        ],
      );
}

/// Шапка инспектора: к чему относится то, что ниже. Без неё правка настроек
/// при выбранной записи выглядела бы как правка общих.

class ModelChip extends StatefulWidget {
  const ModelChip({
    super.key,
    required this.label,
    required this.detail,
    required this.busy,
    required this.resting,
    required this.waiting,
  });

  /// Как назвать занятость и что рассказать в подсказке. Приходят готовыми:
  /// своё («Занято диктовкой») и чужое («Модель занята · имя») зовутся
  /// по-разному, а знает об этом окно, а не значок.
  final String label, detail;

  /// Занято ли — расшифровкой или диктовкой, всё равно.
  final bool busy;

  /// Модель лежит в памяти, но никто ей не пользуется.
  final bool resting;

  /// Наша очередь прямо сейчас стоит из-за этого.
  final bool waiting;

  @override
  State<ModelChip> createState() => ModelChipState();
}

class ModelChipState extends State<ModelChip> {
  @override
  Widget build(BuildContext context) {
    final color = widget.busy
        ? MacosColors.systemOrangeColor
        : widget.resting
            ? MacosColors.systemYellowColor
            : MacosColors.systemGreenColor;
    return MacosTooltip(
      message: widget.detail,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Пока очередь стоит из-за диктовки, точка пульсирует:
            // состояние временное, а не сломанное.
            Dot(color: color, pulsing: widget.waiting),
            const SizedBox(width: 7),
            Text(
              widget.label,
              style: Type.caption
                  .copyWith(color: Surface.secondaryText(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class Dot extends StatefulWidget {
  const Dot({
    super.key,required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<Dot> createState() => DotState();
}

class DotState extends State<Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(Dot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing == oldWidget.pulsing) return;
    widget.pulsing ? _pulse.repeat(reverse: true) : _pulse.animateTo(0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => AnimatedContainer(
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: widget.color.withValues(
            alpha: reduced ? 1 : 1 - _pulse.value * 0.65,
          ),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class EmptyNotice extends StatelessWidget {
  const EmptyNotice({
    super.key,required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(icon, size: 40, color: Surface.secondaryText(context)),
            const SizedBox(height: 14),
            Text(title, style: Type.emptyTitle, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Type.control.copyWith(
                color: Surface.secondaryText(context),
                height: 1.5,
              ),
            ),
          ],
        ),
      );
}

/// Путь как объект, а не как строка настройки: по нему можно щёлкнуть
/// и попасть в саму папку.
