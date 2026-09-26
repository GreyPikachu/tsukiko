import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/wakeword/audio_stream_source.dart';
import '../../../core/wakeword/sherpa_engine.dart';
import '../../../core/wakeword/speaker_profile.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Состояние отдельного шага калибровки.
enum CalibrationPhase {
  idle,
  recording,
  processing,
  stepCompleted,
  allCompleted,
  failed,
}

/// Мастер калибровки голоса пользователя (Voiceprint Enrollment Wizard).
///
/// Записывает 3 контрольных образца ключевого слова активации, извлекает
/// эмбеддинги через `SherpaEngine.extractSpeakerEmbedding` и сохраняет
/// профиль `SpeakerProfile` на диск.
class VoiceCalibrationSheet extends StatefulWidget {
  const VoiceCalibrationSheet({
    super.key,
    required this.wakeWord,
    this.audioSource,
    this.engine,
    this.onProfileCreated,
  });

  final String wakeWord;
  final AudioStreamSource? audioSource;
  final SherpaEngine? engine;
  final VoidCallback? onProfileCreated;

  static Future<bool?> show(
    BuildContext context, {
    required String wakeWord,
    AudioStreamSource? audioSource,
    SherpaEngine? engine,
    VoidCallback? onProfileCreated,
  }) =>
      showMacosSheet<bool>(
        context: context,
        barrierDismissible: false,
        builder: (sheetContext) => VoiceCalibrationSheet(
          wakeWord: wakeWord,
          audioSource: audioSource,
          engine: engine,
          onProfileCreated: onProfileCreated,
        ),
      );

  @override
  State<VoiceCalibrationSheet> createState() => _VoiceCalibrationSheetState();
}

class _VoiceCalibrationSheetState extends State<VoiceCalibrationSheet>
    with SingleTickerProviderStateMixin {
  late final AudioStreamSource _audioSource;
  late final SherpaEngine _engine;

  int _currentStep = 0; // 0, 1, 2
  static const int _totalSteps = 3;

  CalibrationPhase _phase = CalibrationPhase.idle;
  String? _errorMessage;

  final List<Float32List> _collectedEmbeddings = [];
  final List<Float32List> _recordedAudioBuffer = [];
  StreamSubscription<Float32List>? _audioSub;

  double _audioLevel = 0.0;
  Timer? _levelDecayTimer;

  @override
  void initState() {
    super.initState();
    _audioSource = widget.audioSource ?? MicrophoneAudioStreamSource();
    _engine = widget.engine ?? NativeSherpaEngine();
  }

  @override
  void dispose() {
    _stopRecordingStream();
    _levelDecayTimer?.cancel();
    super.dispose();
  }

  Future<void> _stopRecordingStream() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _audioSource.stopStream();
  }

  Future<void> _startRecording() async {
    setState(() {
      _phase = CalibrationPhase.recording;
      _errorMessage = null;
      _audioLevel = 0.0;
      _recordedAudioBuffer.clear();
    });

    final hasPerm = await _audioSource.hasPermission();
    if (!hasPerm) {
      if (!mounted) return;
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = 'Нет разрешения на использование микрофона';
      });
      return;
    }

    try {
      final stream = await _audioSource.startStream(sampleRate: 16000);
      _audioSub = stream.listen(
        _onAudioChunk,
        onError: (Object err) {
          if (!mounted) return;
          setState(() {
            _phase = CalibrationPhase.failed;
            _errorMessage = '$err';
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = '$e';
      });
    }
  }

  void _onAudioChunk(Float32List chunk) {
    if (_phase != CalibrationPhase.recording || chunk.isEmpty) return;

    _recordedAudioBuffer.add(Float32List.fromList(chunk));

    // Считаем громкость RMS для визуализатора
    double sum = 0.0;
    for (var i = 0; i < chunk.length; i++) {
      sum += chunk[i] * chunk[i];
    }
    final rms = math.sqrt(sum / chunk.length);
    // Нормализация 0.0 - 1.0 с нелинейным усилением чувствительности
    final targetLevel = (rms * 8.0).clamp(0.0, 1.0);

    setState(() {
      _audioLevel = _audioLevel * 0.4 + targetLevel * 0.6;
    });
  }

  Future<void> _stopRecordingAndProcess() async {
    await _stopRecordingStream();

    setState(() {
      _phase = CalibrationPhase.processing;
      _audioLevel = 0.0;
    });

    // Объединяем все записанные сэмплы
    final totalSamples =
        _recordedAudioBuffer.fold<int>(0, (sum, list) => sum + list.length);

    if (totalSamples < 16000 * 0.5) {
      // Слишком короткая запись (< 0.5 секунды)
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = l10n.calibrationSampleFailed;
      });
      return;
    }

    final combinedAudio = Float32List(totalSamples);
    var offset = 0;
    for (final buf in _recordedAudioBuffer) {
      combinedAudio.setRange(offset, offset + buf.length, buf);
      offset += buf.length;
    }

    // Извлекаем эмбеддинг спикера
    final embedding = _engine.extractSpeakerEmbedding(combinedAudio);

    if (embedding == null || embedding.isEmpty) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = l10n.calibrationSampleFailed;
      });
      return;
    }

    _collectedEmbeddings.add(embedding);

    if (_currentStep + 1 < _totalSteps) {
      setState(() {
        _phase = CalibrationPhase.stepCompleted;
      });
      // Плавный переход на следующий шаг через полсекунды
      Future.delayed(const Duration(milliseconds: 650), () {
        if (!mounted) return;
        setState(() {
          _currentStep++;
          _phase = CalibrationPhase.idle;
          _recordedAudioBuffer.clear();
        });
      });
    } else {
      // Все 3 шага завершены! Сохраняем профиль
      _finishAndSaveProfile();
    }
  }

  void _finishAndSaveProfile() {
    final profile = SpeakerProfile(
      name: 'user',
      dimension: _collectedEmbeddings.first.length,
      embeddings: _collectedEmbeddings,
      createdAt: DateTime.now(),
    );
    profile.save();

    widget.onProfileCreated?.call();

    if (!mounted) return;
    setState(() {
      _phase = CalibrationPhase.allCompleted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return MacosSheet(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 480,
          minWidth: 420,
          maxHeight: 520,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gap.section),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Шапка
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: MacosTheme.of(context).primaryColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: MacosIcon(
                        _phase == CalibrationPhase.allCompleted
                            ? CupertinoIcons.checkmark_seal_fill
                            : CupertinoIcons.waveform,
                        color: MacosTheme.of(context).primaryColor,
                        size: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.item),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.calibrationWizardTitle,
                          style: Type.emptyTitle,
                        ),
                        const SizedBox(height: Gap.hint),
                        Text(
                          l10n.calibrationWizardSubtitle,
                          style: Type.caption.copyWith(
                            color: MacosTheme.brightnessOf(context) == Brightness.dark
                                ? const Color(0xFF9E9E9E)
                                : const Color(0xFF757575),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.section),

              // Индикатор шагов (1, 2, 3)
              if (_phase != CalibrationPhase.allCompleted) ...[
                Row(
                  children: [
                    for (int i = 0; i < _totalSteps; i++) ...[
                      if (i > 0)
                        Expanded(
                          child: Container(
                            height: 2,
                            color: i <= _currentStep
                                ? MacosTheme.of(context).primaryColor
                                : (MacosTheme.brightnessOf(context) == Brightness.dark
                                    ? const Color(0xFF3A3A3C)
                                    : const Color(0xFFE5E5EA)),
                          ),
                        ),
                      AnimatedContainer(
                        duration: Motion.quick,
                        curve: Motion.quickCurve,
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: i < _currentStep
                              ? MacosTheme.of(context).primaryColor
                              : (i == _currentStep
                                  ? MacosTheme.of(context).primaryColor
                                  : (MacosTheme.brightnessOf(context) == Brightness.dark
                                      ? const Color(0xFF2C2C2E)
                                      : const Color(0xFFF2F2F7))),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: i <= _currentStep
                                ? MacosTheme.of(context).primaryColor
                                : (MacosTheme.brightnessOf(context) == Brightness.dark
                                    ? const Color(0xFF3A3A3C)
                                    : const Color(0xFFD1D1D6)),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: i < _currentStep
                              ? const MacosIcon(
                                  CupertinoIcons.checkmark,
                                  size: 12,
                                  color: Color(0xFFFFFFFF),
                                )
                              : Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: i == _currentStep
                                        ? const Color(0xFFFFFFFF)
                                        : (MacosTheme.brightnessOf(context) == Brightness.dark
                                            ? const Color(0xFF8E8E93)
                                            : const Color(0xFF636366)),
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Gap.item),
              ],

              // Основное содержимое текущего шага
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.settle,
                  switchInCurve: Motion.settleCurve,
                  switchOutCurve: Curves.easeOut,
                  child: _phase == CalibrationPhase.allCompleted
                      ? _buildCompletedContent(l10n)
                      : _buildStepContent(l10n),
                ),
              ),

              const SizedBox(height: Gap.section),

              // Кнопки управления внизу
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_phase != CalibrationPhase.allCompleted) ...[
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () {
                        _stopRecordingStream();
                        Navigator.of(context).pop(false);
                      },
                      child: Text(l10n.buttonCancel),
                    ),
                    const SizedBox(width: Gap.control),
                    if (_phase == CalibrationPhase.recording)
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: _stopRecordingAndProcess,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const MacosIcon(
                              CupertinoIcons.stop_fill,
                              size: 14,
                              color: Color(0xFFFFFFFF),
                            ),
                            const SizedBox(width: Gap.inner),
                            Text(l10n.calibrationButtonStop),
                          ],
                        ),
                      )
                    else if (_phase == CalibrationPhase.processing)
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: null,
                        child: Text(l10n.calibrationProcessing),
                      )
                    else
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: _startRecording,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const MacosIcon(
                              CupertinoIcons.mic_fill,
                              size: 14,
                              color: Color(0xFFFFFFFF),
                            ),
                            const SizedBox(width: Gap.inner),
                            Text(l10n.calibrationButtonRecord),
                          ],
                        ),
                      ),
                  ] else ...[
                    PushButton(
                      controlSize: ControlSize.large,
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(l10n.buttonDone),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepContent(AppLocalizations l10n) {
    final title = switch (_currentStep) {
      0 => l10n.calibrationStep1Title,
      1 => l10n.calibrationStep2Title,
      _ => l10n.calibrationStep3Title,
    };

    final prompt = switch (_currentStep) {
      0 => l10n.calibrationStep1Prompt,
      1 => l10n.calibrationStep2Prompt,
      _ => l10n.calibrationStep3Prompt,
    };

    return Container(
      key: ValueKey<int>(_currentStep),
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: MacosTheme.brightnessOf(context) == Brightness.dark
            ? const Color(0xFF1E1E1E)
            : const Color(0xFFF9F9FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: MacosTheme.brightnessOf(context) == Brightness.dark
              ? const Color(0xFF333333)
              : const Color(0xFFE5E5EA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: Type.navTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.inner),
          Text(
            prompt,
            style: Type.body.copyWith(
              color: MacosTheme.brightnessOf(context) == Brightness.dark
                  ? const Color(0xFFB0B0B0)
                  : const Color(0xFF555555),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.item),

          // Фраза активации в плашке
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.item,
                vertical: Gap.inner,
              ),
              decoration: BoxDecoration(
                color: MacosTheme.of(context).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: MacosTheme.of(context).primaryColor.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                '«${widget.wakeWord}»',
                style: Type.emptyTitle.copyWith(
                  color: MacosTheme.of(context).primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.item),

          // Индикатор уровня звука и состояния
          Center(
            child: _buildAudioMeter(l10n),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioMeter(AppLocalizations l10n) {
    if (_phase == CalibrationPhase.recording) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            height: 36,
            child: CustomPaint(
              painter: _AudioWavePainter(
                level: _audioLevel,
                color: MacosTheme.of(context).primaryColor,
              ),
            ),
          ),
          const SizedBox(height: Gap.hint),
          Text(
            l10n.calibrationRecordingInProgress,
            style: Type.caption.copyWith(
              color: MacosTheme.of(context).primaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    if (_phase == CalibrationPhase.processing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(radius: 12),
          const SizedBox(height: Gap.inner),
          Text(
            l10n.calibrationProcessing,
            style: Type.caption,
          ),
        ],
      );
    }

    if (_phase == CalibrationPhase.stepCompleted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(
            CupertinoIcons.checkmark_circle_fill,
            color: Color(0xFF34C759),
            size: 20,
          ),
          const SizedBox(width: Gap.inner),
          Text(
            l10n.calibrationSampleAccepted,
            style: Type.control.copyWith(
              color: const Color(0xFF34C759),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (_phase == CalibrationPhase.failed && _errorMessage != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_circle_fill,
            color: Color(0xFFFF3B30),
            size: 18,
          ),
          const SizedBox(width: Gap.inner),
          Flexible(
            child: Text(
              _errorMessage!,
              style: Type.caption.copyWith(
                color: const Color(0xFFFF3B30),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return Text(
      'Нажмите «Начать запись» и произнесите фразу',
      style: Type.caption.copyWith(
        color: MacosTheme.brightnessOf(context) == Brightness.dark
            ? const Color(0xFF757575)
            : const Color(0xFF9E9E9E),
      ),
    );
  }

  Widget _buildCompletedContent(AppLocalizations l10n) {
    return Container(
      key: const ValueKey<String>('completed'),
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF34C759).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const MacosIcon(
            CupertinoIcons.checkmark_circle_fill,
            color: Color(0xFF34C759),
            size: 48,
          ),
          const SizedBox(height: Gap.item),
          Text(
            l10n.calibrationCompletedTitle,
            style: Type.emptyTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.inner),
          Text(
            l10n.calibrationCompletedBody,
            style: Type.body.copyWith(
              color: MacosTheme.brightnessOf(context) == Brightness.dark
                  ? const Color(0xFFD0D0D0)
                  : const Color(0xFF444444),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Визуализатор звуковых волн микрофона на базе Canvas.
class _AudioWavePainter extends CustomPainter {
  const _AudioWavePainter({
    required this.level,
    required this.color,
  });

  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 19;
    final barWidth = size.width / (barCount * 2);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.fill;

    final centerY = size.height / 2;

    for (var i = 0; i < barCount; i++) {
      final x = i * (barWidth * 2) + barWidth;
      // Волнообразное распределение вокруг центра
      final distFromCenter = ((i - barCount / 2).abs()) / (barCount / 2);
      final envelope = 1.0 - distFromCenter * 0.6;
      final currentBarLevel = (level * envelope).clamp(0.08, 1.0);
      final barHeight = math.max(4.0, size.height * currentBarLevel * 0.9);

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centerY),
          width: barWidth,
          height: barHeight,
        ),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AudioWavePainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.color != color;
}
