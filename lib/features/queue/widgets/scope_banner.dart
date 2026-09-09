import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/text.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';

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
    required this.onOpenSettings,
  });

  final int selection;
  final String? name;
  final List<String> changed;
  final VoidCallback? onReset, onMakeDefault;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = this.name ?? l10n.genericRecordName;
    // Первая строка отвечает на единственный вопрос, который здесь
    // возникает: то, что я сейчас трогаю, — общее или только этой записи?
    final (title, hint) = switch (selection) {
      0 => (l10n.scopeAllTitle, l10n.scopeAllHint),
      1 => (
          l10n.scopeOneTitle,
          changed.isEmpty
              ? l10n.scopeOneHintDefault(name)
              : l10n.scopeOneHintCustom(name, changed.join(', '))
        ),
      _ => (
          l10n.scopeManyTitle(recordsLabel(selection)),
          l10n.scopeManyHint
        ),
    };

    return Container(
      // Плашка стоит в колонке сама по себе, и поле у неё в ступень
      // «между настройками»: у мелких вставок внутри строки поле
      // [Gap.inner], у самостоятельных — [Gap.item].
      padding: const EdgeInsets.all(Gap.item),
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
                size: IconSize.inline,
                color: Surface.secondaryText(context),
              ),
              const SizedBox(width: Gap.inner),
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.fileName),
              ),
              const SizedBox(width: Gap.inner),
              MacosTooltip(
                message: l10n.buttonTranscriptionSettingsEllipsis('').trim(),
                child: MacosIconButton(
                  icon: const MacosIcon(
                    CupertinoIcons.gear,
                    size: IconSize.button,
                  ),
                  boxConstraints: const BoxConstraints.tightFor(
                    width: IconSize.button + Gap.control,
                    height: IconSize.button + Gap.control,
                  ),
                  onPressed: onOpenSettings,
                ),
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
                  child: Text(l10n.buttonRestoreDefaults),
                ),
                const SizedBox(width: Gap.inner),
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onMakeDefault,
                  child: Text(l10n.buttonMakeDefault),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
