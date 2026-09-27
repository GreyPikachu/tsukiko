import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';
import 'package:tsukiko/core/wakeword/wakeword_models.dart';

void main() {
  final fixture = File('${WakeWordModelPaths.kwsDir}/test_wavs/1.wav');
  test(
    'streaming KWS detects two words in one continuous recording',
    () async {
      // flutter_test does not link desktop plugin binaries into its process.
      final configFile = File('.dart_tool/package_config.json');
      final config =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final packages = config['packages'] as List<dynamic>;
      final platform = packages.cast<Map<String, dynamic>>().firstWhere(
        (entry) => entry['name'] == 'sherpa_onnx_macos',
      );
      final packageRoot = configFile.uri.resolve(platform['rootUri'] as String);
      await sherpa.initBindingsAsync('${packageRoot.toFilePath()}/macos');
      final engine = StreamingSherpaEngine();
      expect(
        await engine.initKeywordSpotter(
          wakeWord: 'LOVELY CHILD',
          closeWord: 'FOREVER',
        ),
        isTrue,
      );
      final wave = sherpa.readWave(fixture.path);
      final detected = <String>[];
      for (var start = 0; start < wave.samples.length; start += 1600) {
        final end = (start + 1600).clamp(0, wave.samples.length);
        engine.acceptAudio(Float32List.sublistView(wave.samples, start, end));
        final keyword = engine.detectKeyword()?.keyword;
        if (keyword != null) detected.add(keyword);
      }
      expect(detected, containsAllInOrder(['lovely child', 'forever']));
      engine.dispose();
    },
    skip: !WakeWordModelPaths.isKwsInstalled || !fixture.existsSync(),
  );
}
