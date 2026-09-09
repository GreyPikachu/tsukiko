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
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.inner, vertical: Gap.hint),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Пока очередь стоит из-за диктовки, точка пульсирует:
            // состояние временное, а не сломанное.
            Dot(color: color, pulsing: widget.waiting),
            const SizedBox(width: Gap.inner),
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
        // Поперечник тоже с общей шкалы, а не на глаз: точка меньше
        // самого мелкого значка ([IconSize.inline]) — это не знак, а
        // отметка при тексте, и спорить с буквами рядом ей нельзя.
        width: Gap.inner,
        height: Gap.inner,
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

/// Что сказал движок, когда не справился, — целиком и с переносами.
///
/// Отдельной коробкой, а не строкой подписи: жалоба движка бывает
/// в несколько строк, и половина смысла в них. В подпись под именем
/// записи влезает только начало, и выделить её оттуда нельзя вовсе —
/// а пока движок не поднимается, эта строка единственное, по чему
/// видно причину.
class EngineErrorBox extends StatelessWidget {
  const EngineErrorBox({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.inner),
        decoration: BoxDecoration(
          // Красным намекаем, а не кричим: коробка и так стоит первой.
          color: MacosColors.systemRedColor.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: MacosColors.systemRedColor.withValues(alpha: 0.25)),
        ),
        child: Text(
          text,
          // Без maxLines и обрезания: тут её и читают целиком.
          style: Type.caption.copyWith(height: 1.45),
        ),
      );
}

class EmptyNotice extends StatelessWidget {
  const EmptyNotice({
    super.key,required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        // Ровно то же поле и та же лесенка, что у пустого экрана с котом
        // (MascotEmpty): это два вида одного состояния, и разойтись видом
        // они не должны.
        padding: const EdgeInsets.all(Gap.section + Gap.inner),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(icon,
                size: IconSize.hero, color: Surface.secondaryText(context)),
            const SizedBox(height: Gap.item),
            Text(title, style: Type.emptyTitle, textAlign: TextAlign.center),
            const SizedBox(height: Gap.hint),
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
