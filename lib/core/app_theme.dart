import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;

import 'settings.dart';

/// Выбранная тема окон: светлая, тёмная или «как в системе».
///
/// Устроена так же, как язык в `app_locale.dart`: окон четыре, у каждого
/// свой изолят, и каждое слушает это значение само. С диска значение
/// читается по [refreshTheme] — на старте окна и на «reload» после чужой
/// правки настроек.
///
/// Раньше выбора не было вовсе: все окна шли за системой, и на светлой
/// Windows приложение оказывалось светлым, хотя на Mac автора — тёмным.
/// Само по себе это верно, но человеку нечем было это изменить.
final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

/// Ключ в общих настройках: 'light', 'dark' или пусто — как в системе.
const themeSetting = 'theme';

ThemeMode parseThemeMode(String? id) => switch (id) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

String themeModeId(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => '',
    };

ThemeMode loadThemeMode() =>
    parseThemeMode(Settings.load()[themeSetting] as String?);

/// Перечитать тему после чужой правки настроек.
void refreshTheme() => appThemeMode.value = loadThemeMode();
