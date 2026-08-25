/// Слова и числа: как приложение называет вещи по-русски и какие файлы
/// вообще берёт в работу.
///
/// Отдельно от всего остального затем, что это единственная часть ядра,
/// которую придётся трогать при переводе на другой язык.
library;

import 'app_locale.dart';

/// `appName` объявлен рядом с границей ОС (там он нужен для путей),
/// но пользуются им повсюду — отдаём дальше отсюда.
export '../platform/os.dart' show appName, bundleId;
const audioExt = {
  '.ogg', '.oga', '.opus', '.mp3', '.m4a', '.aac', '.wav', '.aiff', '.aif',
  '.caf', '.flac', '.mp4', '.mov', '.m4b', '.wma',
};

/// Расшифровки, которые приложение умеет открывать — и через диалог,
/// и перетаскиванием.
const transcriptExt = {'.txt', '.srt', '.vtt', '.json', '.md'};

const languages = [
  'auto', 'ru', 'be', 'uk', 'en', 'pl', 'de', 'fr', 'es', 'it', 'pt', 'tr',
  'kk', 'he', 'ar', 'zh', 'ja',
];

/// Языки называются так, как их называют их носители, — как в системных
/// настройках macOS. Код в интерфейсе не показываем никогда.
// 'auto' — единственный пункт этого списка, который не имя языка,
// а команда «сам разберись», поэтому и живёт он не здесь, а в ARB —
// подписи остальных языков идут как есть, языком интерфейса не тронуты.
String get _languageAuto => currentL10n().languageAuto;

const _languageNames = {
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

String languageName(String code) => code.toLowerCase() == 'auto'
    ? _languageAuto
    : _languageNames[code.toLowerCase()] ?? code.toUpperCase();

// ── маленькие правила языка и чисел ─────────────────────────────────────────

/// «1 фрагмент · 2 фрагмента · 5 фрагментов». Склонения считает ICU внутри
/// ARB: у каждого языка свои правила, и руками их держать больше не надо.
String segmentsLabel(int n) => currentL10n().segmentsLabel(n);

String wordsLabel(int n) => currentL10n().wordsLabel(n);

String filesLabel(int n) => currentL10n().filesLabel(n);

String recordsLabel(int n) => currentL10n().recordsLabel(n);

int wordCount(String text) =>
    RegExp(r'[^\s]+').allMatches(text).length;

/// Длительность для человека: «4:07», «1:12:30». Часы появляются только когда
/// они есть — лишние нули читаются как шум.
String humanDuration(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
