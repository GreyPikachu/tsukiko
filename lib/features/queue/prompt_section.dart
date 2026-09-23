import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';

/// Извлекает список уникальных слов/терминов из строки подсказки модели.
List<String> parsePromptTerms(String prompt) {
  if (prompt.trim().isEmpty) return const [];
  final raw = prompt.split(RegExp(r'[,;\n]+'));
  final seen = <String>{};
  final result = <String>[];
  for (final item in raw) {
    final trimmed = item.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
      result.add(trimmed);
    }
  }
  return result;
}

/// Удаляет конкретное слово/фразу из запятой-разделённой строки подсказки.
String removeTermFromPrompt(String prompt, String term) {
  final lowerTerm = term.trim().toLowerCase();
  final terms = prompt.split(RegExp(r',\s*'));
  final kept = terms.where((t) => t.trim().toLowerCase() != lowerTerm);
  return kept.join(', ').trim();
}

/// Оценка токенов подсказки для окна Whisper (контекст до 220 токенов).
int estimatePromptTokens(String prompt) {
  final trimmed = prompt.trim();
  if (trimmed.isEmpty) return 0;
  return (trimmed.length / 3.8).ceil();
}

/// Компактная секция подсказки модели и словаря в инспекторе очереди:
/// небольшая кнопка для быстрого перехода в настройки словаря
/// и форма быстрой записи слов с возможностью сразу сделать из них автозамену.
class ModelPromptSection extends StatefulWidget {
  const ModelPromptSection({
    super.key,
    required this.prompt,
    this.vocabularyCount,
    required this.onOpenVocabularySettings,
    required this.onAddPromptWord,
    required this.onAddReplacement,
  });

  final String prompt;
  final int? vocabularyCount;
  final VoidCallback onOpenVocabularySettings;
  final ValueChanged<String> onAddPromptWord;
  final void Function({
    required String phrase,
    required String replacement,
    bool removeFromPrompt,
  })
  onAddReplacement;

  @override
  State<ModelPromptSection> createState() => _ModelPromptSectionState();
}

class _ModelPromptSectionState extends State<ModelPromptSection> {
  final _phraseCtrl = TextEditingController();
  final _replacementCtrl = TextEditingController();
  final _phraseFocus = FocusNode();
  final _replacementFocus = FocusNode();

  bool _replacementMode = false;
  bool _cardHovered = false;

  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void dispose() {
    _phraseCtrl.dispose();
    _replacementCtrl.dispose();
    _phraseFocus.dispose();
    _replacementFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final phrase = _phraseCtrl.text.trim();
    if (phrase.isEmpty) return;

    if (_replacementMode) {
      final rep = _replacementCtrl.text.trim();
      if (rep.isEmpty) {
        _replacementFocus.requestFocus();
        return;
      }
      widget.onAddReplacement(
        phrase: phrase,
        replacement: rep,
        removeFromPrompt: true,
      );
      _phraseCtrl.clear();
      _replacementCtrl.clear();
      HapticFeedback.lightImpact();
      _phraseFocus.requestFocus();
    } else {
      widget.onAddPromptWord(phrase);
      _phraseCtrl.clear();
      HapticFeedback.lightImpact();
      _phraseFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final count =
        widget.vocabularyCount ?? parsePromptTerms(widget.prompt).length;
    final tokens = estimatePromptTokens(widget.prompt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(l10n.fieldModelPrompt),
        _buildPromptCard(context, count, tokens),
        const SizedBox(height: Gap.inner),
        _buildQuickEntryRow(context),
        if (_replacementMode) ...[
          const SizedBox(height: Gap.hint),
          _buildReplacementInputRow(context),
        ],
        const SizedBox(height: Gap.hint),
        Hint(
          _replacementMode ? l10n.hintVocabularyScope : l10n.hintPromptHelps,
        ),
      ],
    );
  }

  Widget _buildPromptCard(BuildContext context, int count, int tokens) {
    final primary = MacosTheme.of(context).primaryColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _cardHovered = true),
      onExit: (_) => setState(() => _cardHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onOpenVocabularySettings,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.quick),
          curve: Motion.curve(context, Motion.quickCurve),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.inner,
            vertical: Gap.inner,
          ),
          decoration: BoxDecoration(
            color: _cardHovered
                ? Surface.hover(context)
                : (Surface.isDark(context)
                      ? const Color(0x0FFFFFFF)
                      : const Color(0x08000000)),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _cardHovered
                  ? primary.withValues(alpha: 0.4)
                  : Surface.hairline(context),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: MacosIcon(
                  CupertinoIcons.text_quote,
                  size: 15,
                  color: primary,
                ),
              ),
              const SizedBox(width: Gap.inner),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.buttonEditPrompt,
                      style: Type.control.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      count == 0
                          ? l10n.buttonEditPromptSubtitle(0)
                          : '${l10n.buttonEditPromptSubtitle(count)} · ~$tokens ток.',
                      style: Type.caption.copyWith(
                        color: Surface.secondaryText(context),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              MacosIcon(
                CupertinoIcons.chevron_right,
                size: 13,
                color: Surface.secondaryText(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickEntryRow(BuildContext context) {
    final primary = MacosTheme.of(context).primaryColor;
    return Row(
      children: [
        Expanded(
          child: MacosTextField(
            controller: _phraseCtrl,
            focusNode: _phraseFocus,
            placeholder: l10n.placeholderQuickAddPhrase,
            placeholderStyle: Surface.placeholder(context),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: Gap.hint),
        MacosTooltip(
          message: l10n.tooltipMakeReplacement,
          child: MacosIconButton(
            icon: MacosIcon(
              CupertinoIcons.arrow_right_arrow_left,
              size: 14,
              color: _replacementMode
                  ? primary
                  : Surface.secondaryText(context),
            ),
            onPressed: () {
              setState(() => _replacementMode = !_replacementMode);
              if (_replacementMode) {
                _replacementFocus.requestFocus();
              }
            },
          ),
        ),
        const SizedBox(width: Gap.tight),
        MacosTooltip(
          message: _replacementMode
              ? l10n.buttonSaveReplacement
              : l10n.buttonQuickAddPromptWord,
          child: MacosIconButton(
            icon: MacosIcon(
              _replacementMode
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.plus_circle_fill,
              size: 18,
              color: primary,
            ),
            onPressed: _submit,
          ),
        ),
      ],
    );
  }

  Widget _buildReplacementInputRow(BuildContext context) {
    return AnimatedSize(
      duration: Motion.dur(context, Motion.settle),
      curve: Motion.curve(context, Motion.settleCurve),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: MacosIcon(
              CupertinoIcons.arrow_turn_down_right,
              size: 12,
              color: MacosTheme.of(context).primaryColor,
            ),
          ),
          Expanded(
            child: MacosTextField(
              controller: _replacementCtrl,
              focusNode: _replacementFocus,
              placeholder: l10n.placeholderQuickAddReplacement,
              placeholderStyle: Surface.placeholder(context),
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
      ),
    );
  }
}
