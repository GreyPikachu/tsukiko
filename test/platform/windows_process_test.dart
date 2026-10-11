@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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

  test('движок привязан к приложению: попадает в задание «убить при закрытии»', () async {
    final child = await Process.start('ping', ['-n', '60', '127.0.0.1']);
    addTearDown(child.kill);
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel32.lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    final isProcessInJob = kernel32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)>('IsProcessInJob');
    final closeHandle = kernel32.lookupFunction<
        Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');
    bool inJob() {
      final h = openProcess(0x1000, 0, child.pid);
      final result = calloc<Int32>();
      try {
        isProcessInJob(h, nullptr, result);
        return result.value != 0;
      } finally {
        calloc.free(result);
        closeHandle(h);
      }
    }

    os.bindToApp(child.pid);
    expect(inJob(), isTrue);
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
