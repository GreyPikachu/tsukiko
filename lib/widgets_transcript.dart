part of 'main.dart';

/// Фрагмент расшифровки и полог, который встречает перетаскиваемый файл.
class _SegmentRow extends StatefulWidget {
  const _SegmentRow({
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
  State<_SegmentRow> createState() => _SegmentRowState();
}

class _SegmentRowState extends State<_SegmentRow> with SingleTickerProviderStateMixin {
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
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
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
                  padding: const EdgeInsets.only(right: 14, top: 2),
                  child: Text(
                    fmtTs(widget.segment.from).substring(0, 8),
                    style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                  ),
                ),
              Expanded(child: SelectableText.rich(_spans(context))),
              SizedBox(
                width: 26,
                height: 22,
                child: AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  opacity: _hover || _copied ? 1 : 0,
                  child: MacosIconButton(
                    icon: MacosIcon(
                      _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
                      size: 13,
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
class _DropVeil extends StatelessWidget {
  const _DropVeil({required this.active});
  final bool active;

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
            margin: const EdgeInsets.fromLTRB(14, 14, 14, 54),
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
                  const Mascot(
                    mood: Mood.surprised,
                    height: 116,
                    interactive: false,
                  ),
                  const SizedBox(height: 8),
                  Text('Отпустите — добавим в очередь',
                      style: Type.emptyTitle.copyWith(color: accent)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
