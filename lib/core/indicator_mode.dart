/// Recording appearance; the microphone and transcription queue are independent.
enum IndicatorMode {
  panel,
  status,
  timer,
  off;

  static IndicatorMode fromValue(Object? value, {bool legacyHud = true}) =>
      values.where((mode) => mode.name == value).firstOrNull ??
      (legacyHud ? panel : off);

  IndicatorMode cycle(int direction) =>
      values[(index + direction) % values.length];
}
