import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/core/whisper.dart';

void main() {
  // Ровно та потеря, из-за которой длинные записи приходили обрезанными:
  // whisper-server по умолчанию декодирует жадно, и на записи от четырёх
  // минут это стоило от 18 до 46 процентов текста. Флаги — единственное,
  // что это чинит: в самом запросе те же значения доходят лишь наполовину.
  test('сервер диктовки идёт лучом, а не жадно', () {
    final args = serverArgs(RunOptions(model: '/m.bin', lang: 'auto', threads: 4), 1234);
    expect(args, containsAllInOrder(['-bs', '5']));
    expect(args, containsAllInOrder(['-bo', '5']));
  });

  test('сервер NeMo поднимается только с ASR и остаётся узнаваемым', () {
    final args = nemoServerArgs(
      RunOptions(model: '/m.gguf', lang: 'auto', threads: 4),
      1234,
    );
    expect(args.take(3), ['serve', '--asr-model', '/m.gguf']);
    expect(args, containsAllInOrder(['--host', '127.0.0.1']));
    expect(args, containsAllInOrder(['--port', '1234']));
    expect(args, containsAllInOrder(['--asr.batching.enabled', 'false']));
    expect(args, containsAllInOrder(['--cors-origin', serverMark]));
    expect(args, contains('--no-ui'));
  });
}
