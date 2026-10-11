@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_windows.dart';

/// Живость, память и завершение процесса — через kernel32, без `tasklist`.
/// Проверяем на настоящем процессе: подделка тут ничего бы не доказала.
void main() {
  final os = WindowsOs();

  test('свой процесс жив и занимает память', () async {
    expect(os.isAlive(pid), isTrue);
    expect(await os.footprintMb(pid), greaterThan(0));
  });

  test('несуществующий pid мёртв, памяти у него нет', () async {
    expect(os.isAlive(0), isFalse);
    expect(os.isAlive(0x7FFFFFF0), isFalse);
    expect(await os.footprintMb(0x7FFFFFF0), 0);
  });

  test('приказ завершает процесс', () async {
    final child = await Process.start('ping', ['-n', '60', '127.0.0.1']);
    addTearDown(child.kill);
    expect(os.isAlive(child.pid), isTrue);
    os.signal(child.pid, force: true);
    await child.exitCode.timeout(const Duration(seconds: 5));
    expect(os.isAlive(child.pid), isFalse);
  });
}
