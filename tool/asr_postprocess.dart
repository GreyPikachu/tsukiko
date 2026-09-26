// Потоковая проверка ровно того же разбора и словаря, что используют CLI и UI.
// Одна JSON-строка на входе — одна JSON-строка на выходе.
import 'dart:convert';
import 'dart:io';

import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/dictated_text.dart';
import 'package:tsukiko/core/vocabulary.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    try {
      final request = jsonDecode(line) as Map<String, dynamic>;
      final engine = request['engine'] as String;
      final raw = request['raw'] as String;
      final items = vocabularyFromJson(request['vocabulary']);
      if (engine == 'prompt') {
        stdout.writeln(
          jsonEncode({'prompt': promptWithVocabulary(raw, items)}),
        );
        continue;
      }
      if (engine == 'dictation') {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final recognized = (data['text'] ?? '').toString();
        final cleaned = tidyDictated(recognized);
        final finalText = applyVocabularyReplacements(cleaned, items);
        stdout.writeln(
          jsonEncode({
            'rawText': recognized,
            'cleanedText': cleaned,
            'finalText': finalText.text,
            'replacements': [
              for (final r in finalText.replacements)
                {
                  'start': r.start,
                  'end': r.end,
                  'original': r.original,
                  'replacement': r.replacement,
                },
            ],
          }),
        );
        continue;
      }
      final transcript = engine == 'whisper'
          ? parseWhisperJson(raw)
          : parseNemoJson(raw);
      final finalTranscript = transcript.applyVocabulary(items);
      stdout.writeln(
        jsonEncode({
          'language': transcript.lang,
          'cleaned': [
            for (final s in transcript.segments)
              {'from': s.from, 'to': s.to, 'text': s.text},
          ],
          'final': [
            for (final s in finalTranscript.segments)
              {
                'from': s.from,
                'to': s.to,
                'text': s.text,
                'replacements': [
                  for (final r in s.replacements)
                    {
                      'start': r.start,
                      'end': r.end,
                      'original': r.original,
                      'replacement': r.replacement,
                    },
                ],
              },
          ],
        }),
      );
    } catch (e) {
      stdout.writeln(jsonEncode({'error': '$e'}));
    }
  }
}
