part of 'main.dart';

/// Обвязка окна: заголовок в панели инструментов, значок занятости
/// модели в строке состояния и заглушка пустого экрана.
class _ToolbarTitle extends StatelessWidget {
  const _ToolbarTitle({this.subtitle});
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

class _ModelChip extends StatefulWidget {
  const _ModelChip({
    required this.info,
    required this.label,
    required this.detail,
    required this.busy,
    required this.yielding,
    required this.waiting,
    required this.onTap,
  });
  final ModelUse info;

  /// Как назвать занятость и что рассказать в подсказке. Приходят готовыми:
  /// своё («Занято диктовкой») и чужое («Модель занята · Dictara») зовутся
  /// по-разному, а знает об этом окно, а не значок.
  final String label, detail;

  /// Занято ли — с нашей собственной расшифровкой вместе.
  final bool busy;

  final bool yielding;

  /// Наша очередь прямо сейчас стоит из-за этого.
  final bool waiting;
  final VoidCallback onTap;

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.busy && widget.info.state == ModelState.free
        ? MacosColors.systemOrangeColor
        : switch (widget.info.state) {
            ModelState.busy => MacosColors.systemOrangeColor,
            ModelState.loading => MacosColors.systemYellowColor,
            ModelState.free => MacosColors.systemGreenColor,
          };
    return MacosTooltip(
      message: '${widget.detail}\n'
          '${widget.yielding ? 'Очередь ждёт, пока модель освободится. Нажмите, чтобы не ждать.' : 'Работаем, даже если модель занята. Нажмите, чтобы уступать.'}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.dur(context, Motion.quick),
            curve: Motion.curve(context, Motion.quickCurve),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: _hover ? Surface.hover(context) : MacosColors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Пока мы стоим из-за соседа, точка пульсирует: состояние
                // временное, а не сломанное.
                _Dot(color: color, pulsing: widget.waiting),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: Type.caption.copyWith(
                    color: Surface.secondaryText(context),
                    decoration: widget.yielding ? null : TextDecoration.lineThrough,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing == old.pulsing) return;
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

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.title, required this.subtitle});
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
