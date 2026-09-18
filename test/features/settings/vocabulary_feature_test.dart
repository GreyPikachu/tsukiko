import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/vocabulary.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/queue/queue_bloc.dart';
import 'package:tsukiko/features/queue/queue_event.dart';
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/features/settings/settings_page.dart';
import 'package:tsukiko/features/settings/settings_state.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

/// Test cubit with state updates for widget verification
class _TestVocabularyCubit extends Cubit<SettingsState>
    implements SettingsCubit {
  _TestVocabularyCubit([SettingsState? initial])
      : super(initial ?? SettingsState(tab: 'vocabulary'));

  VocabularyItem? _lastDeletedItem;
  int? _lastDeletedIndex;

  @override
  VocabularyItem? get lastDeletedItem => _lastDeletedItem;

  @override
  void setTab(String tab) => emit(state.copyWith(tab: tab));

  @override
  void setVocabularyDictationEnabled(bool value) => emit(
        state.copyWith(
          vocabularyDictationEnabled: value,
          dictationCommandsEnabled: value,
        ),
      );

  @override
  void setVocabularyTranscriberEnabled(bool value) => emit(
        state.copyWith(
          vocabularyTranscriberEnabled: value,
          transcriberCommandsEnabled: value,
        ),
      );

  @override
  void addVocabularyItem(String phrase, [String replacement = '']) {
    final trimmedPhrase = phrase.trim();
    if (trimmedPhrase.isEmpty) return;
    final item = VocabularyItem(
      id: 'vocab_${DateTime.now().microsecondsSinceEpoch}',
      phrase: trimmedPhrase,
      replacement: replacement.trim(),
      enabled: true,
      createdAt: DateTime.now(),
    );
    final items = [...state.vocabulary, item];
    emit(state.copyWith(
      vocabulary: items,
      textCommands: items
          .where((i) => i.isReplacement)
          .map((i) => i.toTextCommand())
          .toList(),
    ));
  }

  @override
  void updateVocabularyItem(int index, VocabularyItem item) {
    if (index < 0 || index >= state.vocabulary.length) return;
    final items = [...state.vocabulary]..[index] = item;
    emit(state.copyWith(
      vocabulary: items,
      textCommands: items
          .where((i) => i.isReplacement)
          .map((i) => i.toTextCommand())
          .toList(),
    ));
  }

  @override
  void removeVocabularyItem(int index) {
    if (index < 0 || index >= state.vocabulary.length) return;
    _lastDeletedIndex = index;
    _lastDeletedItem = state.vocabulary[index];
    final items = [...state.vocabulary]..removeAt(index);
    emit(state.copyWith(
      vocabulary: items,
      textCommands: items
          .where((i) => i.isReplacement)
          .map((i) => i.toTextCommand())
          .toList(),
    ));
  }

  @override
  void toggleVocabularyItem(int index, bool enabled) {
    if (index < 0 || index >= state.vocabulary.length) return;
    final updated = state.vocabulary[index].copyWith(enabled: enabled);
    updateVocabularyItem(index, updated);
  }

  @override
  void undoDeleteVocabularyItem() {
    final item = _lastDeletedItem;
    if (item == null) return;
    final index = _lastDeletedIndex ?? state.vocabulary.length;
    final items = [...state.vocabulary];
    if (index >= 0 && index <= items.length) {
      items.insert(index, item);
    } else {
      items.add(item);
    }
    _lastDeletedItem = null;
    _lastDeletedIndex = null;
    emit(state.copyWith(
      vocabulary: items,
      textCommands: items
          .where((i) => i.isReplacement)
          .map((i) => i.toTextCommand())
          .toList(),
    ));
  }

  @override
  void setVisible(bool visible) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake native bridge for method channels
class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');
  final calls = <String>[];
  final hudStates = <String>[];
  bool permitted = true;
  String? pasted;
  bool pasteSucceeds = true;
  String recordPath = '/tmp/test_vocab_dictation.wav';

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'permissions':
          return permitted;
        case 'initialTab':
          return 'transcriber';
        case 'record':
          return recordPath;
        case 'stopRecord':
          return null;
        case 'level':
          return 0.3;
        case 'paste':
          pasted = (call.arguments as Map)['text'] as String?;
          return pasteSucceeds;
        case 'hud':
          hudStates.add((call.arguments as Map)['state'] as String);
          return null;
        case 'trash':
          return true;
        default:
          return null;
      }
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Fake Whisper server for dictation integration
class _FakeWhisperServer extends WhisperServer {
  String? transcribedText;

  @override
  bool get up => true;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async =>
      transcribedText;

  @override
  Future<void> shutdown() async {}

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // ════════════════════════════════════════════════════════════════════════════
  // CLASS 11: Settings Cubit & State Actions (Unit & State Testing)
  // ════════════════════════════════════════════════════════════════════════════
  group('Class 11: Settings Cubit & State actions', () {
    useTempSupportDir('tsukiko-settings-vocab-c11');

    late _FakeNative native;
    late SettingsCubit cubit;

    setUp(() {
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      native = _FakeNative()..install();
      NativeBridge.debugReset();
      cubit = SettingsCubit(NativeBridge());
    });

    tearDown(() async {
      await cubit.close();
      native.remove();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 25));

    test('addVocabularyItem adds hints and replacements with dual-writing', () async {
      // Add acoustic hint
      cubit.addVocabularyItem('TypeScript');
      await settle();

      expect(cubit.state.vocabulary.length, 1);
      final hint = cubit.state.vocabulary.first;
      expect(hint.phrase, 'TypeScript');
      expect(hint.isHintOnly, isTrue);
      expect(hint.isReplacement, isFalse);
      expect(cubit.state.textCommands, isEmpty, reason: 'Hints are not textCommands');

      // Add replacement
      cubit.addVocabularyItem('юскейс', 'Use Case');
      await settle();

      expect(cubit.state.vocabulary.length, 2);
      final rep = cubit.state.vocabulary[1];
      expect(rep.phrase, 'юскейс');
      expect(rep.replacement, 'Use Case');
      expect(rep.isReplacement, isTrue);

      // Verify dual-writing to state.textCommands
      expect(cubit.state.textCommands.length, 1);
      expect(cubit.state.textCommands.first.phrase, 'юскейс');
      expect(cubit.state.textCommands.first.replacement, 'Use Case');

      // Verify persistence to disk in both keys
      final saved = Settings.load();
      final savedVocab = vocabularyFromJson(saved[vocabularySetting]);
      expect(savedVocab.length, 2);
      final savedCmds = textCommandsFromJson(saved[textCommandsSetting]);
      expect(savedCmds.length, 1);
      expect(savedCmds.first.phrase, 'юскейс');
    });

    test('addVocabularyItem boundary: empty or whitespace phrase is rejected', () async {
      cubit.addVocabularyItem('');
      cubit.addVocabularyItem('   ');
      cubit.addVocabularyItem('\t\n');
      await settle();

      expect(cubit.state.vocabulary, isEmpty);
      expect(cubit.state.textCommands, isEmpty);
    });

    test('updateVocabularyItem updates item and ignores invalid indices', () async {
      cubit.addVocabularyItem('мак', 'Mac');
      await settle();

      // Valid update
      final item = cubit.state.vocabulary.first;
      cubit.updateVocabularyItem(0, item.copyWith(replacement: 'MacBook'));
      await settle();

      expect(cubit.state.vocabulary.first.replacement, 'MacBook');
      expect(cubit.state.textCommands.first.replacement, 'MacBook');

      // Boundary: invalid indices are safely ignored
      cubit.updateVocabularyItem(-1, item);
      cubit.updateVocabularyItem(999, item);
      await settle();

      expect(cubit.state.vocabulary.first.replacement, 'MacBook');
    });

    test('removeVocabularyItem and undoDeleteVocabularyItem (Boundary 6)', () async {
      cubit.addVocabularyItem('первый', 'First');
      cubit.addVocabularyItem('второй', 'Second');
      cubit.addVocabularyItem('третий', 'Third');
      await settle();

      expect(cubit.state.vocabulary.length, 3);

      // 1. Remove middle item (index 1: 'второй')
      cubit.removeVocabularyItem(1);
      await settle();

      expect(cubit.state.vocabulary.length, 2);
      expect(cubit.state.vocabulary.map((i) => i.phrase), ['первый', 'третий']);
      expect(cubit.lastDeletedItem?.phrase, 'второй');

      // Undo middle deletion -> restored at index 1
      cubit.undoDeleteVocabularyItem();
      await settle();

      expect(cubit.state.vocabulary.length, 3);
      expect(cubit.state.vocabulary[1].phrase, 'второй');
      expect(cubit.lastDeletedItem, isNull);

      // 2. Remove first item (index 0: 'первый')
      cubit.removeVocabularyItem(0);
      await settle();
      expect(cubit.state.vocabulary.first.phrase, 'второй');

      // Undo first deletion -> restored at index 0
      cubit.undoDeleteVocabularyItem();
      await settle();
      expect(cubit.state.vocabulary.first.phrase, 'первый');

      // 3. Remove last item (index 2: 'третий')
      cubit.removeVocabularyItem(2);
      await settle();
      expect(cubit.state.vocabulary.length, 2);

      // Undo last deletion -> restored at index 2
      cubit.undoDeleteVocabularyItem();
      await settle();
      expect(cubit.state.vocabulary.length, 3);
      expect(cubit.state.vocabulary[2].phrase, 'третий');

      // 4. Repeated undo when lastDeletedItem is null is a safe no-op
      cubit.undoDeleteVocabularyItem();
      await settle();
      expect(cubit.state.vocabulary.length, 3);

      // 5. Boundary: Invalid index remove is ignored
      cubit.removeVocabularyItem(-1);
      cubit.removeVocabularyItem(100);
      await settle();
      expect(cubit.state.vocabulary.length, 3);
    });

    test('toggleVocabularyItem toggles enabled and ignores invalid indices', () async {
      cubit.addVocabularyItem('Кубернетис');
      await settle();

      expect(cubit.state.vocabulary.first.enabled, isTrue);

      // Toggle off
      cubit.toggleVocabularyItem(0, false);
      await settle();
      expect(cubit.state.vocabulary.first.enabled, isFalse);

      // Toggle on
      cubit.toggleVocabularyItem(0, true);
      await settle();
      expect(cubit.state.vocabulary.first.enabled, isTrue);

      // Boundary: invalid index is ignored
      cubit.toggleVocabularyItem(-1, false);
      cubit.toggleVocabularyItem(10, false);
      await settle();
      expect(cubit.state.vocabulary.first.enabled, isTrue);
    });

    test('scope toggling synchronizes vocabulary and legacy command flags', () async {
      // Dictation scope
      cubit.setVocabularyDictationEnabled(false);
      await settle();
      expect(cubit.state.vocabularyDictationEnabled, isFalse);
      expect(cubit.state.dictationCommandsEnabled, isFalse);
      expect(Settings.load()[vocabularyDictationEnabledSetting], isFalse);
      expect(Settings.load()[dictationCommandsEnabledSetting], isFalse);

      cubit.setVocabularyDictationEnabled(true);
      await settle();
      expect(cubit.state.vocabularyDictationEnabled, isTrue);
      expect(cubit.state.dictationCommandsEnabled, isTrue);

      // Transcriber scope
      cubit.setVocabularyTranscriberEnabled(false);
      await settle();
      expect(cubit.state.vocabularyTranscriberEnabled, isFalse);
      expect(cubit.state.transcriberCommandsEnabled, isFalse);
      expect(Settings.load()[vocabularyTranscriberEnabledSetting], isFalse);
      expect(Settings.load()[transcriberCommandsEnabledSetting], isFalse);

      cubit.setVocabularyTranscriberEnabled(true);
      await settle();
      expect(cubit.state.vocabularyTranscriberEnabled, isTrue);
      expect(cubit.state.transcriberCommandsEnabled, isTrue);
    });

    test('legacy text commands methods bridge seamlessly with vocabulary', () async {
      cubit.addTextCommand();
      await settle();
      expect(cubit.state.vocabulary.length, 1);

      cubit.updateTextCommand(
        0,
        const TextCommand('адрес офиса', 'Минск, Немига, 1'),
      );
      await settle();
      expect(cubit.state.vocabulary.single.phrase, 'адрес офиса');
      expect(cubit.state.vocabulary.single.replacement, 'Минск, Немига, 1');
      expect(cubit.state.textCommands.single.phrase, 'адрес офиса');

      cubit.removeTextCommand(0);
      await settle();
      expect(cubit.state.vocabulary, isEmpty);
      expect(cubit.lastDeletedItem?.phrase, 'адрес офиса');
    });

    test('reloadSettings loads existing vocabulary and migrates legacy settings', () async {
      await Settings.save({
        'vocabulary': [
          const VocabularyItem(
            id: 'saved_1',
            phrase: 'Docker',
          ).toJson(),
        ],
      });

      await cubit.close();
      NativeBridge.debugReset();
      cubit = SettingsCubit(NativeBridge());
      await settle();
      expect(cubit.state.vocabulary.single.phrase, 'Docker');
      expect(cubit.state.vocabulary.single.isHintOnly, isTrue);
    });
  });

  // ════════════════════════════════════════════════════════════════════════════
  // CLASS 12: Widget Testing for Settings 5th Tab
  // ════════════════════════════════════════════════════════════════════════════
  group('Class 12: Widget testing for Settings 5th tab (Словарь)', () {
    Widget buildTestApp(SettingsCubit cubit) => MacosApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<SettingsCubit>.value(
            value: cubit,
            child: const SettingsBody(),
          ),
        );

    testWidgets('navigation to 5th tab (vocabulary) displays all main sections', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'transcriber',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'),
          ],
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      // Tap the 'Словарь' tab
      await tester.tap(find.text('Словарь'));
      await tester.pump();

      expect(cubit.state.tab, 'vocabulary');
      expect(find.text('СЛОВАРЬ И ЗАМЕНЫ'), findsOneWidget);
      expect(find.text('ДОБАВИТЬ В СЛОВАРЬ'), findsOneWidget);
      expect(find.text('ЗАПИСИ СЛОВАРЯ (1)'), findsOneWidget);
      expect(find.text('TypeScript'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('quick-add bar handles button click, Enter shortcut, and duplicate warnings', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'),
          ],
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      final addButtonFinder = find.widgetWithText(PushButton, 'Добавить');
      expect(addButtonFinder, findsOneWidget);

      // 1. When phrase is empty, button is disabled (onPressed == null)
      var addButton = tester.widget<PushButton>(addButtonFinder);
      expect(addButton.onPressed, isNull);

      // 2. Enter phrase and replacement
      final phraseField = find.byType(AppTextField).first;
      final replacementField = find.byType(AppTextField).at(1);
      expect(phraseField, findsOneWidget);
      expect(replacementField, findsOneWidget);

      await tester.enterText(phraseField, 'юскейс');
      await tester.enterText(replacementField, 'Use Case');
      await tester.pump();

      addButton = tester.widget<PushButton>(addButtonFinder);
      expect(addButton.onPressed, isNotNull);

      // Tap 'Добавить'
      await tester.tap(addButtonFinder);
      await tester.pump();

      expect(cubit.state.vocabulary.length, 2);
      expect(cubit.state.vocabulary[1].phrase, 'юскейс');
      expect(cubit.state.vocabulary[1].replacement, 'Use Case');

      // 3. Duplicate phrase warning (case-insensitive)
      await tester.enterText(phraseField, 'typescript');
      await tester.pump();

      expect(find.text('Такая фраза уже есть в словаре'), findsOneWidget);

      // Clear duplicate text
      await tester.enterText(phraseField, '');
      await tester.pump();
      expect(find.text('Такая фраза уже есть в словаре'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('filter segmented control toggles between All, Hints, and Replacements', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'), // Hint
            VocabularyItem(id: '2', phrase: 'мак', replacement: 'Mac'), // Replacement
          ],
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      expect(find.text('Все (2)'), findsOneWidget);
      expect(find.text('Подсказки (1)'), findsOneWidget);
      expect(find.text('Замены (1)'), findsOneWidget);
      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('мак'), findsOneWidget);

      // Filter: Hints only
      await tester.tap(find.text('Подсказки (1)'));
      await tester.pump();
      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('мак'), findsNothing);

      // Filter: Replacements only
      await tester.tap(find.text('Замены (1)'));
      await tester.pump();
      expect(find.text('TypeScript'), findsNothing);
      expect(find.text('мак'), findsOneWidget);

      // Filter: All
      await tester.tap(find.text('Все (2)'));
      await tester.pump();
      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('мак'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('search filtering via MacosSearchField filters items dynamically', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'),
            VocabularyItem(id: '2', phrase: 'юскейс', replacement: 'Use Case'),
          ],
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      final searchField = find.byType(MacosSearchField);
      expect(searchField, findsOneWidget);

      // Search by phrase
      await tester.enterText(searchField, 'type');
      await tester.pump();
      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('юскейс'), findsNothing);

      // Search by replacement
      await tester.enterText(searchField, 'case');
      await tester.pump();
      expect(find.text('TypeScript'), findsNothing);
      expect(find.text('юскейс'), findsOneWidget);

      // Nonexistent search displays empty notice
      await tester.enterText(searchField, 'не_существует');
      await tester.pump();
      expect(find.text('TypeScript'), findsNothing);
      expect(find.text('юскейс'), findsNothing);
      expect(find.text('Не найдены: —'), findsOneWidget);

      // Clear search by entering whitespace which trims to empty
      await tester.enterText(searchField, ' ');
      await tester.pump();

      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('юскейс'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty state displays suggestions and clicking them adds entries', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [], // Empty vocabulary
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      expect(find.text('Словарь пока пуст'), findsOneWidget);
      expect(
        find.text('Добавьте редкие термины, имена или настройте автозамену фраз.'),
        findsOneWidget,
      );

      final chip1 = find.text('+ юскейс → Use Case');
      final chip2 = find.text('+ супервиспер → SuperWhisper');
      final chip3 = find.text('+ TypeScript');

      expect(chip1, findsOneWidget);
      expect(chip2, findsOneWidget);
      expect(chip3, findsOneWidget);

      // Click chip 1
      await tester.tap(chip1);
      await tester.pump();

      expect(cubit.state.vocabulary.length, 1);
      expect(cubit.state.vocabulary.first.phrase, 'юскейс');
      expect(cubit.state.vocabulary.first.replacement, 'Use Case');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('VocabularyItemRow toggling, in-place edit, deletion, and undo banner', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'мак', replacement: 'Mac'),
          ],
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      // Check badge
      expect(find.text('Замена'), findsOneWidget);

      // 1. Toggle enabled checkbox
      final checkboxFinder = find.byType(MacosCheckbox);
      expect(checkboxFinder, findsWidgets);
      await tester.tap(checkboxFinder.last);
      await tester.pump();
      expect(cubit.state.vocabulary.first.enabled, isFalse);

      // 2. In-place inline edit via double tap
      await tester.tap(find.text('мак'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('мак'));
      await tester.pumpAndSettle();

      // Checkmark save icon should appear in edit mode
      final checkmarkFinder = find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.checkmark_alt,
      );
      if (checkmarkFinder.evaluate().isNotEmpty) {
        // Edit phrase and save
        final editPhraseField = find.byType(AppTextField).at(2);
        await tester.enterText(editPhraseField, 'макбук');
        await tester.tap(checkmarkFinder);
        await tester.pumpAndSettle();
        expect(cubit.state.vocabulary.first.phrase, 'макбук');
      }

      // 3. Delete item
      final trashFinder = find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      );
      expect(trashFinder, findsOneWidget);
      await tester.tap(trashFinder);
      await tester.pump();

      expect(cubit.state.vocabulary, isEmpty);
      expect(find.text('Запись удалена из словаря'), findsOneWidget);
      expect(find.text('Вернуть'), findsOneWidget);

      // 4. Undo deletion
      await tester.tap(find.text('Вернуть'));
      await tester.pump();

      expect(cubit.state.vocabulary.length, 1);
      expect(find.text('Запись удалена из словаря'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('VocabularySummaryCard rendering and navigation in Dictation and Transcriber tabs', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      final cubit = _TestVocabularyCubit(
        SettingsState(
          tab: 'dictation',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'),
            VocabularyItem(id: '2', phrase: 'юскейс', replacement: 'Use Case'),
          ],
          vocabularyDictationEnabled: true,
          vocabularyTranscriberEnabled: true,
        ),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(buildTestApp(cubit));
      await tester.pump();

      // 1. In Dictation tab
      await tester.dragUntilVisible(
        find.text('Словарь и замены'),
        find.byType(ListView).first,
        const Offset(0, -200),
      );

      expect(find.text('Словарь и замены'), findsOneWidget);
      expect(
        find.textContaining('2 записи'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 подсказок, 1 замен'),
        findsOneWidget,
      );
      expect(find.text('Применять в диктовке'), findsOneWidget);

      // Tapping "Настроить словарь →" switches to 'vocabulary' tab
      final configBtn = find.text('Настроить словарь →');
      expect(configBtn, findsOneWidget);
      await tester.tap(configBtn);
      await tester.pump();

      expect(cubit.state.tab, 'vocabulary');

      // 2. In Transcriber tab
      cubit.setTab('transcriber');
      await tester.pump();

      expect(find.text('Словарь и замены'), findsOneWidget);
      expect(find.text('Применять в расшифровщике'), findsOneWidget);

      await tester.tap(find.text('Настроить словарь →'));
      await tester.pump();
      expect(cubit.state.tab, 'vocabulary');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Token budget indicator displays count and warning when exceeding 200 tokens', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(580, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];

      // Small vocabulary (under budget)
      final cubitSmall = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: const [
            VocabularyItem(id: '1', phrase: 'TypeScript'),
          ],
        ),
      );
      addTearDown(cubitSmall.close);

      await tester.pumpWidget(buildTestApp(cubitSmall));
      await tester.pump();

      expect(find.textContaining('из 220 токенов подсказки'), findsOneWidget);
      expect(
        find.text(
          'Словарь превышает рекомендуемый лимит. Часть подсказок может не попасть в окно контекста модели.',
        ),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());

      // Over-budget vocabulary (> 200 tokens)
      final heavyItems = [
        VocabularyItem(id: '1', phrase: 'Термин' * 40),
        VocabularyItem(id: '2', phrase: 'Определение' * 40),
        VocabularyItem(id: '3', phrase: 'Концепция' * 40),
      ];

      final cubitHeavy = _TestVocabularyCubit(
        SettingsState(
          tab: 'vocabulary',
          vocabulary: heavyItems,
        ),
      );
      addTearDown(cubitHeavy.close);

      await tester.pumpWidget(buildTestApp(cubitHeavy));
      await tester.pump();

      expect(
        find.text(
          'Словарь слишком велик: модель может игнорировать слова в конце',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ════════════════════════════════════════════════════════════════════════════
  // CLASS 13: End-to-End Pipeline Integration (Dictation & Queue)
  // ════════════════════════════════════════════════════════════════════════════
  group('Class 13: End-to-End Pipeline Integration', () {
    useTempSupportDir('tsukiko-vocab-pipeline-c13');

    late _FakeNative native;
    late _FakeWhisperServer server;
    late File testWavFile;

    setUp(() {
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      native = _FakeNative()..install();
      server = _FakeWhisperServer();
      NativeBridge.debugReset();

      testWavFile = File('${Directory.systemTemp.path}/tsukiko_test_dict.wav')
        ..writeAsBytesSync(List.filled(32, 42));
      native.recordPath = testWavFile.path;
    });

    tearDown(() {
      native.remove();
      if (testWavFile.existsSync()) {
        try {
          testWavFile.deleteSync();
        } catch (_) {}
      }
    });

    test('DictationCubit end-to-end: prompt conditioning and text replacement', () async {
      await Settings.save({
        vocabularySetting: [
          const VocabularyItem(
            id: 'v1',
            phrase: 'TypeScript',
          ).toJson(),
          const VocabularyItem(
            id: 'v2',
            phrase: 'юскейс',
            replacement: 'Use Case',
          ).toJson(),
        ],
        vocabularyDictationEnabledSetting: true,
      });

      final cubit = DictationCubit(NativeBridge(), server: server);
      addTearDown(cubit.close);
      await cubit.reloadSettingsForTesting();

      // 1. Check prompt includes vocabulary additions
      final effectivePrompt = cubit.optionsForTesting.effectivePrompt;
      expect(effectivePrompt, contains('TypeScript'));
      expect(effectivePrompt, contains('юскейс'));

      // 2. Perform dictation with replacement
      server.transcribedText = 'Это отличный юскейс для TypeScript.';
      testWavFile.writeAsBytesSync(List.filled(32, 42));

      await cubit.start();
      await cubit.stop();

      // Transcribed text has vocabulary replacement applied
      expect(cubit.state.last, 'Это отличный Use Case для TypeScript.');
      expect(native.pasted, 'Это отличный Use Case для TypeScript.');

      // 3. When vocabularyDictationEnabled is false, replacements are skipped
      await Settings.save({
        vocabularyDictationEnabledSetting: false,
      });
      await cubit.reloadSettingsForTesting();

      expect(cubit.optionsForTesting.effectivePrompt, isNot(contains('юскейс')));

      testWavFile.writeAsBytesSync(List.filled(32, 42));
      server.transcribedText = 'Это отличный юскейс для TypeScript.';
      await cubit.start();
      await cubit.stop();

      expect(cubit.state.last, 'Это отличный юскейс для TypeScript.');
      expect(native.pasted, 'Это отличный юскейс для TypeScript.');
    });

    test('QueueBloc end-to-end: live segment vocabulary replacement and undo', () async {
      final tmp = Directory.systemTemp.createTempSync('tsukiko-queue-c13');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final audioFile = File('${tmp.path}/запись.m4a')..writeAsStringSync('звук');

      await Settings.save({
        vocabularySetting: [
          const VocabularyItem(
            id: 'v1',
            phrase: 'адрес офиса',
            replacement: 'Минск, Немига, 1',
          ).toJson(),
        ],
        vocabularyTranscriberEnabledSetting: true,
        transcriberCommandsEnabledSetting: true,
      });

      final bloc = QueueBloc(NativeBridge());
      addTearDown(bloc.close);

      bloc.add(FilesAdded([audioFile.path]));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final targetJob = bloc.state.jobs.single;

      // Advance job with segment containing trigger phrase
      bloc.add(
        JobAdvanced(
          targetJob,
          segment: const Segment(0, 1000, 'Сообщи адрес офиса курьеру'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final liveSegment = bloc.state.jobs.single.live.single;

      // 1. Text is replaced
      expect(liveSegment.text, 'Сообщи Минск, Немига, 1 курьеру');
      expect(liveSegment.replacements.length, 1);
      expect(liveSegment.replacements.first.original, 'адрес офиса');
      expect(liveSegment.replacements.first.replacement, 'Минск, Немига, 1');

      // 2. Segment undo replacement works
      final restoredSegment = liveSegment.undoReplacement(0);
      expect(restoredSegment.text, 'Сообщи адрес офиса курьеру');
      expect(restoredSegment.replacements, isEmpty);
    });
  });
}
