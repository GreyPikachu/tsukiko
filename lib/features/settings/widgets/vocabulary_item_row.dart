import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/vocabulary.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Интерактивная строка элемента словаря с бейджем, переключателем активности
/// и поддержкой встроенного редактирования.
class VocabularyItemRow extends StatefulWidget {
  const VocabularyItemRow({
    super.key,
    required this.item,
    required this.onToggle,
    required this.onUpdate,
    required this.onDelete,
  });

  final VocabularyItem item;
  final ValueChanged<bool> onToggle;
  final ValueChanged<VocabularyItem> onUpdate;
  final VoidCallback onDelete;

  @override
  State<VocabularyItemRow> createState() => _VocabularyItemRowState();
}

class _VocabularyItemRowState extends State<VocabularyItemRow> {
  bool _hover = false;
  bool _deleteHover = false;
  bool _editing = false;

  late final TextEditingController _phraseCtrl;
  late final TextEditingController _replacementCtrl;
  late final FocusNode _phraseFocus;
  late final FocusNode _replacementFocus;

  @override
  void initState() {
    super.initState();
    _phraseCtrl = TextEditingController(text: widget.item.phrase);
    _replacementCtrl = TextEditingController(text: widget.item.replacement);
    _phraseFocus = FocusNode();
    _replacementFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant VocabularyItemRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.phrase != widget.item.phrase && !_editing) {
      _phraseCtrl.text = widget.item.phrase;
    }
    if (oldWidget.item.replacement != widget.item.replacement && !_editing) {
      _replacementCtrl.text = widget.item.replacement;
    }
  }

  @override
  void dispose() {
    _phraseCtrl.dispose();
    _replacementCtrl.dispose();
    _phraseFocus.dispose();
    _replacementFocus.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() {
      _editing = true;
      _phraseCtrl.text = widget.item.phrase;
      _replacementCtrl.text = widget.item.replacement;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _phraseFocus.requestFocus();
    });
  }

  void _saveEdit() {
    final phrase = _phraseCtrl.text.trim();
    if (phrase.isEmpty) return;
    widget.onUpdate(
      widget.item.copyWith(
        phrase: phrase,
        replacement: _replacementCtrl.text.trim(),
      ),
    );
    setState(() => _editing = false);
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _phraseCtrl.text = widget.item.phrase;
      _replacementCtrl.text = widget.item.replacement;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (_editing) {
      return _buildEditingRow(context, l10n);
    }

    return _buildDisplayRow(context, l10n);
  }

  Widget _buildDisplayRow(BuildContext context, AppLocalizations l10n) {
    final item = widget.item;
    final isHint = item.isHintOnly;
    final badgeColor = isHint
        ? MacosColors.systemBlueColor
        : MacosColors.systemGreenColor;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: Motion.dur(context, Motion.press),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.inner,
          vertical: Gap.inner,
        ),
        decoration: BoxDecoration(
          color: _hover ? Surface.hover(context) : MacosColors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            MacosTooltip(
              message: item.enabled
                  ? l10n.tooltipDisableItem
                  : l10n.tooltipEnableItem,
              child: MacosCheckbox(
                value: item.enabled,
                onChanged: (v) => widget.onToggle(v),
              ),
            ),
            const SizedBox(width: Gap.tight),
            MacosTooltip(
              message: item.isPriority
                  ? l10n.tooltipRemovePriority
                  : l10n.tooltipSetPriority,
              child: GestureDetector(
                onTap: () => widget.onUpdate(
                  item.copyWith(isPriority: !item.isPriority),
                ),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: MacosIcon(
                    item.isPriority
                        ? CupertinoIcons.star_fill
                        : CupertinoIcons.star,
                    size: 15,
                    color: item.isPriority
                        ? MacosColors.systemYellowColor
                        : Surface.secondaryText(context).withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Gap.hint),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _startEditing,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.phrase,
                        style: Type.control.copyWith(
                          fontWeight: FontWeight.w600,
                          color: item.enabled
                              ? null
                              : Surface.secondaryText(context),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.isReplacement) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.hint),
                        child: MacosIcon(
                          CupertinoIcons.arrow_right,
                          size: IconSize.inline,
                          color: Surface.secondaryText(context),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          item.replacement,
                          style: Type.control.copyWith(
                            color: item.enabled
                                ? null
                                : Surface.secondaryText(context),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: Gap.inner),
            // Бейдж типа
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.inner,
                vertical: Gap.tight,
              ),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: item.enabled ? 0.12 : 0.06),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isHint ? l10n.badgeHint : l10n.badgeReplacement,
                style: Type.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                  color: item.enabled
                      ? badgeColor
                      : Surface.secondaryText(context),
                ),
              ),
            ),
            const SizedBox(width: Gap.inner),
            // Действия: карандаш и корзина
            AnimatedOpacity(
              duration: Motion.dur(context, Motion.quick),
              opacity: _hover ? 1.0 : 0.0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MacosTooltip(
                    message: l10n.tooltipEditVocabulary,
                    child: MacosIconButton(
                      icon: MacosIcon(
                        CupertinoIcons.pencil,
                        size: IconSize.button,
                        color: Surface.secondaryText(context),
                      ),
                      boxConstraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      onPressed: _startEditing,
                    ),
                  ),
                  MouseRegion(
                    onEnter: (_) => setState(() => _deleteHover = true),
                    onExit: (_) => setState(() => _deleteHover = false),
                    child: MacosTooltip(
                      message: l10n.tooltipDeleteVocabulary,
                      child: MacosIconButton(
                        icon: MacosIcon(
                          CupertinoIcons.trash,
                          size: IconSize.button,
                          color: _deleteHover
                              ? MacosColors.systemRedColor
                              : Surface.secondaryText(context),
                        ),
                        boxConstraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        onPressed: widget.onDelete,
                      ),
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

  Widget _buildEditingRow(BuildContext context, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(Gap.inner),
      decoration: BoxDecoration(
        color: Surface.pressed(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: MacosTheme.of(context).primaryColor.withValues(alpha: 0.5),
        ),
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancelEdit,
          const SingleActivator(LogicalKeyboardKey.enter): _saveEdit,
        },
        child: Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: _phraseCtrl,
                placeholder: l10n.placeholderVocabularyPhrase,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.inner),
              child: MacosIcon(
                CupertinoIcons.arrow_right,
                size: IconSize.inline,
                color: Surface.secondaryText(context),
              ),
            ),
            Expanded(
              child: AppTextField(
                controller: _replacementCtrl,
                placeholder: l10n.placeholderVocabularyReplacement,
              ),
            ),
            const SizedBox(width: Gap.inner),
            MacosTooltip(
              message: l10n.buttonAssign,
              child: MacosIconButton(
                icon: const MacosIcon(
                  CupertinoIcons.checkmark_alt,
                  size: IconSize.button,
                  color: MacosColors.systemGreenColor,
                ),
                boxConstraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: _saveEdit,
              ),
            ),
            MacosTooltip(
              message: l10n.buttonCancelDownload,
              child: MacosIconButton(
                icon: MacosIcon(
                  CupertinoIcons.xmark,
                  size: IconSize.button,
                  color: Surface.secondaryText(context),
                ),
                boxConstraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: _cancelEdit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
