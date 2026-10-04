import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/platform/os.dart';
import '../support/fake_os.dart';

void main() {
  useTempSupportDir('tsukiko-indicator');
  test(
    'four styles survive settings round trips and cycle in both directions',
    () {
      for (final mode in IndicatorMode.values) {
        DictationSettings(indicatorMode: mode).save();
        expect(DictationSettings.load().indicatorMode, mode);
        expect(mode.cycle(1).cycle(-1), mode);
      }
      expect(IndicatorMode.off.cycle(1), IndicatorMode.panel);
      expect(IndicatorMode.panel.cycle(-1), IndicatorMode.off);
    },
  );
  test(
    'legacy visibility settings migrate without changing user preference',
    () {
      final file = File(os.join(os.supportDir, 'dictation.json'));
      file.parent.createSync(recursive: true);
      for (final visible in [true, false]) {
        file.writeAsStringSync(jsonEncode({'hud': visible}));
        expect(
          DictationSettings.load().indicatorMode,
          visible ? IndicatorMode.panel : IndicatorMode.off,
        );
      }
      file.writeAsStringSync(
        jsonEncode({'hud': false, 'indicatorMode': 'timer'}),
      );
      expect(DictationSettings.load().indicatorMode, IndicatorMode.timer);
    },
  );
  test('unknown saved style falls back to legacy visibility', () {
    expect(
      IndicatorMode.fromValue('unknown', legacyHud: false),
      IndicatorMode.off,
    );
    expect(IndicatorMode.fromValue(null), IndicatorMode.panel);
  });
}
