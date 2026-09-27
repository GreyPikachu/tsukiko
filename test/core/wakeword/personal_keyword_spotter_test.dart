import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';

Float32List utterance(List<double> tones, {double speed = 1}) {
  const sampleRate = 16000;
  final toneSamples = (sampleRate * 0.18 * speed).round();
  final audio = Float32List(3200 + toneSamples * tones.length + 8000);
  for (var part = 0; part < tones.length; part++) {
    for (var i = 0; i < toneSamples; i++) {
      final envelope = math.sin(math.pi * i / toneSamples);
      final index = 3200 + part * toneSamples + i;
      audio[index] =
          0.22 *
          envelope *
          (math.sin(2 * math.pi * tones[part] * i / sampleRate) +
              0.4 * math.sin(4 * math.pi * tones[part] * i / sampleRate));
    }
  }
  return audio;
}

void main() {
  test(
    'time ordered templates distinguish wake and close and survive JSON',
    () {
      final wake = [
        for (final speed in [0.92, 1.0, 1.08])
          KeywordTemplate.fromAudio(utterance([210, 370, 270], speed: speed))!,
      ];
      final close = [
        for (final speed in [0.92, 1.0, 1.08])
          KeywordTemplate.fromAudio(utterance([430, 250, 390], speed: speed))!,
      ];
      final wakeNegative = KeywordTemplate.fromAudio(
        utterance([210, 370, 430]),
      )!;
      final closeNegative = KeywordTemplate.fromAudio(
        utterance([430, 250, 270]),
      )!;
      expect(
        keywordDistance(wake[0], wake[1]),
        lessThan(keywordDistance(wake[0], close[1])),
      );
      expect(KeywordTemplate.fromJson(wake[0].toJson()), isNotNull);
      expect(keywordThreshold(wake), inInclusiveRange(0.75, 1.05));
      final profile = SpeakerProfile.fromJson(
        SpeakerProfile(
          name: 'user',
          dimension: 192,
          embeddings: const [],
          wakeWord: 'Вока',
          closeWord: 'Отбой',
          wakeTemplates: wake,
          closeTemplates: close,
          wakeNegatives: [wakeNegative],
          closeNegatives: [closeNegative],
        ).toJson(),
      );
      expect(profile.hasPersonalKeywordsFor('Вока', 'Отбой'), isTrue);
      expect(profile.wakeNegatives, hasLength(1));
      expect(profile.closeNegatives, hasLength(1));

      String? detect(Float32List audio, {bool closeMode = false}) {
        final spotter = PersonalKeywordSpotter(
          wakeWord: 'Вока',
          closeWord: 'Отбой',
          wakeTemplates: wake,
          closeTemplates: close,
          wakeNegatives: [wakeNegative],
          closeNegatives: [closeNegative],
        );
        spotter.listenForClose = closeMode;
        for (var i = 0; i < audio.length; i += 1600) {
          final end = (i + 1600).clamp(0, audio.length);
          spotter.acceptAudio(Float32List.sublistView(audio, i, end));
          final word = spotter.takeDetection();
          if (word != null) return word;
        }
        return null;
      }

      expect(detect(utterance([210, 370, 270], speed: 1.04)), 'вока');
      expect(
        detect(utterance([210, 370, 270], speed: 0.62)),
        'вока',
        reason: 'a fast pronunciation must remain detectable',
      );
      expect(
        detect(utterance([210, 370, 270], speed: 1.9)),
        'вока',
        reason: 'an isolated word with a stretched vowel can match by DTW',
      );
      expect(
        detect(utterance([510, 470, 530, 500, 520, 490])),
        isNull,
        reason: 'a long unrelated phrase must not use the stretch fallback',
      );
      expect(detect(utterance([210, 370, 430])), isNull);
      expect(
        detect(utterance([430, 250, 390], speed: 0.96), closeMode: true),
        'отбой',
      );
      expect(detect(utterance([430, 250, 270]), closeMode: true), isNull);
      final closeWithClick = utterance([430, 250, 390]);
      for (var i = 1280; i < 1920; i++) {
        closeWithClick[i] = 0.025 * math.sin(i * 0.13);
      }
      expect(
        detect(closeWithClick, closeMode: true),
        'отбой',
        reason: 'a 40 ms noise burst before the word is not speech',
      );
      expect(
        detect(utterance([430, 250, 390, 210, 310, 220]), closeMode: true),
        isNull,
      );
      expect(detect(Float32List(32000)), isNull);

      final oneWindow = PersonalKeywordSpotter(
        wakeWord: 'Вока',
        closeWord: 'Отбой',
        wakeTemplates: wake,
        closeTemplates: close,
      );
      oneWindow.listenForClose = true;
      final closeAudio = utterance([430, 250, 390]);
      oneWindow.acceptAudio(
        Float32List.sublistView(closeAudio, 0, 3200 + 3 * 2880),
      );
      expect(
        oneWindow.takeDetection(),
        isNull,
        reason: 'close word must not fire before the utterance ends',
      );
      oneWindow.acceptAudio(
        Float32List.sublistView(closeAudio, 3200 + 3 * 2880),
      );
      expect(oneWindow.takeDetection(), 'отбой');
    },
  );
}
