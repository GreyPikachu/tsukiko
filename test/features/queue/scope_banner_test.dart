import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/queue/widgets/chrome.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('настройки стоят в правой части полосы инспектора', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MacosApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: InspectorHeader(onOpenSettings: () => opened = true),
      ),
    );

    final gear = find.byWidgetPredicate(
      (widget) => widget is MacosIcon && widget.icon == CupertinoIcons.gear,
    );
    expect(gear, findsOneWidget);
    final icon = tester.widget<MacosIcon>(gear);
    final context = tester.element(gear);
    expect(icon.color, Surface.toolbarIcon(context, enabled: true));
    expect(icon.color, isNot(MacosColors.systemBlueColor));
    await tester.tap(gear);
    expect(opened, isTrue);
  });
}
