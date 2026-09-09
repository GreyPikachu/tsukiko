import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import 'menu_shortcuts.dart';

typedef WindowsMenuCommand = ({
  String label,
  String? group,
  String? shortcut,
  VoidCallback? onSelected,
});

typedef WindowsMenuSection = ({
  String label,
  List<WindowsMenuCommand> commands,
});

/// То же дерево команд, что macOS показывает в строке меню.
///
/// PlatformProvidedMenuItem — родные команды AppKit вроде «скрыть
/// остальные». На Windows у них нет ни подписи, ни действия, поэтому
/// они отсеиваются. Остальные, включая временно недоступные, видны:
/// иначе меню меняло бы состав от каждого выделения в очереди.
List<WindowsMenuSection> windowsMenuSections(List<PlatformMenuItem> menus) {
  final sections = <WindowsMenuSection>[];
  for (final top in menus.whereType<PlatformMenu>()) {
    final commands = <WindowsMenuCommand>[];

    void walk(Iterable<PlatformMenuItem> items, [String? group]) {
      for (final item in items) {
        if (item is PlatformProvidedMenuItem) continue;
        if (item is PlatformMenu) {
          walk(item.menus, item.label);
          continue;
        }
        if (item is PlatformMenuItemGroup) {
          walk(item.members, group);
          continue;
        }
        commands.add((
          label: item.label,
          group: group,
          shortcut: menuShortcutLabel(item.shortcut),
          onSelected: item.onSelected,
        ));
      }
    }

    walk(top.menus);
    if (commands.isNotEmpty) {
      sections.add((label: top.label, commands: commands));
    }
  }
  return sections;
}

/// Меню приложения для Windows: слева те же разделы, справа — все их
/// команды с сочетаниями. Дерево приходит из [PlatformMenuBar], так что
/// маковская строка, сочетания и этот лист не могут разойтись.
class WindowsMenuSheet extends StatefulWidget {
  const WindowsMenuSheet({super.key, required this.sections});

  final List<WindowsMenuSection> sections;

  @override
  State<WindowsMenuSheet> createState() => _WindowsMenuSheetState();
}

class _WindowsMenuSheetState extends State<WindowsMenuSheet> {
  var _selected = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final section =
        widget.sections[_selected.clamp(0, widget.sections.length - 1)];
    return MacosSheet(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Gap.section,
              Gap.section,
              Gap.section,
              Gap.control,
            ),
            child: Text(l10n.sheetApplicationMenuTitle, style: Type.emptyTitle),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 180,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(left: Gap.item),
                    itemCount: widget.sections.length,
                    itemBuilder: (context, index) => _SectionButton(
                      label: widget.sections[index].label,
                      selected: index == _selected,
                      onTap: () => setState(() => _selected = index),
                    ),
                  ),
                ),
                Container(width: 1, color: Surface.hairline(context)),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.section,
                      Gap.inner,
                      Gap.section,
                      Gap.section,
                    ),
                    children: [
                      for (var i = 0; i < section.commands.length; i++) ...[
                        if (section.commands[i].group != null &&
                            (i == 0 ||
                                section.commands[i - 1].group !=
                                    section.commands[i].group))
                          SectionTitle(section.commands[i].group!),
                        _CommandButton(
                          command: section.commands[i],
                          onRun: (action) {
                            Navigator.pop(context);
                            Future<void>.delayed(Duration.zero, action);
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.edge),
            child: Align(
              alignment: Alignment.centerRight,
              child: PushButton(
                controlSize: ControlSize.large,
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.buttonClose),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: Gap.inner, bottom: Gap.tight),
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.inner,
        vertical: Gap.control,
      ),
      decoration: BoxDecoration(
        color: selected ? MacosTheme.of(context).primaryColor : null,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: Type.control.copyWith(
          color: selected ? MacosColors.white : null,
        ),
      ),
    ),
  );
}

class _CommandButton extends StatelessWidget {
  const _CommandButton({required this.command, required this.onRun});

  final WindowsMenuCommand command;
  final ValueChanged<VoidCallback> onRun;

  @override
  Widget build(BuildContext context) {
    final enabled = command.onSelected != null;
    return Opacity(
      opacity: enabled ? 1 : 0.42,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onRun(command.onSelected!) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.inner),
          child: Row(
            children: [
              Expanded(child: Text(command.label, style: Type.control)),
              if (command.shortcut case final shortcut?) ...[
                const SizedBox(width: Gap.item),
                Text(
                  shortcut,
                  style: Type.timestamp.copyWith(
                    color: Surface.secondaryText(context),
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
