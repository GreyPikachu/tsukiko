import 'dart:math' as math;
import 'dart:typed_data';

import 'acoustic_feature_extractor.dart';
import 'keyword_tokenizer.dart';
import 'speech_verifier.dart';

/// One pronunciation recorded by the user. No raw microphone audio is stored.
class KeywordTemplate {
  const KeywordTemplate({required this.durationSamples, required this.frames});

  final int durationSamples;
  final List<Float32List> frames;

  static KeywordTemplate? fromAudio(
    Float32List audio, {
    int minActiveSamples = 4000,
  }) {
    final speech = SpeechVerifier.prepareCalibrationSamples(
      audio,
      minActiveSamples: minActiveSamples,
    );
    if (speech.isEmpty) return null;
    final frames = AcousticFeatureExtractor.keywordFrames(speech);
    if (frames.length < 10 || frames.length > 120) return null;
    return KeywordTemplate(durationSamples: speech.length, frames: frames);
  }

  Map<String, Object> toJson() => {
    'durationSamples': durationSamples,
    'frames': [for (final row in frames) row.toList()],
  };

  static KeywordTemplate? fromJson(Object? value) {
    if (value is! Map) return null;
    final length = value['durationSamples'];
    final rawFrames = value['frames'];
    if (length is! int ||
        length < 5600 ||
        length > 96000 ||
        rawFrames is! List ||
        rawFrames.length < 10 ||
        rawFrames.length > 120) {
      return null;
    }
    final frames = <Float32List>[];
    for (final raw in rawFrames) {
      if (raw is! List ||
          raw.length != 12 ||
          raw.any((element) => element is! num || !element.isFinite)) {
        return null;
      }
      frames.add(
        Float32List.fromList(raw.cast<num>().map((n) => n.toDouble()).toList()),
      );
    }
    return KeywordTemplate(durationSamples: length, frames: frames);
  }
}

/// Banded dynamic time warping: compare how a phrase evolves, not just its
/// average timbre. Longer/shorter pronunciations can align locally.
double keywordDistance(KeywordTemplate a, KeywordTemplate b) {
  final left = a.frames;
  final right = b.frames;
  if (left.isEmpty || right.isEmpty) return double.infinity;
  final previous = Float64List(right.length + 1);
  final current = Float64List(right.length + 1);
  previous.fillRange(0, previous.length, double.infinity);
  previous[0] = 0;
  final band = math.max(8, (left.length - right.length).abs() + 8);
  for (var i = 1; i <= left.length; i++) {
    current.fillRange(0, current.length, double.infinity);
    final middle = (i * right.length / left.length).round();
    final low = math.max(1, middle - band);
    final high = math.min(right.length, middle + band);
    for (var j = low; j <= high; j++) {
      var squared = 0.0;
      for (var d = 0; d < 12; d++) {
        final delta = left[i - 1][d] - right[j - 1][d];
        squared += delta * delta;
      }
      final cost = math.sqrt(squared / 12);
      current[j] =
          cost +
          math.min(previous[j - 1], math.min(previous[j], current[j - 1]));
    }
    previous.setAll(0, current);
  }
  return previous[right.length] / math.max(left.length, right.length);
}

/// The calibration threshold follows leave-one-out positive distances.
/// A large outlier is rejected during enrollment instead of making all later
/// detections permissive.
double keywordThreshold(List<KeywordTemplate> templates) {
  if (templates.length < 2) return 0.82;
  var largestNearest = 0.0;
  for (var i = 0; i < templates.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < templates.length; j++) {
      if (i != j) {
        nearest = math.min(
          nearest,
          keywordDistance(templates[i], templates[j]),
        );
      }
    }
    largestNearest = math.max(largestNearest, nearest);
  }
  return (largestNearest + 0.10).clamp(0.75, 1.05);
}

/// Wake detection scores overlapping windows for low latency. Close detection
/// scores a completed, isolated utterance so syllables inside longer speech
/// cannot end the recording. Each word has its own calibration examples.
class PersonalKeywordSpotter {
  PersonalKeywordSpotter({
    required this.wakeWord,
    required this.closeWord,
    required this.wakeTemplates,
    required this.closeTemplates,
    this.wakeNegatives = const [],
    this.closeNegatives = const [],
  }) : wakeThreshold = keywordThreshold(wakeTemplates),
       closeThreshold = closeTemplates.isEmpty
           ? 0
           : keywordThreshold(closeTemplates);

  final String wakeWord;
  final String closeWord;
  final List<KeywordTemplate> wakeTemplates;
  final List<KeywordTemplate> closeTemplates;
  final List<KeywordTemplate> wakeNegatives;
  final List<KeywordTemplate> closeNegatives;
  final double wakeThreshold;
  final double closeThreshold;
  bool listenForClose = false;

  /// Only attached during an explicit developer diagnostic recording.
  void Function(KeywordScore score)? onScore;

  Float32List _recent = Float32List(0);
  int _sinceEvaluation = 0;
  String? _candidate;
  int _candidateHits = 0;
  String? _pending;
  int _totalSamples = 0;
  int _lastCloseSegmentEnd = 0;

  String? takeDetection() {
    final result = _pending;
    _pending = null;
    return result;
  }

  void reset() {
    _recent = Float32List(0);
    _sinceEvaluation = 0;
    _candidate = null;
    _candidateHits = 0;
    _pending = null;
    _totalSamples = 0;
    _lastCloseSegmentEnd = 0;
  }

  void acceptAudio(Float32List audio) {
    if (audio.isEmpty || _pending != null) return;
    const maxSamples = 16000 * 3;
    final keep = math.min(maxSamples, _recent.length + audio.length).toInt();
    final next = Float32List(keep);
    final oldCount = math
        .min(_recent.length, keep - math.min(audio.length, keep))
        .toInt();
    final addedCount = math.min(audio.length, keep).toInt();
    next.setRange(0, oldCount, _recent, _recent.length - oldCount);
    next.setRange(oldCount, keep, audio, audio.length - addedCount);
    _recent = next;
    _totalSamples += audio.length;
    _sinceEvaluation += audio.length;
    if (_sinceEvaluation < 1600) return;
    _sinceEvaluation %= 1600;

    if (listenForClose) {
      final evaluated = _evaluateCompletedCloseSegment();
      if (!evaluated) {
        onScore?.call(
          KeywordScore(
            wake: double.infinity,
            close: double.infinity,
            wakeNegative: double.infinity,
            closeNegative: double.infinity,
            wakeThreshold: wakeThreshold,
            closeThreshold: closeThreshold,
            candidate: null,
            closeReason: 'awaiting_boundary',
          ),
        );
      }
      return;
    }
    final wake = _bestDistance(wakeTemplates);
    final close = closeTemplates.isEmpty
        ? double.infinity
        : _bestDistance(closeTemplates);
    final wakeNegative = _bestDistance(wakeNegatives);
    // A strict hard-negative gap discarded genuine quiet/fast wake words
    // when both template scores were close. The negative must still lose.
    final detected =
        wake < wakeThreshold &&
            close > wake + 0.08 &&
            wakeNegative > wake + 0.04
        ? wakeWord
        : null;
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: wakeNegative,
        closeNegative: double.infinity,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: detected,
      ),
    );
    if (detected == null) {
      _candidate = null;
      _candidateHits = 0;
      return;
    }
    _candidateHits = _candidate == detected ? _candidateHits + 1 : 1;
    _candidate = detected;
    if (_candidateHits >= 2 || wake < wakeThreshold * 0.80) {
      _pending = KeywordTokenizer.normalizeKeywordText(detected);
      _candidate = null;
      _candidateHits = 0;
    }
  }

  bool _evaluateCompletedCloseSegment() {
    final segment = _lastCompletedSpeechSegment();
    if (segment == null) return false;
    final (start, end) = segment;
    final absoluteEnd = _totalSamples - _recent.length + end;
    if (absoluteEnd <= _lastCloseSegmentEnd) return false;
    _lastCloseSegmentEnd = absoluteEnd;
    final length = end - start;
    final meanLength = closeTemplates.isEmpty
        ? 0
        : closeTemplates
                  .map((template) => template.durationSamples)
                  .reduce((a, b) => a + b) ~/
              closeTemplates.length;
    final durationMs = length * 1000 ~/ 16000;
    String reason = 'duration';
    var close = double.infinity;
    var wake = double.infinity;
    var negative = double.infinity;
    if (meanLength > 0 &&
        length >= math.max(5600, meanLength * 0.60) &&
        length <= math.min(16000 * 2.4, meanLength * 1.65)) {
      final candidate = KeywordTemplate.fromAudio(
        Float32List.sublistView(_recent, start, end),
      );
      if (candidate != null) {
        close = _distanceTo(candidate, closeTemplates);
        wake = _distanceTo(candidate, wakeTemplates);
        negative = _distanceTo(candidate, closeNegatives);
        final threshold = math.min(1.06, closeThreshold + 0.03);
        if (close >= threshold) {
          reason = 'score';
        } else if (wake <= close + 0.06) {
          reason = 'wake_word';
        } else if (negative + 0.12 < close) {
          reason = 'negative_word';
        } else {
          reason = 'accepted';
          _pending = KeywordTokenizer.normalizeKeywordText(closeWord);
        }
      } else {
        reason = 'invalid_audio';
      }
    }
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: double.infinity,
        closeNegative: negative,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: reason == 'accepted' ? closeWord : null,
        closeSegmentMs: durationMs,
        closeReason: reason,
      ),
    );
    return true;
  }

  double _distanceTo(
    KeywordTemplate candidate,
    List<KeywordTemplate> templates,
  ) {
    var best = double.infinity;
    for (final template in templates) {
      best = math.min(best, keywordDistance(candidate, template));
    }
    return best;
  }

  /// Find an utterance bounded by at least 200 ms of quiet. The sliding
  /// windows used for wake words matched ordinary syllables inside sentences;
  /// a close word must instead be a complete, isolated utterance.
  (int, int)? _lastCompletedSpeechSegment() {
    const frame = 320;
    const trailingQuietFrames = 10;
    final count = _recent.length ~/ frame;
    if (count < 28) return null;
    final active = List<bool>.filled(count, false);
    for (var i = 0; i < count; i++) {
      var power = 0.0;
      final start = i * frame;
      for (var j = start; j < start + frame; j++) {
        power += _recent[j] * _recent[j];
      }
      active[i] = math.sqrt(power / frame) > 0.002;
    }
    // Bridge brief unvoiced phonemes inside one word, not inter-word pauses.
    var previousActive = -1;
    for (var i = 0; i < count; i++) {
      if (!active[i]) continue;
      if (previousActive >= 0 && i - previousActive <= 4) {
        for (var j = previousActive + 1; j < i; j++) {
          active[j] = true;
        }
      }
      previousActive = i;
    }
    // A click or brief breath before the keyword must not revoke its leading
    // pause. The old gate treated even a single 20 ms spike as speech.
    int? burstStart;
    for (var i = 0; i <= count; i++) {
      final speech = i < count && active[i];
      if (speech && burstStart == null) burstStart = i;
      if (!speech && burstStart != null) {
        if (i - burstStart <= 3) {
          for (var j = burstStart; j < i; j++) {
            active[j] = false;
          }
        }
        burstStart = null;
      }
    }
    int? start;
    (int, int)? latest;
    for (var i = 0; i <= count; i++) {
      final speech = i < count && active[i];
      if (speech && start == null) start = i;
      if (!speech && start != null) {
        final isolatedStart =
            start >= 6 &&
            !active.getRange(start - 6, start).any((frame) => frame);
        if (isolatedStart && i <= count - trailingQuietFrames) {
          latest = (start * frame, i * frame);
        }
        start = null;
      }
    }
    return latest;
  }

  double _bestDistance(List<KeywordTemplate> templates) {
    if (templates.isEmpty) return double.infinity;
    final meanLength =
        templates.map((t) => t.durationSamples).reduce((a, b) => a + b) ~/
        templates.length;
    var best = double.infinity;
    for (final ratio in [0.8, 1.0, 1.2]) {
      final length = (meanLength * ratio).round();
      for (final offset in [0, 1600, 3200]) {
        if (_recent.length < length + offset) continue;
        final end = _recent.length - offset;
        final chunk = Float32List.sublistView(_recent, end - length, end);
        final candidate = KeywordTemplate.fromAudio(
          chunk,
          minActiveSamples: 2400,
        );
        if (candidate == null) continue;
        for (final template in templates) {
          final lengthRatio =
              candidate.durationSamples / template.durationSamples;
          if (lengthRatio < 0.65 || lengthRatio > 1.45) continue;
          best = math.min(best, keywordDistance(candidate, template));
        }
      }
    }
    return best;
  }
}

class KeywordScore {
  const KeywordScore({
    required this.wake,
    required this.close,
    required this.wakeNegative,
    required this.closeNegative,
    required this.wakeThreshold,
    required this.closeThreshold,
    required this.candidate,
    this.closeSegmentMs,
    this.closeReason,
  });

  final double wake;
  final double close;
  final double wakeNegative;
  final double closeNegative;
  final double wakeThreshold;
  final double closeThreshold;
  final String? candidate;
  final int? closeSegmentMs;
  final String? closeReason;

  Map<String, Object?> toJson() => {
    'wake': wake.isFinite ? wake : null,
    'close': close.isFinite ? close : null,
    'wakeNegative': wakeNegative.isFinite ? wakeNegative : null,
    'closeNegative': closeNegative.isFinite ? closeNegative : null,
    'wakeThreshold': wakeThreshold,
    'closeThreshold': closeThreshold,
    'candidate': candidate,
    if (closeSegmentMs != null) 'closeSegmentMs': closeSegmentMs,
    if (closeReason != null) 'closeReason': closeReason,
  };
}
