import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/features/queue/prompt_section.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

void main() {
  group('helpers', () {
    test('parsePromptTerms извлекает уникальные слова без дубликатов', () {
      final terms = parsePromptTerms('Flutter, Dart, виджет, flutter, NeMo');
      expect(terms, ['Flutter', 'Dart', 'виджет', 'NeMo']);
    });

    test('removeTermFromPrompt удаляет конкретное слово', () {
      final updated = removeTermFromPrompt('Flutter, тсукико, Dart', 'тсукико');
      expect(updated, 'Flutter, Dart');
    });

    test('estimatePromptTokens оценивает количество токенов', () {
      expect(estimatePromptTokens(''), 0);
      expect(estimatePromptTokens('Flutter'), greaterThan(0));
    });
  });

  Widget wrapWithMacosApp(Widget child) => MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MacosScaffold(
          children: [
            ContentArea(builder: (_, _) => child),
          ],
        ),
      );

  Finder findMacosIcon(IconData icon) => find.byWidgetPredicate(
        (widget) => widget is MacosIcon && widget.icon == icon,
      );

  group('ModelPromptSection', () {
    testWidgets('отображает количество слов и токенов', (tester) async {
      await tester.pumpWidget(
        wrapWithMacosApp(
          ModelPromptSection(
            prompt: 'Flutter, Dart, виджет',
            onOpenVocabularySettings: () {},
            onAddPromptWord: (_) {},
            onAddReplacement: ({
              required String phrase,
              required String replacement,
              bool removeFromPrompt = false,
            }) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Общий словарь…'), findsOneWidget);
      expect(find.textContaining('3 слова'), findsOneWidget);
      expect(find.textContaining('ток.'), findsOneWidget);
    });

    testWidgets('нажатие на карточку вызывает onOpenVocabularySettings',
        (tester) async {
      var opened = false;
      await tester.pumpWidget(
        wrapWithMacosApp(
          ModelPromptSection(
            prompt: 'TypeScript',
            onOpenVocabularySettings: () => opened = true,
            onAddPromptWord: (_) {},
            onAddReplacement: ({
              required String phrase,
              required String replacement,
              bool removeFromPrompt = false,
            }) {},
          ),
        ),
      );

      await tester.tap(find.text('Общий словарь…'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });

    testWidgets('быстрое добавление слова в подсказку', (tester) async {
      String? addedWord;
      await tester.pumpWidget(
        wrapWithMacosApp(
          ModelPromptSection(
            prompt: '',
            onOpenVocabularySettings: () {},
            onAddPromptWord: (w) => addedWord = w,
            onAddReplacement: ({
              required String phrase,
              required String replacement,
              bool removeFromPrompt = false,
            }) {},
          ),
        ),
      );

      await tester.enterText(find.byType(MacosTextField).first, 'KubeJS');
      await tester.tap(findMacosIcon(CupertinoIcons.plus_circle_fill));
      await tester.pump();

      expect(addedWord, 'KubeJS');
    });

    testWidgets('переключение в режим замены и сохранение автозамены',
        (tester) async {
      String? savedPhrase;
      String? savedReplacement;
      bool? removedFromPrompt;

      await tester.pumpWidget(
        wrapWithMacosApp(
          ModelPromptSection(
            prompt: 'тсукико',
            onOpenVocabularySettings: () {},
            onAddPromptWord: (_) {},
            onAddReplacement: ({
              required String phrase,
              required String replacement,
              bool removeFromPrompt = false,
            }) {
              savedPhrase = phrase;
              savedReplacement = replacement;
              removedFromPrompt = removeFromPrompt;
            },
          ),
        ),
      );

      // Включаем режим замены
      await tester.tap(findMacosIcon(CupertinoIcons.arrow_right_arrow_left));
      await tester.pumpAndSettle();

      // Теперь должно быть 2 текстовых поля
      expect(find.byType(MacosTextField), findsNWidgets(2));

      await tester.enterText(find.byType(MacosTextField).first, 'тсукико');
      await tester.enterText(find.byType(MacosTextField).last, 'Tsukiko');

      await tester.tap(findMacosIcon(CupertinoIcons.checkmark_circle_fill));
      await tester.pump();

      expect(savedPhrase, 'тсукико');
      expect(savedReplacement, 'Tsukiko');
      expect(removedFromPrompt, isTrue);
    });
  });
}
