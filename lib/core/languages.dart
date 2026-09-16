/// Коды и самоназвания поддерживаемых языков.
///
/// Чистый Dart без зависимости от Flutter, чтобы функцию нормализации кода языка
/// могли использовать как ядро приложения, так и консольный транскрибатор
/// tsukiko-transcribe (AOT-компиляция без flutter/dart:ui).
library;

const languages = [
  'auto',
  'ru',
  'be',
  'uk',
  'en',
  'pl',
  'de',
  'fr',
  'es',
  'it',
  'pt',
  'tr',
  'kk',
  'he',
  'ar',
  'zh',
  'ja',
];

const languageNativeNames = {
  'ru': 'Русский',
  'be': 'Беларуская',
  'uk': 'Українська',
  'en': 'English',
  'pl': 'Polski',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'tr': 'Türkçe',
  'kk': 'Қазақша',
  'he': 'עברית',
  'ar': 'العربية',
  'zh': '中文',
  'ja': '日本語',
};

/// Приведение кода языка к базовому виду ('ru-ru', 'ru_RU', 'en-US' -> 'ru', 'en').
String normalizeLanguageCode(String code) {
  final clean = code.trim().toLowerCase().replaceAll('_', '-');
  if (clean.isEmpty || clean == 'auto') return 'auto';
  final parts = clean.split('-');
  final base = parts.first;
  if (languageNativeNames.containsKey(base)) return base;
  if (languageNativeNames.containsKey(clean)) return clean;
  return base;
}
