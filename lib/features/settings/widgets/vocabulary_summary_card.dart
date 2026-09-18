import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';

enum VocabularyScope {
  dictation,
  transcriber,
}

/// Компактная карточка сводки словаря для вкладок «Диктовка» и «Расшифровщик».
///
/// Показывает число активных записей (подсказок и замен), выключатель для
/// данного режима и переход на 5-ю вкладку «Словарь».
class VocabularySummaryCard extends StatelessWidget {
  const VocabularySummaryCard({
    super.key,
    required this.scope,
    required this.totalCount,
    required this.hintCount,
    required this.replacementCount,
    required this.enabled,
    required this.onEnabledChanged,
    required this.onConfigure,
  });

  final VocabularyScope scope;
  final int totalCount;
  final int hintCount;
  final int replacementCount;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDictation = scope == VocabularyScope.dictation;

    return Container(
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: Surface.hover(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Surface.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MacosIcon(
                CupertinoIcons.book,
                size: IconSize.toolbar,
                color: MacosTheme.of(context).primaryColor,
              ),
              const SizedBox(width: Gap.inner),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.vocabularySummaryTitle,
                      style: Type.control.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Gap.tight),
                    Text(
                      l10n.vocabularySummaryStatus(
                        totalCount,
                        hintCount,
                        replacementCount,
                      ),
                      style: Type.caption.copyWith(
                        color: Surface.secondaryText(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.inner),
          Text(
            l10n.hintVocabularyScope,
            style: Type.caption.copyWith(
              color: Surface.secondaryText(context),
              height: 1.35,
            ),
          ),
          const SizedBox(height: Gap.item),
          Row(
            children: [
              Expanded(
                child: Check(
                  isDictation
                      ? l10n.checkVocabularyDictation
                      : l10n.checkVocabularyTranscriber,
                  enabled,
                  onEnabledChanged,
                ),
              ),
              const SizedBox(width: Gap.control),
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: onConfigure,
                child: Text(l10n.buttonConfigureVocabulary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
