import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:macos_ui/macos_ui.dart';
import 'core/app_locale.dart';
import 'l10n/gen/app_localizations.dart';
import 'legacy_migration.dart';
import 'features/dictation/hud_page.dart' show runHud;
import 'features/dictation/panel_page.dart' show runPanel;
import 'features/settings/settings_page.dart' show runSettings;
import 'features/queue/home_page.dart';
import 'platform/os.dart';

/// Точка входа второго движка Flutter — того, что рисует панель у строки
/// меню и ведёт диктовку. Она обязана лежать именно здесь: FlutterEngine
/// на macOS ищет точку входа только в корневой библиотеке приложения.
@pragma('vm:entry-point')
void panelMain() => runPanel();

/// Точка входа третьего движка — окна настроек. Оно открывается по ⌘,
/// и из поповера, а в режиме без значка в Dock только из поповера:
/// строки меню там нет вовсе.
@pragma('vm:entry-point')
void settingsMain() => runSettings();

/// Точка входа движка плавающей панели записи. Только Windows: на macOS
/// эта панель написана на SwiftUI и остаётся там — почему, разобрано
/// в `docs/задача-панель-записи.md`.
@pragma('vm:entry-point')
void hudMain() => runHud();

/// Второй копии здесь не бывает: её ловит и завершает сторона macOS ещё
/// до запуска движка (AppDelegate.applicationWillFinishLaunching), подняв
/// окно уже работающей. Проверять это в Dart больше нечем и незачем.
Future<void> main(List<String> args) async {
  refreshLocale();
  WidgetsFlutterBinding.ensureInitialized();
  // Настоящий материал окна: содержимое во всю высоту, титульная полоса
  // прозрачная. Спрашиваем не «мы на macOS?», а «даёт ли система материал
  // окна»: настраивать здесь нечего ровно там, где материала нет, — а
  // плагин, который это делает, на такой системе и не поднимется.
  if (os.hasWindowMaterial) {
    await const MacosWindowUtilsConfig(toolbarStyle: NSWindowToolbarStyle.unified).apply();
  }
  // До первого findModels(): список моделей должен собираться уже
  // из своей папки. Когда переезжать нечего, это одна проверка папки.
  await migrateLegacyModels();
  runApp(TsukikoApp(
    initialFiles: args.where((a) => FileSystemEntity.typeSync(a) != FileSystemEntityType.notFound),
  ));
}

class TsukikoApp extends StatelessWidget {
  const TsukikoApp({super.key, this.initialFiles = const []});
  final Iterable<String> initialFiles;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
        valueListenable: appLocale,
        builder: (context, locale, _) => MacosApp(
          locale: locale,
          title: appName,
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: ThemeMode.system,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomePage(initialFiles: initialFiles),
        ),
      );
}

