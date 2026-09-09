import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/queue/widgets/segment_row.dart';

void main() {
  testWidgets('значок копирования фрагмента имеет размер панели', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosApp(
        home: SegmentRow(
          segment: const Segment(0, 0, 'Текст'),
          showTimestamp: false,
          onCopied: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icon = tester.widget<MacosIcon>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MacosIcon && widget.icon == CupertinoIcons.doc_on_doc,
      ),
    );
    expect(icon.size, IconSize.toolbar);
  });
}
