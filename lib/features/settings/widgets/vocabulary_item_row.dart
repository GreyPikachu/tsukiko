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
        duration: Motion.dur(context, Motion.quick),
        curve: Motion.curve(context, Motion.quickCurve),
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.inner,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: _hover
              ? Surface.pressed(context).withValues(alpha: 0.4)
              : MacosColors.transparent,
        ),
        child: Row(
          children: [
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
                          fontStyle:
                              item.enabled ? FontStyle.normal : FontStyle.italic,
                          color: item.enabled
                              ? null
                              : Surface.secondaryText(context)
                                  .withValues(alpha: 0.45),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.isReplacement) ...[
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: Gap.inner),
                        child: MacosIcon(
                          CupertinoIcons.arrow_right,
                          size: 11,
                          color: Surface.secondaryText(context).withValues(
                            alpha: item.enabled ? 0.5 : 0.3,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          item.replacement,
                          style: Type.control.copyWith(
                            fontStyle: item.enabled
                                ? FontStyle.normal
                                : FontStyle.italic,
                            color: item.enabled
                                ? null
                                : Surface.secondaryText(context)
                                    .withValues(alpha: 0.45),
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
            // Капсульный бейдж типа с микро-значком и оптическим трекингом
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.inner,
                vertical: 3.0,
              ),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: item.enabled ? 0.12 : 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      badgeColor.withValues(alpha: item.enabled ? 0.25 : 0.1),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MacosIcon(
                    isHint
                        ? CupertinoIcons.text_quote
                        : CupertinoIcons.arrow_2_squarepath,
                    size: 10,
                    color: item.enabled
                        ? badgeColor
                        : Surface.secondaryText(context).withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 3.5),
                  Text(
                    isHint ? l10n.badgeHint : l10n.badgeReplacement,
                    style: Type.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 10.5,
                      letterSpacing: 0.25,
                      color: item.enabled
                          ? badgeColor
                          : Surface.secondaryText(context).withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.inner),
            // Действия: переключение активности, карандаш и корзина
            // Оптически выровнены по весу со звёздочкой и текстом строки
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MacosTooltip(
                  message: item.enabled
                      ? l10n.tooltipDisableItem
                      : l10n.tooltipEnableItem,
                  child: AnimatedOpacity(
                    duration: Motion.dur(context, Motion.quick),
                    opacity: _hover ? 1.0 : (item.enabled ? 0.7 : 0.9),
                    child: MacosIconButton(
                      padding: const EdgeInsets.all(4),
                      icon: MacosIcon(
                        item.enabled
                            ? CupertinoIcons.checkmark_circle
                            : CupertinoIcons.pause_circle_fill,
                        size: IconSize.button,
                        color: item.enabled
                            ? MacosColors.systemGreenColor
                            : MacosColors.systemOrangeColor,
                      ),
                      boxConstraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      onPressed: () => widget.onToggle(!item.enabled),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  opacity: _hover ? 1.0 : 0.65,
                  child: MacosTooltip(
                    message: l10n.tooltipEditVocabulary,
                    child: MacosIconButton(
                      padding: const EdgeInsets.all(4),
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
                ),
                AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  opacity: _hover ? 1.0 : 0.65,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _deleteHover = true),
                    onExit: (_) => setState(() => _deleteHover = false),
                    child: MacosTooltip(
                      message: l10n.tooltipDeleteVocabulary,
                      child: MacosIconButton(
                        padding: const EdgeInsets.all(4),
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
                ),
              ],
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
