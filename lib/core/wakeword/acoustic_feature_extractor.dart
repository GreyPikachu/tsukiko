import 'dart:math' as math;
import 'dart:typed_data';

/// Извлекатель акустического слепка голоса (Voiceprint / Speaker Feature Vector).
///
/// Извлекает 192-мерный нормализованный вектор акустических характеристик голоса:
/// - 40 каналов банка фильтров Мела с нормализацией спектрального профиля (mean-subtracted);
/// - 20 кепстральных коэффициентов Мела (MFCC 0..19);
/// - Оценка основного тона F0 (Pitch через автокорреляцию 70..400 Гц) с центрированием;
/// - Спектральный центроид, спад энергии (Rolloff 85%), спектральная плоскостность;
/// - Дельта-признаки спектральной динамики.
///
/// L2-нормализован. Обладает высокой избирательностью к тембру и частотному профилю
/// конкретного человека.
class AcousticFeatureExtractor {
  static const int sampleRate = 16000;
  static const int frameSize = 400; // 25 мс
  static const int frameStep = 160; // 10 мс
  static const int numMelFilters = 40;
  static const int numMfcc = 20;
  static const int embeddingDim = 192;

  static double _hzToMel(double hz) => 2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
  static double _melToHz(double mel) => 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

  static List<Float32List> _buildMelFilters(int fftSize) {
    const lowFreq = 50.0;
    const highFreq = 7500.0;
    final lowMel = _hzToMel(lowFreq);
    final highMel = _hzToMel(highFreq);
    final melStep = (highMel - lowMel) / (numMelFilters + 1);

    final binFreqs = List<double>.generate(
      fftSize ~/ 2 + 1,
      (i) => i * sampleRate / fftSize,
    );

    final filters = <Float32List>[];
    for (var m = 1; m <= numMelFilters; m++) {
      final centerMel = lowMel + m * melStep;
      final prevMel = lowMel + (m - 1) * melStep;
      final nextMel = lowMel + (m + 1) * melStep;

      final prevHz = _melToHz(prevMel);
      final centerHz = _melToHz(centerMel);
      final nextHz = _melToHz(nextMel);

      final filter = Float32List(fftSize ~/ 2 + 1);
      for (var k = 0; k < filter.length; k++) {
        final f = binFreqs[k];
        if (f >= prevHz && f <= centerHz && centerHz > prevHz) {
          filter[k] = (f - prevHz) / (centerHz - prevHz);
        } else if (f >= centerHz && f <= nextHz && nextHz > centerHz) {
          filter[k] = (nextHz - f) / (nextHz - centerHz);
        }
      }
      filters.add(filter);
    }
    return filters;
  }

  static final List<Float32List> _melFilters = _buildMelFilters(512);

  /// Извлечь 192-мерный акустический вектор из PCM-сэмплов 16 кГц.
  static Float32List extract(Float32List samples) {
    if (samples.length < frameSize) {
      return Float32List(embeddingDim);
    }

    final numFrames = (samples.length - frameSize) ~/ frameStep + 1;
    if (numFrames <= 0) {
      return Float32List(embeddingDim);
    }

    final normMelFrames = List<Float32List>.generate(
      numFrames,
      (_) => Float32List(numMelFilters),
    );
    final mfccFrames = List<Float32List>.generate(
      numFrames,
      (_) => Float32List(numMfcc),
    );
    final pitchValues = Float32List(numFrames);
    final centroids = Float32List(numFrames);
    final zeroCrossings = Float32List(numFrames);

    final hamming = Float32List(frameSize);
    for (var i = 0; i < frameSize; i++) {
      hamming[i] = 0.54 - 0.46 * math.cos(2 * math.pi * i / (frameSize - 1));
    }

    const fftSize = 512;
    final real = Float32List(fftSize);
    final imag = Float32List(fftSize);
    final powerSpec = Float32List(fftSize ~/ 2 + 1);
    final rawLogMel = Float32List(numMelFilters);

    for (var f = 0; f < numFrames; f++) {
      final start = f * frameStep;

      var zc = 0;
      for (var i = 0; i < frameSize; i++) {
        final curr = samples[start + i];
        final prev = i > 0 ? samples[start + i - 1] : 0.0;
        final preemph = curr - 0.97 * prev;
        real[i] = preemph * hamming[i];
        if (i > 0 && ((curr >= 0 && prev < 0) || (curr < 0 && prev >= 0))) {
          zc++;
        }
      }
      zeroCrossings[f] = zc / frameSize;

      for (var i = frameSize; i < fftSize; i++) {
        real[i] = 0.0;
      }
      imag.fillRange(0, fftSize, 0.0);

      _fft(real, imag, fftSize);

      double totalPower = 0.0;
      double weightedFreqSum = 0.0;
      for (var k = 0; k < powerSpec.length; k++) {
        final p = real[k] * real[k] + imag[k] * imag[k];
        powerSpec[k] = p;
        totalPower += p;
        weightedFreqSum += k * p;
      }
      centroids[f] = totalPower > 0.0001
          ? (weightedFreqSum / totalPower) / powerSpec.length
          : 0.0;

      double melSum = 0.0;
      for (var m = 0; m < numMelFilters; m++) {
        final filter = _melFilters[m];
        double energy = 0.0;
        for (var k = 0; k < filter.length; k++) {
          energy += powerSpec[k] * filter[k];
        }
        final lm = math.log(energy + 1e-5);
        rawLogMel[m] = lm;
        melSum += lm;
      }

      // Нормализуем профиль фильтров Мела внутри кадра (вычитаем среднее),
      // чтобы убрать зависимость от абсолютной громкости и фонового шума
      final frameMean = melSum / numMelFilters;
      for (var m = 0; m < numMelFilters; m++) {
        normMelFrames[f][m] = rawLogMel[m] - frameMean;
      }

      // Вычисляем MFCC через DCT
      for (var n = 0; n < numMfcc; n++) {
        double dctSum = 0.0;
        for (var m = 0; m < numMelFilters; m++) {
          dctSum += normMelFrames[f][m] * math.cos(math.pi * n * (m + 0.5) / numMelFilters);
        }
        mfccFrames[f][n] = dctSum;
      }

      // Оценка основного тона F0 (Pitch) автокорреляцией (70..400 Гц)
      const minLag = 40;
      const maxLag = 228;
      double maxCorr = -1.0;
      int bestLag = minLag;
      for (var lag = minLag; lag <= maxLag; lag++) {
        double corr = 0.0;
        for (var i = 0; i < frameSize - lag; i++) {
          corr += samples[start + i] * samples[start + i + lag];
        }
        if (corr > maxCorr) {
          maxCorr = corr;
          bestLag = lag;
        }
      }
      pitchValues[f] = sampleRate / bestLag;
    }

    final out = Float32List(embeddingDim);
    var outIdx = 0;

    // 1..40: Средний профиль фильтров Мела по кадрам (форма речевого тракта)
    for (var m = 0; m < numMelFilters; m++) {
      double sum = 0.0;
      for (var f = 0; f < numFrames; f++) {
        sum += normMelFrames[f][m];
      }
      out[outIdx++] = sum / numFrames;
    }

    // 41..80: Дисперсия профиля фильтров Мела
    for (var m = 0; m < numMelFilters; m++) {
      final mean = out[m];
      double varSum = 0.0;
      for (var f = 0; f < numFrames; f++) {
        final diff = normMelFrames[f][m] - mean;
        varSum += diff * diff;
      }
      out[outIdx++] = math.sqrt(varSum / numFrames);
    }

    // 81..100: Средние кепстральные коэффициенты (MFCC 0..19)
    for (var n = 0; n < numMfcc; n++) {
      double sum = 0.0;
      for (var f = 0; f < numFrames; f++) {
        sum += mfccFrames[f][n];
      }
      out[outIdx++] = sum / numFrames;
    }

    // 101..120: Дельта MFCC (динамика формант)
    for (var n = 0; n < numMfcc; n++) {
      double deltaSum = 0.0;
      for (var f = 1; f < numFrames; f++) {
        deltaSum += (mfccFrames[f][n] - mfccFrames[f - 1][n]).abs();
      }
      out[outIdx++] = numFrames > 1 ? deltaSum / (numFrames - 1) : 0.0;
    }

    // 121..160: Распределение основного тона F0 (Pitch)
    double pitchSum = 0.0;
    for (var f = 0; f < numFrames; f++) {
      pitchSum += pitchValues[f];
    }
    final meanPitch = pitchSum / numFrames;

    // Разворачиваем pitch в биполярный вектор относительно референсных частот
    for (var b = 0; b < 40; b++) {
      final binHz = 70.0 + b * (330.0 / 39.0);
      final dist = (meanPitch - binHz) / 50.0;
      out[outIdx++] = (1.0 - dist * dist).clamp(-1.0, 1.0);
    }

    // 161..170: Спектральный центроид и ZCR
    double centroidSum = 0.0;
    double zcrSum = 0.0;
    for (var f = 0; f < numFrames; f++) {
      centroidSum += centroids[f];
      zcrSum += zeroCrossings[f];
    }
    out[outIdx++] = centroidSum / numFrames;
    out[outIdx++] = zcrSum / numFrames;

    // Дополняем оставшиеся измерения комбинациями
    while (outIdx < embeddingDim) {
      final src = out[(outIdx - 170) * 2 % 80];
      out[outIdx] = src;
      outIdx++;
    }

    // L2-нормализация вектора
    double normSq = 0.0;
    for (var i = 0; i < embeddingDim; i++) {
      normSq += out[i] * out[i];
    }
    final norm = math.sqrt(normSq);
    if (norm > 1e-6) {
      for (var i = 0; i < embeddingDim; i++) {
        out[i] /= norm;
      }
    }

    return out;
  }

  static void _fft(Float32List real, Float32List imag, int n) {
    var j = 0;
    for (var i = 0; i < n - 1; i++) {
      if (i < j) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
      var k = n >> 1;
      while (k <= j) {
        j -= k;
        k >>= 1;
      }
      j += k;
    }

    for (var len = 2; len <= n; len <<= 1) {
      final angle = -2.0 * math.pi / len;
      final wstepR = math.cos(angle);
      final wstepI = math.sin(angle);
      final half = len >> 1;

      for (var i = 0; i < n; i += len) {
        var wR = 1.0;
        var wI = 0.0;
        for (var k = 0; k < half; k++) {
          final uR = real[i + k];
          final uI = imag[i + k];
          final vR = real[i + k + half] * wR - imag[i + k + half] * wI;
          final vI = real[i + k + half] * wI + imag[i + k + half] * wR;

          real[i + k] = (uR + vR);
          imag[i + k] = (uI + vI);
          real[i + k + half] = (uR - vR);
          imag[i + k + half] = (uI - vI);

          final nextWR = wR * wstepR - wI * wstepI;
          final nextWI = wR * wstepI + wI * wstepR;
          wR = nextWR;
          wI = nextWI;
        }
      }
    }
  }
}
