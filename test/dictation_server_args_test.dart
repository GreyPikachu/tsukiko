import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/dictation.dart';
import 'package:tsukiko/engine.dart';

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
}
