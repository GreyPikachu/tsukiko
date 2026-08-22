import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/text.dart';
import '../../../design/design.dart';

/// Правая панель: к чему относятся настройки, путь к библиотеке
/// и мелочи, из которых она собрана.
class ScopeBanner extends StatelessWidget {
  const ScopeBanner({
    super.key,
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
    // Первая строка отвечает на единственный вопрос, который здесь
    // возникает: то, что я сейчас трогаю, — общее или только этой записи?
    final (title, hint) = switch (selection) {
      0 => (
          'Меняете общие настройки',
          'Они применятся ко всем новым записям. Выберите запись в очереди, '
              'чтобы менять только её.'
        ),
      1 => (
          'Меняете только эту запись',
          changed.isEmpty
              ? '${name ?? 'Запись'} · пока настройки как общие.'
              : '${name ?? 'Запись'} · своё: ${changed.join(', ')}.'
        ),
      _ => (
          'Меняете ${recordsLabel(selection)}',
          'Изменения применятся ко всем выбранным записям, общих не тронут.'
        ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
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
              const SizedBox(width: Gap.inner),
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.fileName),
              ),
            ],
          ),
          const SizedBox(height: Gap.hint),
          Text(
            hint,
            style: Type.caption.copyWith(
              color: Surface.secondaryText(context),
              height: 1.35,
            ),
          ),
          if (onReset != null) ...[
            const SizedBox(height: Gap.item),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onReset,
                  child: const Text('Вернуть общие'),
                ),
                const SizedBox(width: Gap.inner),
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
