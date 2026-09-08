import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/features/queue/library_sheet.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';
import 'package:tsukiko/platform/os.dart';

/// Прошлые расшифровки. Проверять здесь стоит ровно одно: что список
/// с диска доезжает до экрана и что раскладка на две колонки не рвётся —
/// именно она и была причиной завести отдельный виджет вместо строки
/// в меню.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    root = Directory.systemTemp.createTempSync('tsukiko-lib-sheet');
    final month = Directory(os.join(root.path, '2026-09'))..createSync();
    File(os.join(month.path, 'Совещание.txt'))
        .writeAsStringSync('Первая строка.\nВторая строка.');
    File(os.join(month.path, 'Разговор.srt')).writeAsStringSync(
        '1\n00:00:00,000 --> 00:00:02,000\nСказанное вслух\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, String at) async {
    await tester.pumpWidget(MacosApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LibrarySheet(
        root: at,
        onOpenInQueue: (_) {},
        onReveal: (_) {},
        onStatus: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('список читается с диска, текст выбранной строки виден',
      (tester) async {
    await open(tester, root.path);

    expect(find.text('Совещание.txt'), findsOneWidget);
    expect(find.text('Разговор.srt'), findsOneWidget);

    // Первая строка показана сразу: пустая правая половина при непустом
    // списке читалась бы как «ничего не нашлось».
    await tester.tap(find.text('Совещание.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Вторая строка.'), findsOneWidget);

    // Субтитры показываем текстом, а не разметкой: читают здесь сказанное,
    // а не формат.
    await tester.tap(find.text('Разговор.srt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сказанное вслух'), findsOneWidget);
    expect(find.textContaining('-->'), findsNothing);
  });

  testWidgets('пустая библиотека объясняет себя, а не показывает пустоту',
      (tester) async {
    final empty = Directory.systemTemp.createTempSync('tsukiko-lib-empty');
    await open(tester, empty.path);
    expect(find.text('Расшифровок пока нет'), findsOneWidget);
    empty.deleteSync(recursive: true);
  });
}
