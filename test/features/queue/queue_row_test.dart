import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/features/queue/job.dart';
import 'package:tsukiko/features/queue/widgets/queue_row.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('дата и время записи получают вторую строку в узкой очереди',
      (tester) async {
    const name = 'Диктовка 2026-09-09 10-42-37.wav';
    final job = Job(File('/tmp/$name'));

    await tester.pumpWidget(MacosApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SizedBox(
        width: 248,
        child: QueueRow(
          job: job,
          selected: false,
          lead: true,
          customised: false,
          onTap: () {},
        ),
      ),
    ));

    final title = tester.widget<Text>(find.text(name));
    expect(title.maxLines, 2);
    expect(title.softWrap, isTrue);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is MacosTooltip && widget.message == name),
        findsOneWidget,
        reason: 'даже очень длинное имя должно читаться целиком');
    expect(tester.takeException(), isNull);
  });
}
