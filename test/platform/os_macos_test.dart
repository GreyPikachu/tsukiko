import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_macos.dart';

/// Заголовок WAV, каким afconvert пишет его из Opus: fmt в 40 байт
/// с меткой 0xFFFE и подформатом PCM.
List<int> _extensibleHeader({int subformat = 1}) => [
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WAVE'.codeUnits,
  ...'fmt '.codeUnits,
  40,
  0,
  0,
  0,
  0xFE,
  0xFF,
  1,
  0,
  0x80,
  0x3E,
  0,
  0,
  0,
  0x7D,
  0,
  0,
  2,
  0,
  16,
  0,
  22,
  0,
  16,
  0,
  4,
  0,
  0,
  0,
  subformat,
  0,
  0,
  0,
  0,
  0,
  0x10,
  0,
  0x80,
  0,
  0,
  0xAA,
  0,
  0x38,
  0x9B,
  0x71,
  ...'data'.codeUnits,
  4,
  0,
  0,
  0,
  1,
  2,
  3,
  4,
];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wav-tag'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('метка EXTENSIBLE с PCM внутри становится обычным PCM', () {
    final f = File('${dir.path}/a.wav')..writeAsBytesSync(_extensibleHeader());
    plainPcmTag(f.path);
    final bytes = f.readAsBytesSync();
    expect(bytes.sublist(20, 22), [1, 0]);
    // Больше ничего не тронуто: ни звук, ни длина.
    final expected = _extensibleHeader()..setRange(20, 22, [1, 0]);
    expect(bytes, expected);
  });

  test('чужой подформат и обычный PCM не трогаются', () {
    final float = _extensibleHeader(subformat: 3);
    final f = File('${dir.path}/b.wav')..writeAsBytesSync(float);
    plainPcmTag(f.path);
    expect(f.readAsBytesSync(), float);

    final plain = _extensibleHeader()..setRange(20, 22, [1, 0]);
    final g = File('${dir.path}/c.wav')..writeAsBytesSync(plain);
    plainPcmTag(g.path);
    expect(g.readAsBytesSync(), plain);
  });
}
