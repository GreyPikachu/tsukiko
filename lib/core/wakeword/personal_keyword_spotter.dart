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

  static KeywordTemplate? fromCalibrationAudio(Float32List audio) {
    final word = SpeechVerifier.prepareIsolatedKeywordSamples(audio);
    return word.isEmpty ? null : fromAudio(word);
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

/// Compare the transition into the last phoneme, excluding edge padding.
/// Whole-word DTW can stretch a matching prefix over a missing ending.
double keywordEndingDistance(KeywordTemplate a, KeywordTemplate b) {
  KeywordTemplate middleEnd(KeywordTemplate value) {
    final start = (value.frames.length * 0.40).floor();
    final end = (value.frames.length * 0.80).ceil();
    return KeywordTemplate(
      durationSamples: value.durationSamples,
      frames: value.frames.sublist(start, end),
    );
  }

  return keywordDistance(middleEnd(a), middleEnd(b));
}

double keywordEndingThreshold(List<KeywordTemplate> templates) {
  if (templates.length < 2) return 0.9;
  var largestNearest = 0.0;
  for (var i = 0; i < templates.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < templates.length; j++) {
      if (i != j) {
        nearest = math.min(
          nearest,
          keywordEndingDistance(templates[i], templates[j]),
        );
      }
    }
    largestNearest = math.max(largestNearest, nearest);
  }
  return (largestNearest + 0.18).clamp(0.48, 1.08);
}

/// A sliding wake score finds quiet and fast pronunciations, but is confirmed
/// only after a short pause. Close uses complete isolated utterances.
class PersonalKeywordSpotter {
  PersonalKeywordSpotter({
    required this.wakeWord,
    required this.closeWord,
    required this.wakeTemplates,
    required this.closeTemplates,
    this.wakeNegatives = const [],
    this.closeNegatives = const [],
  }) : wakeThreshold = keywordThreshold(wakeTemplates),
       wakeEndingThreshold = keywordEndingThreshold(wakeTemplates),
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
  final double wakeEndingThreshold;
  final double closeThreshold;
  bool listenForClose = false;

  /// Only attached during an explicit developer diagnostic recording.
  void Function(KeywordScore score)? onScore;

  Float32List _recent = Float32List(0);
  int _sinceEvaluation = 0;
  String? _pending;
  int _totalSamples = 0;
  int _lastWakeSegmentEnd = 0;
  int? _wakeCandidateAt;
  final _closeSegments = _StreamingSpeechSegments();

  String? takeDetection() {
    final result = _pending;
    _pending = null;
    return result;
  }

  void reset() {
    _recent = Float32List(0);
    _sinceEvaluation = 0;
    _pending = null;
    _totalSamples = 0;
    _lastWakeSegmentEnd = 0;
    _wakeCandidateAt = null;
    _closeSegments.reset();
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
    if (listenForClose) _closeSegments.acceptAudio(audio);
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
    final wake = _bestDistance(
      wakeTemplates,
      maxEndingDistance: wakeEndingThreshold,
    );
    final close = _bestDistance(closeTemplates);
    final negative = _bestDistance(wakeNegatives);
    final matched =
        wake < wakeThreshold && close > wake + 0.08 && negative > wake + 0.04;
    if (matched) _wakeCandidateAt = _totalSamples;
    final candidateAge = _wakeCandidateAt == null
        ? 16000
        : _totalSamples - _wakeCandidateAt!;
    final boundary = candidateAge <= 11200 && _recentWordBoundary();
    final voiced =
        boundary &&
        _hasVoicedFrames(math.max(0, _recent.length - 16000), _recent.length);
    final accepted = boundary && voiced;
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: negative,
        closeNegative: double.infinity,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: accepted ? wakeWord : null,
        wakeReason: matched || _wakeCandidateAt != null
            ? accepted
                  ? 'accepted'
                  : boundary
                  ? 'noise'
                  : 'awaiting_boundary'
            : null,
      ),
    );
    if (accepted) {
      _wakeCandidateAt = null;
      _pending = KeywordTokenizer.normalizeKeywordText(wakeWord);
      return;
    }
    if (candidateAge > 11200) _wakeCandidateAt = null;
    _evaluateCompletedWakeSegment();
  }

  bool _evaluateCompletedWakeSegment() {
    if (wakeTemplates.isEmpty) return false;
    final segment = _lastCompletedSpeechSegment(trailingQuietFrames: 6);
    if (segment == null) return false;
    final (start, end) = segment;
    final absoluteEnd = _totalSamples - _recent.length + end;
    if (absoluteEnd <= _lastWakeSegmentEnd) return false;
    _lastWakeSegmentEnd = absoluteEnd;
    final meanLength =
        wakeTemplates.map((t) => t.durationSamples).reduce((a, b) => a + b) ~/
        wakeTemplates.length;
    final length = end - start;
    if (length < math.max(7200, meanLength * 1.6) ||
        length > math.min(16000 * 2.4, meanLength * 2.5)) {
      return true;
    }
    final candidate = KeywordTemplate.fromAudio(
      _segmentAudio(start, end),
      minActiveSamples: 2400,
    );
    if (candidate == null) {
      _emitRejectedWake(length, 'invalid_audio');
      return true;
    }
    final wake = _distanceTo(
      candidate,
      wakeTemplates,
      maxEndingDistance: wakeEndingThreshold,
    );
    final close = _distanceTo(candidate, closeTemplates);
    final negative = _distanceTo(candidate, wakeNegatives);
    final accepted =
        wake < math.min(wakeThreshold, 0.96) &&
        close > wake + 0.08 &&
        negative > wake + 0.04;
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: negative,
        closeNegative: double.infinity,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: accepted ? wakeWord : null,
        wakeSegmentMs: length * 1000 ~/ 16000,
        wakeReason: accepted ? 'accepted' : 'score',
      ),
    );
    if (accepted) {
      _pending = KeywordTokenizer.normalizeKeywordText(wakeWord);
    }
    return true;
  }

  void _emitRejectedWake(int length, String reason) {
    onScore?.call(
      KeywordScore(
        wake: double.infinity,
        close: double.infinity,
        wakeNegative: double.infinity,
        closeNegative: double.infinity,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: null,
        wakeSegmentMs: length * 1000 ~/ 16000,
        wakeReason: reason,
      ),
    );
  }

  bool _evaluateCompletedCloseSegment() {
    final segment = _closeSegments.takeSegment();
    if (segment == null) return false;
    final start = segment.$1 - (_totalSamples - _recent.length);
    final end = segment.$2 - (_totalSamples - _recent.length);
    if (start < 0 || end > _recent.length || start >= end) return false;
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
    if (segment.$4 && segment.$3 < 14) {
      // A close word is a separate command. Syllables carved out of a longer
      // utterance can score like the template but have no preceding boundary.
      reason = 'boundary';
    } else if (meanLength > 0 &&
        length >= math.max(3520, meanLength * 0.30) &&
        length <= math.min(16000 * 2.4, meanLength * 1.65)) {
      final candidate = KeywordTemplate.fromAudio(
        _segmentAudio(start, end),
        minActiveSamples: 1600,
      );
      if (candidate != null) {
        close = _distanceTo(candidate, closeTemplates);
        wake = _distanceTo(candidate, wakeTemplates);
        negative = _distanceTo(candidate, closeNegatives);
        // Several hard negatives justify a little more timing/noise headroom.
        // With only one negative, keep the stricter threshold from enrollment.
        final threshold = closeNegatives.length >= 3
            ? math.min(1.10, closeThreshold + 0.05)
            : math.min(1.06, closeThreshold + 0.03);
        if (close >= threshold) {
          reason = 'score';
        } else if (wake + 0.03 < close) {
          reason = 'wake_word';
        } else if (negative <=
            close + (closeNegatives.length == 1 ? 0.025 : 0)) {
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
        closeSegmentAgeMs: (_totalSamples - segment.$2) * 1000 ~/ 16000,
        closePrecedingQuietMs: segment.$3 * 20,
        closeReason: reason,
      ),
    );
    return true;
  }

  double _distanceTo(
    KeywordTemplate candidate,
    List<KeywordTemplate> templates, {
    double? maxEndingDistance,
  }) {
    var best = double.infinity;
    for (final template in templates) {
      if (maxEndingDistance != null &&
          keywordEndingDistance(candidate, template) >= maxEndingDistance) {
        continue;
      }
      best = math.min(best, keywordDistance(candidate, template));
    }
    return best;
  }

  Float32List _segmentAudio(int start, int end) => Float32List.sublistView(
    _recent,
    math.max(0, start - 960),
    math.min(_recent.length, end + 960),
  );

  bool _recentWordBoundary() {
    const frame = 320;
    final count = _recent.length ~/ frame;
    if (count < 8) return false;
    final levels = <double>[];
    for (var i = 0; i < count; i++) {
      var power = 0.0;
      for (var j = i * frame; j < (i + 1) * frame; j++) {
        power += _recent[j] * _recent[j];
      }
      levels.add(math.sqrt(power / frame));
    }
    final sorted = [...levels]..sort();
    final noise = sorted[count ~/ 4];
    final recent = levels.skip(math.max(0, count - 30)).toList();
    final peak = recent.reduce(math.max);
    if (peak < math.max(0.004, noise * 5)) return false;
    final gate = math.max(noise * 2.8, peak * 0.30);
    return levels.skip(count - 4).every((level) => level < gate);
  }

  /// Estimate the local room floor, then find a complete utterance. A fixed
  /// amplitude gate cut quiet words into fragments on the user's recordings.
  (int, int)? _lastCompletedSpeechSegment({
    int trailingQuietFrames = 9,
    int bridgeFrames = 6,
  }) {
    const frame = 320;
    final count = _recent.length ~/ frame;
    if (count < 18) return null;
    final levels = List<double>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      var power = 0.0;
      final start = i * frame;
      for (var j = start; j < start + frame; j++) {
        power += _recent[j] * _recent[j];
      }
      levels[i] = math.sqrt(power / frame);
    }
    final sorted = [...levels]..sort();
    final noise = sorted[count ~/ 4];
    final gate = math.max(0.0008, noise * 2.8);
    final active = List<bool>.filled(count, false);
    for (var i = 0; i < count; i++) {
      active[i] = levels[i] > gate;
    }
    // Remove clicks before bridging gaps; otherwise a click 80 ms before a
    // word is merged into its onset and revokes the required leading pause.
    void removeShortBursts() {
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
    }

    removeShortBursts();
    // Bridge brief unvoiced phonemes inside one word, not inter-word pauses.
    var previousActive = -1;
    for (var i = 0; i < count; i++) {
      if (!active[i]) continue;
      if (previousActive >= 0 && i - previousActive <= bridgeFrames) {
        for (var j = previousActive + 1; j < i; j++) {
          active[j] = true;
        }
      }
      previousActive = i;
    }
    removeShortBursts();
    int? start;
    (int, int)? latest;
    for (var i = 0; i <= count; i++) {
      final speech = i < count && active[i];
      if (speech && start == null) start = i;
      if (!speech && start != null) {
        final isolatedStart =
            start >= 6 &&
            !active.getRange(start - 6, start).any((frame) => frame);
        final peak = levels.getRange(start, i).reduce(math.max);
        if (isolatedStart &&
            i <= count - trailingQuietFrames &&
            count - i <= 25 &&
            i - start >= 9 &&
            peak > math.max(0.003, noise * 5) &&
            _hasVoicedFrames(start * frame, i * frame)) {
          latest = (start * frame, i * frame);
        }
        start = null;
      }
    }
    return latest;
  }

  bool _hasVoicedFrames(int start, int end) {
    var voiced = 0;
    for (var at = start; at + 400 < end; at += 640) {
      var energy = 0.0;
      for (var j = 0; j < 400; j++) {
        final sample = _recent[at + j];
        energy += sample * sample;
      }
      if (energy < 0.002) continue;
      var strongest = 0.0;
      for (var lag = 40; lag <= 200; lag += 4) {
        var dot = 0.0;
        var left = 0.0;
        var right = 0.0;
        for (var j = 0; j < 400 - lag; j++) {
          final a = _recent[at + j];
          final b = _recent[at + j + lag];
          dot += a * b;
          left += a * a;
          right += b * b;
        }
        final correlation = dot / math.sqrt(left * right + 1e-12);
        strongest = math.max(strongest, correlation);
      }
      if (strongest >= 0.52 && ++voiced >= 2) return true;
    }
    return false;
  }

  double _bestDistance(
    List<KeywordTemplate> templates, {
    double? maxEndingDistance,
  }) {
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
          if (maxEndingDistance != null &&
              keywordEndingDistance(candidate, template) >= maxEndingDistance) {
            continue;
          }
          best = math.min(best, keywordDistance(candidate, template));
        }
      }
    }
    return best;
  }
}

/// Makes one irrevocable boundary decision per 20 ms frame. Re-scanning a
/// rolling buffer changed old segment endpoints as its noise quantile moved,
/// so a word from over a second ago could be accepted during the next word.
class _StreamingSpeechSegments {
  static const frameSamples = 320;
  final _frame = Float32List(frameSamples);
  final _levels = <double>[];
  final _completed = <(int, int, int, bool)>[];
  int _frameFill = 0;
  int _processedSamples = 0;
  int? _start;
  int _lastActiveEnd = 0;
  int _quietFrames = 0;
  int _leadingQuietFrames = 0;
  int? _candidateStart;
  int _candidateActiveFrames = 0;
  int _candidateQuietFrames = 0;
  int _segmentLeadingQuietFrames = 0;
  bool _hasPriorSpeech = false;
  bool _segmentHasPriorSpeech = false;

  void reset() {
    _frameFill = 0;
    _processedSamples = 0;
    _levels.clear();
    _completed.clear();
    _start = null;
    _lastActiveEnd = 0;
    _quietFrames = 0;
    _leadingQuietFrames = 0;
    _candidateStart = null;
    _candidateActiveFrames = 0;
    _candidateQuietFrames = 0;
    _segmentLeadingQuietFrames = 0;
    _hasPriorSpeech = false;
    _segmentHasPriorSpeech = false;
  }

  void acceptAudio(Float32List audio) {
    for (final sample in audio) {
      _frame[_frameFill++] = sample;
      if (_frameFill == frameSamples) {
        _acceptFrame();
        _frameFill = 0;
      }
    }
  }

  (int, int, int, bool)? takeSegment() =>
      _completed.isEmpty ? null : _completed.removeAt(0);

  void _acceptFrame() {
    var power = 0.0;
    for (final sample in _frame) {
      power += sample * sample;
    }
    final level = math.sqrt(power / frameSamples);
    final sorted = [..._levels]..sort();
    final noise = sorted.isEmpty ? 0.001 : sorted[sorted.length ~/ 4];
    final gate = math.max(0.0015, noise * 2.1);
    final active = level >= gate;
    final frameStart = _processedSamples;
    _processedSamples += frameSamples;

    if (_start == null) {
      if (active) {
        if (_candidateStart == null) {
          _candidateStart = frameStart;
          _candidateActiveFrames = 0;
        }
        _candidateActiveFrames++;
        _candidateQuietFrames = 0;
        if (_candidateActiveFrames >= 4 && _leadingQuietFrames >= 5) {
          _start = _candidateStart;
          _segmentLeadingQuietFrames = _leadingQuietFrames;
          _segmentHasPriorSpeech = _hasPriorSpeech;
          _lastActiveEnd = _processedSamples;
          _quietFrames = 0;
          _candidateStart = null;
          _candidateActiveFrames = 0;
        }
      } else {
        if (_candidateStart == null) {
          _leadingQuietFrames++;
        } else if (++_candidateQuietFrames >= 4) {
          // A brief isolated burst is noise, not the onset of a word.
          _leadingQuietFrames += _candidateActiveFrames + _candidateQuietFrames;
          _candidateStart = null;
          _candidateActiveFrames = 0;
          _candidateQuietFrames = 0;
        }
      }
    } else if (active) {
      _lastActiveEnd = _processedSamples;
      _quietFrames = 0;
    } else if (++_quietFrames >= 9) {
      final start = _start!;
      final end = _lastActiveEnd;
      if (end - start >= 2880 && end - start <= 16000 * 2) {
        _completed.add((
          start,
          end,
          _segmentLeadingQuietFrames,
          _segmentHasPriorSpeech,
        ));
      }
      _hasPriorSpeech = true;
      _start = null;
      _leadingQuietFrames = _quietFrames;
      _quietFrames = 0;
    }

    _levels.add(level);
    if (_levels.length > 150) _levels.removeAt(0);
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
    this.closeSegmentAgeMs,
    this.closePrecedingQuietMs,
    this.closeReason,
    this.wakeSegmentMs,
    this.wakeReason,
  });

  final double wake;
  final double close;
  final double wakeNegative;
  final double closeNegative;
  final double wakeThreshold;
  final double closeThreshold;
  final String? candidate;
  final int? closeSegmentMs;
  final int? closeSegmentAgeMs;
  final int? closePrecedingQuietMs;
  final String? closeReason;
  final int? wakeSegmentMs;
  final String? wakeReason;

  Map<String, Object?> toJson() => {
    'wake': wake.isFinite ? wake : null,
    'close': close.isFinite ? close : null,
    'wakeNegative': wakeNegative.isFinite ? wakeNegative : null,
    'closeNegative': closeNegative.isFinite ? closeNegative : null,
    'wakeThreshold': wakeThreshold,
    'closeThreshold': closeThreshold,
    'candidate': candidate,
    if (closeSegmentMs != null) 'closeSegmentMs': closeSegmentMs,
    if (closeSegmentAgeMs != null) 'closeSegmentAgeMs': closeSegmentAgeMs,
    if (closePrecedingQuietMs != null)
      'closePrecedingQuietMs': closePrecedingQuietMs,
    if (closeReason != null) 'closeReason': closeReason,
    if (wakeSegmentMs != null) 'wakeSegmentMs': wakeSegmentMs,
    if (wakeReason != null) 'wakeReason': wakeReason,
  };
}
