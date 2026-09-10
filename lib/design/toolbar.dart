// Внутренности macos_ui нужны здесь по делу: `OverflowHandler` — то самое,
// что решает, каким пунктам панели места не хватило, а `WallpaperTintingOverride`
// снимает подкраску обоями под размытой полосой. Ни то, ни другое пакет
// наружу не отдаёт, а без них панель пришлось бы писать целиком.
// ignore_for_file: implementation_imports

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_ui/src/layout/toolbar/overflow_handler.dart';
import 'package:macos_ui/src/layout/wallpaper_tinting_settings/wallpaper_tinting_override.dart';

import '../l10n/gen/app_localizations.dart';
import 'design.dart';

/// Выпадающая кнопка с цветом доступного действия.
///
/// Пакетная [ToolBarPullDownButton] всегда красит значок в 50%
/// прозрачности — точно как недоступный. В самом меню оставляем
/// пакетную реализацию, а в панели задаём тот же цвет, что у остальных
/// рабочих кнопок.
class AppToolBarPullDownButton extends ToolbarItem {
  const AppToolBarPullDownButton({
    super.key,
    required this.label,
    required this.icon,
    required this.items,
    this.tooltipMessage,
  });

  final String label;
  final IconData icon;
  final List<MacosPulldownMenuEntry> items;
  final String? tooltipMessage;

  @override
  Widget build(BuildContext context, ToolbarItemDisplayMode displayMode) {
    if (displayMode == ToolbarItemDisplayMode.overflowed) {
      return _OverflowPulldownButton(label: label, items: items);
    }
    return CustomToolbarItem(
      tooltipMessage: tooltipMessage,
      inToolbarBuilder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: MacosPulldownButtonTheme(
          data: MacosPulldownButtonTheme.of(
            context,
          ).copyWith(iconColor: Surface.toolbarIcon(context, enabled: true)),
          child: MacosPulldownButton(icon: icon, items: items),
        ),
      ),
    ).build(context, displayMode);
  }
}

/// Подменяет только подменю, которое пакет строит для спрятанной кнопки.
/// Обычный `ToolBarPullDownButton` оставляет от каждого пункта одну строку
/// `label` и теряет виджет `title`. Из-за этого галочка выбранного формата
/// и отступы отличались в зависимости от ширины окна. Здесь обе версии
/// используют один и тот же `title`.
class _OverflowPulldownButton extends StatefulWidget {
  const _OverflowPulldownButton({required this.label, required this.items});

  final String label;
  final List<MacosPulldownMenuEntry> items;

  @override
  State<_OverflowPulldownButton> createState() =>
      _OverflowPulldownButtonState();
}

class _OverflowPulldownButtonState extends State<_OverflowPulldownButton> {
  final _popup = GlobalKey<ToolbarPopupState>();
  bool _selected = false;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final item in widget.items)
        if (item is MacosPulldownMenuDivider)
          item
        else if (item is MacosPulldownMenuItem)
          _RichOverflowMenuItem(
            title: item.title,
            enabled: item.enabled,
            onPressed: () {
              item.onTap?.call();
              Navigator.of(context).pop();
            },
          ),
    ];
    return ToolbarPopup(
      key: _popup,
      content: (context) => MouseRegion(
        onExit: (_) {
          _popup.currentState?.removeToolbarPopupRoute();
          setState(() => _selected = false);
        },
        child: ToolbarOverflowMenu(children: children),
      ),
      position: ToolbarPopupPosition.side,
      placement: ToolbarPopupPlacement.start,
      child: MouseRegion(
        onHover: (_) {
          if (_selected) return;
          setState(() => _selected = true);
          _popup.currentState?.openPopup().whenComplete(() {
            if (mounted) setState(() => _selected = false);
          });
        },
        child: ToolbarOverflowMenuItem(
          label: widget.label,
          // Непустой список нужен системному пункту только для стрелки.
          subMenuItems: const [ToolbarOverflowMenuItem(label: '')],
          isSelected: _selected,
          onPressed: () {},
        ),
      ),
    );
  }
}

class _RichOverflowMenuItem extends StatefulWidget {
  const _RichOverflowMenuItem({
    required this.title,
    required this.enabled,
    required this.onPressed,
  });

  final Widget title;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_RichOverflowMenuItem> createState() => _RichOverflowMenuItemState();
}

class _RichOverflowMenuItemState extends State<_RichOverflowMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final brightness = MacosTheme.brightnessOf(context);
    final normal = brightness.resolve(MacosColors.black, MacosColors.white);
    final disabled = brightness.resolve(
      MacosColors.disabledControlTextColor,
      MacosColors.disabledControlTextColor.darkColor,
    );
    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled
            ? () {
                Navigator.of(context).pop();
                widget.onPressed();
              }
            : null,
        child: Container(
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: _hovered
                ? MacosPulldownButtonTheme.of(context).highlightColor
                : MacosColors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 13,
              color: !widget.enabled
                  ? disabled
                  : _hovered
                  ? MacosColors.white
                  : normal,
            ),
            child: widget.title,
          ),
        ),
      ),
    );
  }
}

/// Панель инструментов macos_ui с другим значком у списка спрятанного.
///
/// Форк ради одного значка выглядит несоразмерно, поэтому — почему он всё
/// же нужен и почему он такой маленький.
///
/// Когда пунктам панели перестаёт хватать места, macos_ui прячет лишние
/// и ставит на их место кнопку со значком `chevron_right_2` — «»». Значок
/// выбран неудачно: в окне с двумя боковыми колонками он стоит у правого
/// края и читается как «свернуть правую колонку», а не «показать
/// спрятанное». Хозяин на это и наткнулся: нажал, ожидая свернуть панель,
/// и получил меню экспорта.
///
/// Поменять значок настройкой нельзя: `ToolbarOverflowButton` пакет
/// создаёт сам, внутри своего `build`, и наружу этого не отдаёт.
/// А подсунуть `MacosScaffold` чужой виджет тоже нельзя — его поле
/// `toolBar` типизировано именно как [ToolBar].
///
/// Отсюда и вид форка: не копия файла, а наследник. Все поля [ToolBar]
/// открыты, `createState` тоже — значит достаточно своего состояния,
/// которое собирает то же дерево, что и пакет, с одной заменой. Копией
/// файла пришлось бы тянуть ещё и то, чем мы не пользуемся: заголовок
/// по центру, кнопку «назад», свою раскладку и свои поля.
class AppToolBar extends ToolBar {
  const AppToolBar({
    super.key,
    super.title,
    super.titleWidth,
    super.actions,
    super.dividerColor,
    super.enableBlur,
  });

  @override
  State<ToolBar> createState() => _AppToolBarState();
}

class _AppToolBarState extends State<ToolBar> {
  /// Сколько пунктов с конца сейчас спрятано. Считает [OverflowHandler]:
  /// он один знает, что во что поместилось.
  int _hidden = 0;

  @override
  void didUpdateWidget(ToolBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Список пунктов сменился — прежний счёт спрятанного к нему не
    // относится. Пересчитает тот же OverflowHandler на ближайшей раскладке.
    if (widget.actions?.length != oldWidget.actions?.length) _hidden = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final scope = MacosWindowScope.maybeOf(context);
    final actions = widget.actions ?? const <ToolbarItem>[];
    final overflowed = _hidden == 0
        ? const <ToolbarItem>[]
        : actions.sublist(actions.length - _hidden);

    Widget? title = widget.title;
    if (title != null) {
      title = SizedBox(
        width: widget.titleWidth,
        child: DefaultTextStyle(
          style: theme.typography.title3.copyWith(
            fontSize: 15,
            fontWeight: MacosFontWeight.w590,
          ),
          child: title,
        ),
      );
    }

    return MediaQuery(
      // Слева под панелью лежат кнопки окна — там ставить свои пункты
      // нельзя. Рисует их macOS в самой титульной полосе; на Windows их
      // там нет вовсе, и тот же отступ был бы просто дырой слева.
      data: MediaQuery.of(context).copyWith(
        padding: EdgeInsets.only(
          left:
              defaultTargetPlatform == TargetPlatform.macOS &&
                  !(scope?.isSidebarShown ?? false)
              ? 70
              : 0,
        ),
      ),
      child: _ground(
        theme,
        child: Builder(
          builder: (context) {
            final band = Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.inner,
                vertical: Gap.hint,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: widget.dividerColor ?? theme.dividerColor,
                  ),
                ),
              ),
              // Заголовок и кнопки идут одним рядом от левого края.
              // NavigationToolbar ставил заголовок в геометрический центр,
              // а кнопки прижимал вправо: между ними возникала пустыня,
              // хотя последние значки уже уходили под многоточие. Row отдаёт
              // OverflowHandler ровно остаток, поэтому ширину заголовка второй
              // раз в overflowBreakpoint вычитать не нужно.
              child: SafeArea(
                top: false,
                right: false,
                bottom: false,
                child: Row(
                  children: [
                    if (title != null) ...[
                      title,
                      const SizedBox(width: Gap.inner),
                    ],
                    Expanded(
                      child: OverflowHandler(
                        overflowWidget: _MoreButton(
                          items: [
                            for (final a in overflowed)
                              a.build(
                                context,
                                ToolbarItemDisplayMode.overflowed,
                              ),
                          ],
                        ),
                        overflowChangedCallback: (hidden) =>
                            setState(() => _hidden = hidden.length),
                        children: [
                          for (final a in actions)
                            a.build(context, ToolbarItemDisplayMode.inToolbar),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
            if (!widget.enableBlur) return band;
            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: band,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Подложка полосы: либо размытие того, что под ней, либо подкраска
  /// обоями. То же разделение, что и в пакете, и та же причина: подкраска
  /// умеет только цвет, а размытие — только там, где под окном есть чему
  /// размываться.
  Widget _ground(MacosThemeData theme, {required Widget child}) =>
      widget.enableBlur
      ? WallpaperTintingOverride(child: child)
      : WallpaperTintedArea(
          backgroundColor: theme.canvasColor,
          insertRepaintBoundary: true,
          child: child,
        );
}

/// Кнопка «остальное»: та же, что в macos_ui, с многоточием вместо «»»
/// и с подписью, которая говорит, что за ней.
class _MoreButton extends StatefulWidget {
  const _MoreButton({required this.items});
  final List<Widget> items;

  @override
  State<_MoreButton> createState() => _MoreButtonState();
}

class _MoreButtonState extends State<_MoreButton> {
  final _popup = GlobalKey<ToolbarPopupState>();

  @override
  Widget build(BuildContext context) => ToolbarPopup(
    key: _popup,
    content: (context) => ToolbarOverflowMenu(children: widget.items),
    verticalOffset: 8,
    horizontalOffset: 10,
    position: ToolbarPopupPosition.below,
    placement: ToolbarPopupPlacement.end,
    child: ToolBarIconButton(
      label: AppLocalizations.of(context).toolbarMore,
      tooltipMessage: AppLocalizations.of(context).tooltipToolbarMore,
      icon: const MacosIcon(CupertinoIcons.ellipsis),
      showLabel: false,
      onPressed: () => _popup.currentState?.openPopup(),
    ).build(context, ToolbarItemDisplayMode.inToolbar),
  );
}
