import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../design/design.dart';

/// Одна установленная модель: чем она является, где лежит, сколько весит
/// и что с ней можно сделать.
///
/// Раньше здесь были только имя, путь и размер — без единой кнопки.
/// Скачав три гигабайта и передумав, вернуть их было можно только руками
/// через проводник, зная, куда смотреть.
class ModelRow extends StatefulWidget {
  const ModelRow({
    super.key,
    required this.name,
    required this.path,
    required this.size,
    required this.problem,
    required this.chosen,
    required this.onReveal,
    required this.onDelete,
  });

  final String name, path, size;

  /// Почему файл не годится в модель. Пусто — годится.
  final String? problem;

  /// Эта модель сейчас выбрана для диктовки.
  final bool chosen;

  final VoidCallback onReveal, onDelete;

  @override
  State<ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<ModelRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final grey = Type.caption.copyWith(color: Surface.secondaryText(context));
    final broken = widget.problem != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: Motion.dur(context, Motion.press),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
        decoration: BoxDecoration(
          color: _hover ? Surface.hover(context) : MacosColors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Type.fileName,
                        ),
                      ),
                      // Выбранную помечаем: одинаковых имён в списке
                      // может быть несколько, и какая из них в деле —
                      // иначе не видно.
                      if (widget.chosen) ...[
                        const SizedBox(width: 6),
                        Text('· выбрана', style: grey),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  // Путь показываем всегда: две модели с одинаковым именем
                  // различает только он.
                  Text(
                    widget.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: grey,
                  ),
                  if (broken) ...[
                    const SizedBox(height: Gap.hint),
                    // Битую модель показывать наравне с рабочей нельзя:
                    // узнавалось это только при запуске распознавания,
                    // руганью whisper про тензоры.
                    Text(
                      widget.problem!,
                      style: Type.caption.copyWith(
                        color: MacosColors.systemOrangeColor,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (widget.size.isNotEmpty) Text(widget.size, style: grey),
            const SizedBox(width: 4),
            // Кнопки появляются под курсором: в спокойном списке они
            // только шумят, а удаление рядом с каждой строкой ещё и пугает.
            AnimatedOpacity(
              duration: Motion.dur(context, Motion.quick),
              opacity: _hover ? 1 : 0,
              child: Row(
                children: [
                  MacosTooltip(
                    message: 'Показать файл',
                    child: MacosIconButton(
                      icon: const MacosIcon(CupertinoIcons.folder, size: 14),
                      onPressed: _hover ? widget.onReveal : null,
                    ),
                  ),
                  MacosTooltip(
                    message: 'Убрать в Корзину',
                    child: MacosIconButton(
                      icon: const MacosIcon(CupertinoIcons.trash, size: 14),
                      onPressed: _hover ? widget.onDelete : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
