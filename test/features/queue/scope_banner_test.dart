import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/features/queue/widgets/scope_banner.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('настройки расшифровщика открываются из верхней плашки',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(MacosApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ScopeBanner(
        selection: 0,
        name: null,
        changed: const [],
        onReset: null,
        onMakeDefault: null,
        onOpenSettings: () => opened = true,
      ),
    ));

    final gear = find.byWidgetPredicate(
        (widget) => widget is MacosIcon && widget.icon == CupertinoIcons.gear);
    expect(gear, findsOneWidget);
    await tester.tap(gear);
    expect(opened, isTrue);
  });
}
