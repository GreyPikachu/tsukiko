part of 'main.dart';

/// Правая панель: к чему относятся настройки, путь к библиотеке
/// и мелочи, из которых она собрана.
class _ScopeBanner extends StatelessWidget {
  const _ScopeBanner({
    required this.selection,
    required this.name,
    required this.changed,
    required this.onReset,
    required this.onMakeDefault,
  });

  final int selection;
  final String? name;
  final List<String> changed;
  final VoidCallback? onReset, onMakeDefault;

  @override
  Widget build(BuildContext context) {
    final (title, hint) = switch (selection) {
      0 => ('Настройки по умолчанию', 'Применяются ко всем новым записям.'),
      1 => (
          name ?? 'Запись',
          changed.isEmpty
              ? 'Настройки как по умолчанию. Изменения здесь коснутся только этой записи.'
              : 'Своё: ${changed.join(', ')}.'
        ),
      _ => (
          'Выбрано: ${recordsLabel(selection)}',
          'Изменения применятся ко всем выбранным записям.'
        ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: Surface.hover(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MacosIcon(
                selection == 0 ? CupertinoIcons.slider_horizontal_3 : CupertinoIcons.doc_text,
                size: 13,
                color: Surface.secondaryText(context),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.fileName),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: Type.caption.copyWith(
              color: Surface.secondaryText(context),
              height: 1.35,
            ),
          ),
          if (onReset != null) ...[
            const SizedBox(height: 9),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onReset,
                  child: const Text('Вернуть общие'),
                ),
                const SizedBox(width: 6),
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onMakeDefault,
                  child: const Text('Сделать общими'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LibraryPath extends StatefulWidget {
  const _LibraryPath({
    required this.path,
    required this.onReveal,
    required this.onChange,
  });
  final String path;
  final VoidCallback onReveal, onChange;

  @override
  State<_LibraryPath> createState() => _LibraryPathState();
}

class _LibraryPathState extends State<_LibraryPath> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final short = widget.path.replaceFirst(home, '~');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MacosTooltip(
          message: 'Показать в Finder',
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
        const SizedBox(height: 8),
        PushButton(
          controlSize: ControlSize.small,
          secondary: true,
          onPressed: widget.onChange,
          child: const Text('Выбрать другую папку…'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 7),
        child: Text(
          text.toUpperCase(),
          style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          text,
          style: Type.caption.copyWith(
            color: Surface.secondaryText(context),
            height: 1.4,
          ),
        ),
      );
}

class _Check extends StatefulWidget {
  const _Check(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_Check> createState() => _CheckState();
}

class _CheckState extends State<_Check> {
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
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
