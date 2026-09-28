import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/wake_diagnostics.dart';

void main() {
  test('session preserves templates without speaker identity', () async {
    final root = Directory.systemTemp.createTempSync('wake-profile-test-');
    try {
      final template = KeywordTemplate(
        durationSamples: 6400,
        frames: [for (var i = 0; i < 20; i++) Float32List(12)],
      );
      final session = WakeDiagnosticsSession.start(
        wakeWord: 'wake',
        closeWord: 'close',
        detector: 'personal-mfcc-dtw',
        profile: SpeakerProfile(
          name: 'private identity',
          dimension: 192,
          embeddings: [Float32List(192)],
          wakeWord: 'wake',
          closeWord: 'close',
          wakeTemplates: [template, template, template],
          closeTemplates: [template, template, template],
        ),
        root: root.path,
      );
      await session.stop();
      final snapshot =
          jsonDecode(
                File('${session.directory}/profile.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(snapshot.containsKey('name'), isFalse);
      expect(snapshot.containsKey('embeddings'), isFalse);
      expect(
        SpeakerProfile.fromJson(
          snapshot,
        ).hasPersonalKeywordsFor('wake', 'close'),
        isTrue,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('writes playable PCM WAV and sample-aligned marks and scores', () async {
    final root = Directory.systemTemp.createTempSync('wake-diagnostics-test-');
    try {
      final session = WakeDiagnosticsSession.start(
        wakeWord: 'Джефф',
        closeWord: 'Отбой',
        detector: 'personal-mfcc-dtw',
        root: root.path,
      );
      session.recordAudio(Float32List.fromList([0, 0.25, -0.25, 1]));
      session.mark('close');
      session.score(
        const KeywordScore(
          wake: double.infinity,
          close: 0.7,
          wakeNegative: double.infinity,
          closeNegative: 1.1,
          wakeThreshold: 0.9,
          closeThreshold: 0.8,
          candidate: 'Отбой',
        ),
      );
      await session.stop();

      final wav = File('${session.directory}/audio.wav').readAsBytesSync();
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 8);
      expect(wav.length, 52);
      final lines = File('${session.directory}/events.jsonl')
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(lines.map((e) => e['type']), ['start', 'mark', 'score', 'stop']);
      expect(lines[1]['sample'], 4);
      expect(lines[2]['wake'], isNull);
      expect(lines[2]['close'], 0.7);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
