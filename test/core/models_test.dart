import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/models.dart';
import 'package:tsukiko/platform/os.dart';

/// Список моделей: он должен быть честным. Битую или недокачанную модель
/// нельзя показывать наравне с рабочей, а две с одинаковым именем надо
/// как-то различать.
void main() {
  late Directory tmp;
  late Os real;

  setUp(() {
    real = os;
    tmp = Directory.systemTemp.createTempSync('tsukiko-models');
    os = _FakeOs(real, tmp.path);
    Directory(os.modelsDir).createSync(recursive: true);
  });

  tearDown(() {
    os = real;
    tmp.deleteSync(recursive: true);
  });

  /// Настоящая модель ggml: метка «lmgg», крупный словарь и вес больше
  /// самой маленькой из речевых.
  File model(String dir, String name, {int vocab = 51865, int mb = 74}) {
    final bytes = <int>[
      ...'lmgg'.codeUnits,
      vocab & 0xFF,
      (vocab >> 8) & 0xFF,
      (vocab >> 16) & 0xFF,
      (vocab >> 24) & 0xFF,
      ...List.filled(mb * 1024 * 1024 - 8, 0),
    ];
    Directory(dir).createSync(recursive: true);
    return File(os.join(dir, name))..writeAsBytesSync(bytes);
  }

  test('целая модель попадает в список без нареканий', () {
    model(os.modelsDir, 'ggml-tiny.bin');
    final found = scanModels();
    expect(found.length, 1);
    expect(found.single.broken, isFalse);
    expect(found.single.ours, isTrue);
    expect(found.single.sizeLabel, '74 МБ');
  });

  test('битая модель видна в списке, но помечена', () {
    File(os.join(os.modelsDir, 'ggml-огрызок.bin'))
        .writeAsBytesSync(List.filled(4096, 9));

    final found = scanModels();
    // В списке она есть — иначе человек не поймёт, куда делся файл.
    expect(found.single.broken, isTrue);
    expect(found.single.problem, isNotNull);
    // А распознавать ею нельзя: раньше это выяснялось только руганью
    // whisper про тензоры.
    expect(findModels(), isEmpty);
  });

  test('модель тишины в список моделей речи не попадает', () {
    model(os.modelsDir, 'ggml-silero-v5.1.2.bin', vocab: 10, mb: 1);
    expect(scanModels(), isEmpty);
  });

  test('одинаковые имена из разных папок различаются подписью', () {
    final ours = model(os.modelsDir, 'ggml-large-v3-turbo.bin');
    final shared =
        model(os.join(tmp.path, '.cache/whisper'), 'ggml-large-v3-turbo.bin');

    final all = [ours.path, shared.path];
    // Без этого в списке стояли две одинаковые строки «Large v3 Turbo»,
    // и какая из них выбрана, понять было нельзя.
    expect(modelLabel(ours.path, all), isNot(modelLabel(shared.path, all)));
    expect(modelLabel(ours.path, all), contains(appName));
    expect(modelLabel(shared.path, all), contains('whisper'));
  });

  test('единственное имя подписью не обрастает', () {
    final only = model(os.modelsDir, 'ggml-tiny.bin');
    expect(modelLabel(only.path, [only.path]), 'Tiny');
  });

  test('битая копия не мешает предложить скачать её заново', () {
    File(os.join(os.modelsDir, 'ggml-tiny.bin'))
        .writeAsBytesSync(List.filled(4096, 9));
    // Раньше сравнение шло по именам файлов на диске, и огрызок скрывал
    // предложение скачать целую модель.
    expect(modelOffers(findModels()).any((m) => m.file == 'ggml-tiny.bin'),
        isTrue);
  });
}

/// Подставная система: папки — во временной.
class _FakeOs implements Os {
  _FakeOs(this._real, this._root);
  final Os _real;
  final String _root;

  @override
  String get home => _root;

  @override
  String get supportDir => join(_root, 'Support');

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  List<String> get sharedModelDirs => [join(_root, '.cache/whisper')];

  @override
  String join(String a, [String? b, String? c]) => _real.join(a, b, c);

  @override
  String basename(String p) => _real.basename(p);

  @override
  String dirname(String p) => _real.dirname(p);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
