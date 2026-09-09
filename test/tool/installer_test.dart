import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('свои картинки мастера заданы для обеих тем Windows', () {
    final lines = File('tool/installer.iss').readAsLinesSync();
    String value(String name) => lines
        .singleWhere((line) => line.startsWith('$name='))
        .substring(name.length + 1);

    expect(value('WizardImageFileDynamicDark'), value('WizardImageFile'));
    expect(
      value('WizardSmallImageFileDynamicDark'),
      value('WizardSmallImageFile'),
    );
    for (final path in [
      ...value('WizardImageFile').split(','),
      ...value('WizardSmallImageFile').split(','),
    ]) {
      final local = path.replaceFirst(r'..\design\', 'design/');
      expect(File(local).existsSync(), isTrue, reason: 'нет $local');
    }
  });
}
