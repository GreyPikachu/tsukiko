/// Слова и числа: как приложение называет вещи по-русски и какие файлы
/// вообще берёт в работу.
///
/// Отдельно от всего остального затем, что это единственная часть ядра,
/// которую придётся трогать при переводе на другой язык.
library;

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
const _languageNames = {
  'auto': 'Определять автоматически',
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

String languageName(String code) =>
    _languageNames[code.toLowerCase()] ?? code.toUpperCase();

// ── маленькие правила языка и чисел ─────────────────────────────────────────

/// «1 фрагмент · 2 фрагмента · 5 фрагментов». Без этого интерфейс на русском
/// сразу выдаёт, что его переводили наспех.
String plural(int n, String one, String few, String many) {
  final h = n.abs() % 100, t = n.abs() % 10;
  if (h >= 11 && h <= 14) return many;
  if (t == 1) return one;
  if (t >= 2 && t <= 4) return few;
  return many;
}

String segmentsLabel(int n) => '$n ${plural(n, 'фрагмент', 'фрагмента', 'фрагментов')}';

String wordsLabel(int n) => '$n ${plural(n, 'слово', 'слова', 'слов')}';

String filesLabel(int n) => '$n ${plural(n, 'файл', 'файла', 'файлов')}';

String recordsLabel(int n) => '$n ${plural(n, 'запись', 'записи', 'записей')}';

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
