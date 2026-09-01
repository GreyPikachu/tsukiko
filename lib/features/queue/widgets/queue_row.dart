import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/whisper.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../job.dart';

/// Строка очереди и значок её состояния.
class QueueRow extends StatefulWidget {
  const QueueRow({
    super.key,
    required this.job,
    required this.selected,
    required this.lead,
    required this.customised,
    required this.onTap,
  });
  final Job job;
  final bool selected, lead, customised;
  final VoidCallback onTap;

  @override
  State<QueueRow> createState() => QueueRowState();
}

class QueueRowState extends State<QueueRow> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final accent = MacosTheme.of(context).primaryColor;
    // Выделено несколько — ведущая запись (её показывает инспектор) плотнее.
    final bg = widget.selected
        ? (widget.lead ? accent : accent.withValues(alpha: 0.75))
        : _down
            ? Surface.pressed(context)
            : _hover
                ? Surface.hover(context)
                : MacosColors.transparent;
    final fg = widget.selected ? MacosColors.white : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Подсветка на нажатии, не на отпускании.
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StateGlyph(job: job, tint: fg),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.fileName.copyWith(color: fg),
                    ),
                  ),
                  // Отметка «у этой записи свои настройки» — иначе о них
                  // узнаёшь только открыв инспектор.
                  if (widget.customised)
                    MacosTooltip(
                      message: AppLocalizations.of(context).tooltipCustomSettings,
                      child: MacosIcon(
                        CupertinoIcons.slider_horizontal_3,
                        size: 12,
                        color: fg ?? Surface.secondaryText(context),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 1),
                child: Text(
                  job.detail ?? job.state.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.caption.copyWith(
                    color: fg?.withValues(alpha: 0.75) ?? Surface.secondaryText(context),
                  ),
                ),
              ),
              // Прогресс живёт рядом со своим файлом, а не в общей строке снизу.
              if (job.active)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 6, right: 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: (fg ?? accent).withValues(alpha: 0.22),
                            ),
                          ),
                          AnimatedFractionallySizedBox(
                            duration: Motion.dur(context, Motion.settle),
                            curve: Motion.curve(context, Motion.settleCurve),
                            widthFactor: job.progress.clamp(0.02, 1),
                            child: ColoredBox(color: fg ?? accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class StateGlyph extends StatelessWidget {
  const StateGlyph({
    super.key,required this.job, this.tint});
  final Job job;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (job.state) {
      JobState.done => (CupertinoIcons.checkmark_circle_fill, MacosColors.systemGreenColor),
      JobState.failed => (
          CupertinoIcons.exclamationmark_circle_fill,
          MacosColors.systemRedColor
        ),
      JobState.cancelled => (CupertinoIcons.minus_circle, Surface.secondaryText(context)),
      JobState.waiting => (CupertinoIcons.clock, MacosColors.systemOrangeColor),
      JobState.paused => (
          CupertinoIcons.pause_circle_fill,
          MacosColors.systemOrangeColor
        ),
      JobState.converting || JobState.transcribing => (
          CupertinoIcons.waveform_circle_fill,
          MacosTheme.of(context).primaryColor
        ),
      JobState.queued => (CupertinoIcons.circle, Surface.secondaryText(context)),
    };
    return AnimatedSwitcher(
      duration: Motion.dur(context, Motion.quick),
      switchInCurve: Motion.curve(context, Motion.quickCurve),
      child: MacosIcon(icon, key: ValueKey(icon.codePoint), size: 15, color: tint ?? color),
    );
  }
}

/// Фрагмент: появляется снизу вверх — оттуда же, откуда его выдаёт модель.
