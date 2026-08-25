import 'package:flutter/widgets.dart'
    show WidgetsBinding, basicLocaleListResolution;

import '../l10n/gen/app_localizations.dart';

/// Строки для мест без `BuildContext` — блоков и ядра.
///
/// `AppLocalizations.of(context)` там недоступен: блоки создаются в
/// `BlocProvider.create`, а это ещё до `MacosApp`, то есть выше
/// `Localizations` в дереве виджетов. Разрешаем язык вручную — тем же
/// алгоритмом, что использует `WidgetsApp` по умолчанию, — и берём готовые
/// строки напрямую, без ожидания виджета.
///
/// Локаль берём через `WidgetsBinding.instance`, а не напрямую из
/// `dart:ui` — тесты подменяют локаль именно на этом уровне
/// (`TestWidgetsFlutterBinding`), и `dart:ui`-синглтон эту подмену не видит.
///
/// Один процесс — три изолята (главное окно, панель диктовки, настройки),
/// и у каждого свой системный локаль неоткуда взяться, кроме общей ОС,
/// поэтому все три сходятся на одном языке без обмена сообщениями.
AppLocalizations currentL10n() {
  final resolved = basicLocaleListResolution(
    WidgetsBinding.instance.platformDispatcher.locales,
    AppLocalizations.supportedLocales,
  );
  return lookupAppLocalizations(resolved);
}
