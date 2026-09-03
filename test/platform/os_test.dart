import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/legacy_migration.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/labels.dart';

/// Граница ОС и разовый переезд моделей.
///
/// Переезд двигает файлы пользователя, а это полтора гигабайта чужой
/// работы: проверять его обязательно. Настоящую систему для этого не
/// трогаем — подменяем `os` на подставную.
void main() {
  group('граница ОС', () {
    test('сборка пути и разбор имени согласованы между собой', () {
      final path = os.join('/a', 'b', 'c.txt');
      expect(os.basename(path), 'c.txt');
      expect(os.dirname(path), os.join('/a', 'b'));
    });

    test('имя без папки остаётся собой', () {
      expect(os.basename('файл.txt'), 'файл.txt');
    });

    test('подпись сочетания собирается в порядке системы, а не хранения', () {
      // Захват приходит множеством: у него порядка нет, и без наведения
      // порядка подпись читалась бы как «⌘ + fn».
      expect(os.shortcutLabel(['cmd', 'fn']), os.shortcutLabel(['fn', 'cmd']));
    });

    test('своя папка моделей лежит внутри данных приложения', () {
      expect(os.modelsDir.startsWith(os.supportDir), isTrue);
    });

    test('whisper ищется в PATH, а не по паре записанных путей', () {
      // Найдётся не на всякой машине — проверяем сам механизм: то, что
      // есть в PATH заведомо, найтись обязано.
      expect(os.findExecutable('ls'), isNotNull);
      expect(os.findExecutable('такой-программы-нет'), isNull);
    });
  });

  group('переезд моделей', () {
    late Directory root;
    late _FakeOs fake;
    late Os real;

    setUp(() {
      real = os;
      root = Directory.systemTemp.createTempSync('tsukiko-move');
      fake = _FakeOs(real, root.path);
      os = fake;
    });

    tearDown(() {
      os = real;
      root.deleteSync(recursive: true);
    });

    File legacy(String name, {int size = 16}) {
      final dir = Directory(fake.legacyDir)..createSync(recursive: true);
      return File(os.join(dir.path, name))
        ..writeAsBytesSync(List<int>.filled(size, 1));
    }

    test('модель переезжает, а не копируется', () async {
      final source = legacy('ggml-large-v3.bin');
      final moved = await migrateLegacyModels();

      expect(moved, 1);
      expect(source.existsSync(), isFalse, reason: 'перенос, а не копия');
      expect(File(os.join(os.modelsDir, 'ggml-large-v3.bin')).existsSync(), isTrue);
    });

    test('модель тишины переезжает вместе с речевыми', () async {
      legacy('ggml-large-v3.bin');
      legacy('ggml-silero-v5.1.2.bin');
      expect(await migrateLegacyModels(), 2);
    });

    test('чужие файлы в той папке не трогаем', () async {
      final alien = legacy('заметки.txt');
      await migrateLegacyModels();
      expect(alien.existsSync(), isTrue);
    });

    test('такая же модель уже есть — лишнюю копию убираем', () async {
      final source = legacy('ggml-tiny.bin', size: 74);
      Directory(os.modelsDir).createSync(recursive: true);
      File(os.join(os.modelsDir, 'ggml-tiny.bin'))
          .writeAsBytesSync(List<int>.filled(74, 1));

      await migrateLegacyModels();
      expect(source.existsSync(), isFalse, reason: 'двух копий по 1,5 ГБ не держим');
    });

    test('разный размер при том же имени — чужое не трогаем', () async {
      final source = legacy('ggml-tiny.bin', size: 74);
      Directory(os.modelsDir).createSync(recursive: true);
      File(os.join(os.modelsDir, 'ggml-tiny.bin'))
          .writeAsBytesSync(List<int>.filled(20, 1));

      await migrateLegacyModels();
      // Файл целее, чем наша уверенность: раз размеры разошлись, это
      // разные файлы, и удалять исходник нельзя.
      expect(source.existsSync(), isTrue);
    });

    test('выбранная модель переезжает вместе с файлом', () async {
      final source = legacy('ggml-large-v3.bin');
      await Settings.save({'model': source.path});

      await migrateLegacyModels();

      // Иначе после обновления человек увидел бы «Не выбрана» и пустой
      // список там, где вчера всё работало.
      expect(Settings.load()['model'], os.join(os.modelsDir, 'ggml-large-v3.bin'));
    });

    test('переезжать нечего — ничего и не делаем', () async {
      expect(await migrateLegacyModels(), 0);
      // Повторный заход тоже безвреден: зовут его обе точки входа.
      expect(await migrateLegacyModels(), 0);
    });

    test('пустая папка прежней установки убирается за собой', () async {
      legacy('ggml-tiny.bin');
      await migrateLegacyModels();
      expect(Directory(fake.legacyDir).existsSync(), isFalse);
    });

    test('модель во вложенной папке тоже переезжает', () async {
      // Там они лежали не россыпью, а каждая в своей подпапке.
      final nested = Directory(os.join(fake.legacyDir, 'whisper-large-v3-turbo'))
        ..createSync(recursive: true);
      final source = File(os.join(nested.path, 'ggml-large-v3-turbo.bin'))
        ..writeAsBytesSync(List<int>.filled(32, 1));

      expect(await migrateLegacyModels(), 1);
      expect(source.existsSync(), isFalse);
      expect(File(os.join(os.modelsDir, 'ggml-large-v3-turbo.bin')).existsSync(),
          isTrue);
      // И пустые подпапки за собой убираем — иначе сама папка никогда
      // не станет пустой и останется висеть.
      expect(Directory(fake.legacyDir).existsSync(), isFalse);
    });
  });
}

/// Подставная система: всё как в настоящей, но папки — во временной.
class _FakeOs implements Os {
  _FakeOs(this._real, this._root);
  final Os _real;
  final String _root;

  String get legacyDir =>
      join(_root, 'Library/Application Support/app.dictara/models');

  @override
  String get home => _root;

  @override
  String get supportDir => join(_root, 'Library/Application Support', bundleId);

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  noSuchMethod(Invocation invocation) =>
      reflectOnReal(invocation);

  /// Всё, что не про пути, отдаём настоящей реализации.
  dynamic reflectOnReal(Invocation invocation) {
    if (invocation.isMethod) {
      return Function.apply(
        _methods[invocation.memberName]!,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return _getters[invocation.memberName]!();
  }

  late final Map<Symbol, Function> _methods = {
    #join: _real.join,
    #basename: _real.basename,
    #dirname: _real.dirname,
    #findExecutable: _real.findExecutable,
    #toWav: _real.toWav,
    #isAlive: _real.isAlive,
    #signal: _real.signal,
    #listProcesses: _real.listProcesses,
    #footprintMb: _real.footprintMb,
    #reveal: _real.reveal,
    #onTerminate: _real.onTerminate,
    #modifierLabel: _real.modifierLabel,
    #shortcutLabel: _real.shortcutLabel,
    #engineNames: _real.engineNames,
    #openUrl: _real.openUrl,
  };

  late final Map<Symbol, Function> _getters = {
    #defaultLibraryPath: () => join(_root, 'Documents', appName),
    #documentsDir: () => join(_root, 'Documents'),
    #sharedModelDirs: () => <String>[],
    #whisperInstallHint: () => _real.whisperInstallHint,
    #fileManagerName: () => _real.fileManagerName,
    #engineDir: () => _real.engineDir,
    #defaultHold: () => _real.defaultHold,
    #defaultToggle: () => _real.defaultToggle,
  };
}
