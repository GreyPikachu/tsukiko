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
