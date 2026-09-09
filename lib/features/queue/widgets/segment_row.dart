import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/transcript.dart';
import '../../../design/design.dart';
import '../../../design/mascot.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Фрагмент расшифровки и полог, который встречает перетаскиваемый файл.
class SegmentRow extends StatefulWidget {
  const SegmentRow({
    super.key,
    required this.segment,
    required this.showTimestamp,
    required this.onCopied,
    this.highlight = '',
  });
  final Segment segment;
  final bool showTimestamp;
  final VoidCallback onCopied;
  final String highlight;

  @override
  State<SegmentRow> createState() => SegmentRowState();
}

class SegmentRowState extends State<SegmentRow> with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Motion.settle,
  )..forward();
  bool _hover = false, _copied = false;
  Timer? _resetCopied;

  @override
  void dispose() {
    _resetCopied?.cancel();
    _enter.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.segment.text));
    setState(() => _copied = true);
    widget.onCopied();
    _resetCopied?.cancel();
    _resetCopied = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Найденное подсвечивается прямо в тексте — искать глазами по строке,
  /// которую только что нашёл поиск, было бы издевательством.
  TextSpan _spans(BuildContext context) {
    final text = widget.segment.text;
    final needle = widget.highlight;
    if (needle.isEmpty) return TextSpan(text: text, style: Type.body);

    final accent = MacosTheme.of(context).primaryColor;
    final spans = <TextSpan>[];
    final lower = text.toLowerCase(), q = needle.toLowerCase();
    var at = 0;
    while (true) {
      final hit = lower.indexOf(q, at);
      if (hit < 0) break;
      if (hit > at) spans.add(TextSpan(text: text.substring(at, hit)));
      spans.add(TextSpan(
        text: text.substring(hit, hit + q.length),
        style: TextStyle(backgroundColor: accent.withValues(alpha: 0.28)),
      ));
      at = hit + q.length;
    }
    spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: Type.body, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Motion.curve(context, Motion.settleCurve),
    );
    final slide = Motion.slide(context, 10);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Opacity(
          opacity: curve.value.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, slide * (1 - curve.value)),
            child: child,
          ),
        ),
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.quick),
          curve: Motion.curve(context, Motion.quickCurve),
          margin: const EdgeInsets.only(bottom: Gap.tight),
          padding: const EdgeInsets.all(Gap.inner),
          decoration: BoxDecoration(
            color: _copied
                ? MacosTheme.of(context).primaryColor.withValues(alpha: 0.14)
                : _hover
                    ? Surface.hover(context)
                    : MacosColors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showTimestamp)
                Padding(
                  // Время — отдельный столбец слева, и до текста от него
                  // ступень «между кнопками»: на восьми точках столбец
                  // прилипал к первому слову и переставал читаться числом.
                  padding: const EdgeInsets.only(
                      right: Gap.control, top: Gap.tight),
                  child: Text(
                    fmtTs(widget.segment.from).substring(0, 8),
                    style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                  ),
                ),
              Expanded(child: SelectableText.rich(_spans(context))),
              // Копирование — самостоятельная цель нажатия, а не отметка
              // при тексте: значок кнопочной ступени, и коробка вокруг
              // него шире значка на [Gap.inner], чтобы в неё попадали.
              // Раньше тут стоял значок в тринадцать точек — мельче
              // соседнего времени записи, и найти его глазом было нечем.
              SizedBox(
                width: IconSize.toolbar + Gap.inner,
                height: IconSize.toolbar + Gap.inner,
                child: AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  opacity: _hover || _copied ? 1 : 0,
                  child: MacosIconButton(
                    icon: MacosIcon(
                      _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
                      size: IconSize.toolbar,
                      color: _copied ? MacosTheme.of(context).primaryColor : null,
                    ),
                    onPressed: _hover || _copied ? _copy : null,
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

/// Полог при перетаскивании: материал приходит с лёгким перелётом —
/// жест уже нёс импульс.
class DropVeil extends StatelessWidget {
  const DropVeil({
    super.key,required this.active, this.compact = false});
  final bool active;

  /// Узкая колонка очереди: коту в ней не поместиться, и он там не нужен —
  /// подсветки края и подписи хватает, чтобы понять, что файл здесь примут.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: Motion.dur(context, Motion.toss),
        curve: Motion.curve(context, Motion.tossCurve),
        opacity: active ? 1 : 0,
        child: AnimatedScale(
          duration: Motion.dur(context, Motion.toss),
          curve: Motion.curve(context, Motion.tossCurve),
          scale: active ? 1 : 0.97,
          child: Container(
            margin: compact
                ? const EdgeInsets.all(Gap.inner)
                // Снизу вчетверо больше, чем с боков: там лежит нижняя
                // полоса окна, и вуаль не должна залезать под неё.
                : const EdgeInsets.fromLTRB(
                    Gap.item, Gap.item, Gap.item, Gap.item * 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.5),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Кот тянется навстречу файлу. Тыкать в него сейчас нельзя —
                  // вуаль и так перехватывает всё под собой.
                  if (!compact) ...[
                    const Mascot(
                      mood: Mood.surprised,
                      height: 116,
                      interactive: false,
                    ),
                    const SizedBox(height: Gap.inner),
                  ],
                  Text(
                    AppLocalizations.of(context).dropVeilHint,
                    textAlign: TextAlign.center,
                    style: (compact ? Type.caption : Type.emptyTitle)
                        .copyWith(color: accent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
