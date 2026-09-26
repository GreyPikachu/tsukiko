// Очистка текста диктовки без зависимости от Flutter и состояния сервера.
import 'transcript.dart';

final _bracketed = RegExp(r'^[\[\(\*][^\]\)\*]*[\]\)\*]$');
final _leadingDash = RegExp(r'^(?:[-—–]\s*)+');

String tidyDictated(String raw) {
  final text = raw
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(_leadingDash, '')
      .trim();
  if (_bracketed.hasMatch(text)) return '';
  if (looksLikeSilenceHallucination(text)) return '';
  final cleaned = stripSilenceHallucinations(text).trim();
  if (cleaned.isEmpty || looksLikeSilenceHallucination(cleaned)) return '';
  return cleaned;
}
