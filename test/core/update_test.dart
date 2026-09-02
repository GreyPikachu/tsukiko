import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/update.dart';

/// Проверка обновлений. Сравнение версий — то место, где ошибка тихая:
/// приложение просто никогда не скажет, что вышло новое.
void main() {
  test('версии сравниваются числами, а не строками', () {
    expect(isNewer('1.0.1', '1.0.0'), isTrue);
    expect(isNewer('1.1.0', '1.0.9'), isTrue);
    // Как строка «1.10.0» меньше «1.9.0» — и это ровно та ошибка,
    // из-за которой обновление молча перестаёт находиться.
    expect(isNewer('1.10.0', '1.9.0'), isTrue);
    expect(isNewer('2.0.0', '1.99.99'), isTrue);

    expect(isNewer('1.0.0', '1.0.0'), isFalse);
    expect(isNewer('1.0.0', '1.0.1'), isFalse);
    // Сборка в pubspec записана как «1.0.0+7» — хвост тоже считается.
    expect(isNewer('1.0.0+8', '1.0.0+7'), isTrue);
    expect(isNewer('1.0.0', '1.0.0+1'), isFalse);
  });

  test('без сети и на чужой ответ новостей просто нет', () async {
    // Не исключение и не сообщение: проверка обновлений — не тот повод,
    // чтобы беспокоить человека.
    expect(await checkForUpdate('1.0.0', url: 'https://127.0.0.1:9/nothing'),
        isNull);
  });
}
