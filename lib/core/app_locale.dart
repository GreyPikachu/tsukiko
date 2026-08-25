import 'package:flutter/widgets.dart'
    show Locale, ValueNotifier, WidgetsBinding, basicLocaleListResolution;

import '../l10n/gen/app_localizations.dart';
import 'settings.dart';

/// Выбранный язык интерфейса. `null` — «как в системе».
///
/// Значение живёт отдельно от снимка настроек: язык нужен трём окнам ещё
/// до того, как построится хоть один блок, и каждое окно слушает его само.
final appLocale = ValueNotifier<Locale?>(loadLocale());

/// Ключ в общих настройках. Пусто — системный язык.
const localeSetting = 'locale';

Locale? loadLocale() {
  final id = (Settings.load()[localeSetting] as String?) ?? '';
  return id.isEmpty ? null : Locale(id);
}

/// Перечитать язык после чужой правки настроек.
void refreshLocale() => appLocale.value = loadLocale();

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
  final chosen = appLocale.value;
  if (chosen != null) return lookupAppLocalizations(chosen);
  final resolved = basicLocaleListResolution(
    WidgetsBinding.instance.platformDispatcher.locales,
    AppLocalizations.supportedLocales,
  );
  return lookupAppLocalizations(resolved);
}
