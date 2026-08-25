import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';
import 'package:macos_ui/macos_ui.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../platform/os.dart';

/// Пружины и типографика по формулировкам Apple: не «длительность и кривая»,
/// а «отклик» (за сколько дойти) и «затухание» (насколько перелетит).

class SpringCurve extends Curve {
  SpringCurve({required this.duration, double response = 0.4, double dampingRatio = 1.0})
      : _sim = SpringSimulation(
          SpringDescription.withDampingRatio(
            mass: 1,
            stiffness: math.pow(2 * math.pi / response, 2).toDouble(),
            ratio: dampingRatio,
          ),
          0,
          1,
          0,
        );

  final Duration duration;
  final SpringSimulation _sim;

  @override
  double transformInternal(double t) {
    if (t >= 1) return 1;
    return _sim.x(t * duration.inMicroseconds / Duration.microsecondsPerSecond);
  }
}

class Motion {
  /// Перемещение и раскрытие: критическое затухание, без перелёта.
  static const settle = Duration(milliseconds: 380);
  static final settleCurve = SpringCurve(duration: settle, response: 0.4);

  /// Быстрый отклик на наведение и нажатие.
  static const quick = Duration(milliseconds: 220);
  static final quickCurve = SpringCurve(duration: quick, response: 0.25);

  /// Перелёт разрешён только там, где жесту предшествовал импульс —
  /// перетаскивание файла в окно.
  static const toss = Duration(milliseconds: 340);
  static final tossCurve =
      SpringCurve(duration: toss, response: 0.3, dampingRatio: 0.72);

  /// Нажатие подсвечивается мгновенно — задержка убивает ощущение прямоты.
  static const press = Duration(milliseconds: 90);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// При «уменьшить движение» остаётся мягкое затухание, а не пустота.
  static Duration dur(BuildContext context, Duration d) =>
      reduced(context) ? const Duration(milliseconds: 150) : d;

  static Curve curve(BuildContext context, Curve c) =>
      reduced(context) ? Curves.easeOut : c;

  static double slide(BuildContext context, double px) => reduced(context) ? 0 : px;
}

/// Шкала отступов, шаг 4: других значений в приложении нет.
///
/// Смысл шкалы не в числах, а в порядке: пояснение стоит к своей подписи
/// вчетверо ближе, чем следующий блок к концу предыдущего. Пока это
/// соотношение держится, глаз сам собирает настройку и её пояснение в одно.
class Gap {
  /// Подпись и её пояснение — самое тесное расстояние в приложении.
  static const hint = 4.0;

  /// Внутри одной настройки: подпись над полем, кнопка под путём.
  static const inner = 8.0;

  /// Между соседними настройками одного раздела.
  static const item = 16.0;

  /// Перед заголовком раздела.
  static const section = 24.0;

  /// Поля слева и справа: в окне настроек одно, в узких панелях другое.
  static const edge = 20.0;
  static const edgeNarrow = 16.0;
}

/// Размер, насыщенность и межбуквенное — единым набором.
/// Крупному тексту трекинг отрицательный, мелкому — положительный.
class Type {
  static const navTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const emptyTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.35,
    height: 1.2,
  );

  /// Главное состояние поповера: крупнее всего остального в нём, поэтому
  /// трекинг уходит в минус — на этом кегле буквы иначе стоят слишком врозь.
  static const stateTitle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.4,
    height: 1.15,
  );

  static const sectionHeader = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.65,
  );

  static const body = TextStyle(
    fontSize: 13.5,
    height: 1.55,
    letterSpacing: 0,
  );

  static const control = TextStyle(fontSize: 12.5, letterSpacing: 0.1);

  static const fileName = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
  );

  static const caption = TextStyle(fontSize: 11.5, letterSpacing: 0.2);

  static const timestamp = TextStyle(
    fontSize: 11.5,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Материалы. Крупная поверхность читается плотнее мелкой, светлое
/// полупрозрачное не кладётся на светлое полупрозрачное.
class Surface {
  static bool isDark(BuildContext context) =>
      MacosTheme.of(context).brightness == Brightness.dark;

  static Color chrome(BuildContext context) => isDark(context)
      ? const Color(0xE6202023)
      : const Color(0xE6F7F7F9);

  static Color hairline(BuildContext context) => isDark(context)
      ? const Color(0x2BFFFFFF)
      : const Color(0x1A000000);

  static Color hover(BuildContext context) =>
      isDark(context) ? const Color(0x14FFFFFF) : const Color(0x0D000000);

  static Color pressed(BuildContext context) =>
      isDark(context) ? const Color(0x24FFFFFF) : const Color(0x17000000);

  static Color secondaryText(BuildContext context) =>
      isDark(context) ? const Color(0x99FFFFFF) : const Color(0x8C000000);

  /// Цвет подсказки в пустом поле ввода. Умолчание macos_ui —
  /// CupertinoColors.placeholderText, а он разрешается через CupertinoTheme,
  /// которого под MacosApp нет: на тёмной теме получалось тёмное на тёмном.
  static TextStyle placeholder(BuildContext context) =>
      TextStyle(color: secondaryText(context));
}

// ── общие элементы настроек ─────────────────────────────────────────────────
//
// Одни и те же строки стоят в инспекторе главного окна и в окне настроек:
// это разные изоляты, и без общего места они разошлись бы видом.

/// Поле ввода с читаемой подсказкой на обеих темах.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.maxLines = 1,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => MacosTextField(
        controller: controller,
        placeholder: placeholder,
        placeholderStyle: Surface.placeholder(context),
        maxLines: maxLines,
        onChanged: onChanged,
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.section, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
        ),
      );
}

/// Пояснение к тому, что стоит НАД ним, и ни к чему больше: снизу отступа
/// нет вовсе, сверху — самый маленький в шкале. Расстояние до следующей
/// настройки задаёт та настройка, и оно всегда больше.
///
/// [under] — пояснение к галке: тогда оно встаёт под её подписью, а не под
/// самой галкой, и колонка текста не рвётся.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.under = false});
  final String text;
  final bool under;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: Gap.hint, left: under ? 25 : 0),
        child: Text(
          text,
          style: Type.caption.copyWith(
            color: Surface.secondaryText(context),
            height: 1.4,
          ),
        ),
      );
}

class Check extends StatefulWidget {
  const Check(this.label, this.value, this.onChanged, {super.key});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<Check> createState() => _CheckState();
}

class _CheckState extends State<Check> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onChanged(!widget.value),
          child: AnimatedContainer(
            duration: Motion.dur(context, Motion.press),
            curve: Curves.easeOut,
            // Слева поля нет: подсветка начинается ровно там же, где
            // заголовки разделов и пояснения. Иначе у каждой галки свой
            // левый край, и колонка рассыпается.
            padding: const EdgeInsets.fromLTRB(0, 5, 6, 5),
            decoration: BoxDecoration(
              color: _hover ? Surface.hover(context) : MacosColors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MacosCheckbox(value: widget.value, onChanged: widget.onChanged),
                const SizedBox(width: 9),
                Expanded(child: Text(widget.label, style: Type.control)),
              ],
            ),
          ),
        ),
      );
}

/// Сочетание клавиш плашкой. Одна на всё приложение: в настройках по ней
/// назначают новое сочетание, в поповере она просто показывает нынешнее —
/// и там и там из вида читается, что это значение, а не подпись.
class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key, this.lit = false});
  final String keys;
  final bool lit;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: Motion.dur(context, Motion.quick),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: lit ? Surface.pressed(context) : Surface.hover(context),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Surface.hairline(context)),
        ),
        child: Text(keys, style: Type.control),
      );
}

/// Сочетание клавиш: нажатие на чип включает захват, и следующая
/// комбинация встаёт на его место. Ждём ровно столько же, сколько ждёт
/// сторона macOS, иначе чип завис бы в «нажмите сочетание» навсегда.
class HotkeyRow extends StatefulWidget {
  const HotkeyRow({
    super.key,
    required this.label,
    required this.keys,
    required this.onTap,
  });
  final String label, keys;
  final Future<void> Function() onTap;

  @override
  State<HotkeyRow> createState() => _HotkeyRowState();
}

class _HotkeyRowState extends State<HotkeyRow> {
  bool _hover = false, _waiting = false;

  Future<void> _tap() async {
    setState(() => _waiting = true);
    await widget.onTap();
    if (mounted) setState(() => _waiting = false);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _waiting ? null : _tap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(child: Text(widget.label, style: Type.control)),
                KeyCap(
                  _waiting ? 'Нажмите сочетание…' : widget.keys,
                  lit: _hover || _waiting,
                ),
              ],
            ),
          ),
        ),
      );
}

/// Путь как объект, а не как строка настройки: по нему можно щёлкнуть
/// и попасть в саму папку.
class LibraryPath extends StatefulWidget {
  const LibraryPath({
    super.key,
    required this.path,
    required this.onReveal,
    required this.onChange,
    this.hint,
  });
  final String path;
  final VoidCallback onReveal, onChange;

  /// Пояснение к самому пути. Стоит между путём и кнопкой, а не после
  /// кнопки: снаружи оно оказывалось ближе к кнопке, чем кнопка к пути,
  /// и читалось как пояснение к ней.
  final String? hint;

  @override
  State<LibraryPath> createState() => _LibraryPathState();
}

class _LibraryPathState extends State<LibraryPath> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final short = widget.path.replaceFirst(home, '~');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MacosTooltip(
          message: 'Показать в ${os.fileManagerName}',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onReveal,
              child: AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                curve: Motion.curve(context, Motion.quickCurve),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: _hover ? Surface.hover(context) : MacosColors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Surface.hairline(context)),
                ),
                child: Row(
                  children: [
                    MacosIcon(CupertinoIcons.folder,
                        size: 14, color: Surface.secondaryText(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        short,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.control,
                      ),
                    ),
                    AnimatedOpacity(
                      duration: Motion.dur(context, Motion.quick),
                      opacity: _hover ? 1 : 0,
                      child: MacosIcon(CupertinoIcons.arrow_up_right_square,
                          size: 13, color: Surface.secondaryText(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.hint != null) Hint(widget.hint!),
        const SizedBox(height: Gap.item),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: widget.onChange,
          child: const Text('Выбрать другую папку…'),
        ),
      ],
    );
  }
}

/// Один список моделей вместо трёх кнопок рядом: сверху то, что уже есть
/// на диске, ниже — то, что приложение умеет достать само, с размером.
/// Выбор ненайденной модели начинает её загрузку.
///
/// Разделитель обязателен: без него «есть» и «можно скачать» сливаются
/// в один список, и выбор молча уходит в сеть на полтора гигабайта.
class ModelField extends StatelessWidget {
  const ModelField({
    super.key,
    required this.installed,
    required this.value,
    required this.onChosen,
    required this.onDownload,
    this.fallback,
  });

  final List<String> installed;
  final String value;
  final ValueChanged<String> onChosen;
  final ValueChanged<ModelOffer> onDownload;

  /// Подпись пустого выбора там, где пустой выбор что-то значит: у диктовки
  /// это «как у расшифровщика». Она же становится первым пунктом списка —
  /// иначе, выбрав модель однажды, вернуться к общей было бы нечем.
  /// Пусто — модель обязана быть выбрана, и пункта нет.
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    final offers = modelOffers(installed);
    final f = fallback;
    return MacosPopupButton<String>(
      value: installed.contains(value) ? value : (f == null ? null : ''),
      hint: Text(f ?? 'Не выбрана'),
      items: [
        if (f != null) MacosPopupMenuItem(value: '', child: Text(f)),
        for (final m in installed)
          MacosPopupMenuItem(
            value: m,
            // Не просто имя: две «Large v3 Turbo» из разных папок выглядели
            // в списке одинаково, и какая выбрана — понять было нельзя.
            child: Text(modelLabel(m, installed)),
          ),
        if (offers.isNotEmpty && installed.isNotEmpty)
          MacosPopupMenuItem(
            enabled: false,
            child: Text(
              'Можно загрузить',
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
          ),
        for (final m in offers)
          MacosPopupMenuItem(
            value: m.path,
            child: Text('${m.title} · ${m.size}'),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v.isEmpty || installed.contains(v)) return onChosen(v);
        final offer = modelCatalog.firstWhere((m) => m.path == v);
        onDownload(offer);
      },
    );
  }
}

/// Ход загрузки модели. Пока файл едет, кнопок нет: вторая полуторагиговая
/// качка рядом с первой только замедлит обе.
class ModelDownload extends StatelessWidget {
  const ModelDownload({
    super.key,
    required this.title,
    required this.progress,
    required this.percent,
    required this.onCancel,
  });

  /// Значения, а не сам загрузчик: он меняется внутри себя, и виджет,
  /// державший на него ссылку, не замечал бы, что процент сдвинулся.
  final String title, progress;
  final int percent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Загрузка: $title', style: Type.control),
          const SizedBox(height: 7),
          ProgressBar(value: percent.toDouble()),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: Text(
                  progress,
                  style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                ),
              ),
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: onCancel,
                child: const Text('Отменить'),
              ),
            ],
          ),
        ],
      );
}

// ── контекстное меню ────────────────────────────────────────────────────────
//
// В macos_ui меню умеют только кнопки, а по правому щелчку в macOS меню есть
// у всего. Панель берём готовую — MacosOverlayFilter, тот же материал, что
// у выпадающих списков, — своим остаётся только раскладка и попадание в экран.

class MenuAction {
  const MenuAction(this.label, {this.onSelected, this.shortcut});

  /// Разделитель: собственной надписи и действия у него нет.
  const MenuAction.separator() : label = '', onSelected = null, shortcut = null;

  final String label;
  final VoidCallback? onSelected;
  final String? shortcut;

  bool get isSeparator => label.isEmpty;
  bool get enabled => onSelected != null;
}

/// Меню у точки щелчка. Пункты без действия показываются серыми — как в
/// системе, где недоступная команда остаётся на своём месте.
Future<void> showContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<MenuAction> actions,
) {
  if (actions.every((a) => a.isSeparator || !a.enabled)) return Future.value();
  return Navigator.of(context, rootNavigator: true).push(
    _ContextMenuRoute(
      at: globalPosition,
      actions: actions,
      theme: MacosTheme.of(context),
    ),
  );
}

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({required this.at, required this.actions, required this.theme});

  final Offset at;
  final List<MenuAction> actions;
  final MacosThemeData theme;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Закрыть меню';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> _) {
    return MacosTheme(
      data: theme,
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(at),
        child: FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          child: _ContextMenuPanel(actions: actions),
        ),
      ),
    );
  }
}

/// Меню открывается вправо-вниз от курсора и разворачивается в другую сторону,
/// если там край экрана.
class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout(this.at);
  final Offset at;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - 16, c.maxHeight - 16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = at.dx + child.width > size.width - 8
        ? math.max(8.0, at.dx - child.width)
        : at.dx;
    final y = at.dy + child.height > size.height - 8
        ? math.max(8.0, at.dy - child.height)
        : at.dy;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.at != at;
}

class _ContextMenuPanel extends StatelessWidget {
  const _ContextMenuPanel({required this.actions});
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
        child: MacosOverlayFilter(
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in actions)
                  if (a.isSeparator)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                      child: Container(height: 1, color: Surface.hairline(context)),
                    )
                  else
                    _ContextMenuRow(action: a),
              ],
            ),
          ),
        ),
      );
}

class _ContextMenuRow extends StatefulWidget {
  const _ContextMenuRow({required this.action});
  final MenuAction action;

  @override
  State<_ContextMenuRow> createState() => _ContextMenuRowState();
}

class _ContextMenuRowState extends State<_ContextMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final accent = MacosTheme.of(context).primaryColor;
    final lit = _hover && a.enabled;
    final fg = !a.enabled
        ? Surface.secondaryText(context).withValues(alpha: 0.5)
        : lit
            ? MacosColors.white
            : null;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: a.enabled
            ? () {
                Navigator.of(context).pop();
                a.onSelected!();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: lit ? accent : MacosColors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Text(a.label, style: Type.control.copyWith(color: fg)),
              if (a.shortcut != null) ...[
                const SizedBox(width: 28),
                const Spacer(),
                Text(
                  a.shortcut!,
                  style: Type.control.copyWith(
                    color: fg ?? Surface.secondaryText(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Правый щелчок (он же двумя пальцами по трекпаду). Собственный обработчик
/// нажатия у ребёнка не трогаем — это разные кнопки мыши.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.actions,
    required this.child,
    this.onOpen,
  });

  /// Пункты меню. Должны только считать: щелчок — это [onOpen].
  final List<MenuAction> Function() actions;

  /// Что сделать до сборки пунктов. Сюда уходит всё, что меняет состояние
  /// (например, выделить строку под курсором), — иначе setState случался бы
  /// посреди построения меню.
  final VoidCallback? onOpen;

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) {
          onOpen?.call();
          showContextMenu(context, d.globalPosition, actions());
        },
        child: child,
      );
}
