import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/core/library.dart';
import 'package:tsukiko/core/models.dart';
import 'package:tsukiko/core/settings.dart';

/// Проверки на те поломки, которые раньше проходили молча: обрезанный файл
/// настроек, склеенная из двух версий модель, экспорт поверх чужих файлов.
/// Все они про потерю данных, поэтому и живут отдельным файлом.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tsukiko-test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('запись настроек', () {
    test('файл никогда не остаётся обрезанным: пишем и переименовываем', () {
      final target = File('${tmp.path}/settings.json');
      writeJsonAtomically(target, {'a': 1});
      expect(jsonDecode(target.readAsStringSync()), {'a': 1});

      // Временного файла после себя не оставляем: findModels и подобные
      // обходы каталога не должны натыкаться на огрызки.
      expect(File('${target.path}.tmp').existsSync(), isFalse);

      // Повторная запись заменяет содержимое целиком, а не дописывает.
      writeJsonAtomically(target, {'b': 2});
      expect(jsonDecode(target.readAsStringSync()), {'b': 2});
    });

    test('в любой момент на диске лежит целый JSON, а не половина', () {
      final target = File('${tmp.path}/settings.json');
      // Большой объём: если бы запись шла на месте, читатель успел бы
      // застать её посередине. С переименованием этого состояния нет.
      final big = {for (var i = 0; i < 2000; i++) 'ключ$i': 'значение$i'};
      writeJsonAtomically(target, {'а': 'б'});
      writeJsonAtomically(target, big);
      final read = jsonDecode(target.readAsStringSync()) as Map;
      expect(read.length, 2000);
    });

    test('слияние не трогает чужие ключи', () async {
      // Settings пишет в настоящую папку приложения, поэтому проверяем
      // на ней же — и возвращаем как было.
      final before = Settings.load();
      addTearDown(() async {
        final file = File('$supportDir/settings.json');
        if (before.isEmpty) {
          if (file.existsSync()) file.deleteSync();
        } else {
          writeJsonAtomically(file, before);
        }
      });

      await Settings.save({'тест-один': 1});
      await Settings.save({'тест-два': 2});
      final after = Settings.load();
      expect(after['тест-один'], 1, reason: 'первый ключ пережил вторую запись');
      expect(after['тест-два'], 2);
      for (final key in before.keys) {
        expect(after.containsKey(key), isTrue, reason: 'ключ «$key» не потерян');
      }
    });
  });

  group('свободное имя', () {
    test('под один формат — как раньше', () {
      File('${tmp.path}/Запись.txt').writeAsStringSync('занято');
      expect(freeStem(tmp.path, 'Запись', '.txt'), 'Запись 2');
      expect(freeStem(tmp.path, 'Другая', '.txt'), 'Другая');
    });

    test('под набор форматов имя выбирается одно на всех', () {
      // .txt свободен, .srt занят: старый код взял бы «Запись» и затёр
      // чужие субтитры, положив рядом свой текст.
      File('${tmp.path}/Запись.srt').writeAsStringSync('чужие субтитры');
      final stem = freeStemFor(tmp.path, 'Запись', ['.txt', '.srt']);
      expect(stem, 'Запись 2');
      expect(File('${tmp.path}/Запись.srt').readAsStringSync(), 'чужие субтитры');
    });

    test('свободно везде — номер не приписывается', () {
      expect(freeStemFor(tmp.path, 'Запись', ['.txt', '.srt', '.vtt']), 'Запись');
    });

    test('суффикс с пробелом («текст с таймкодами») тоже учитывается', () {
      File('${tmp.path}/Запись (таймкоды).txt').writeAsStringSync('занято');
      final stem = freeStemFor(tmp.path, 'Запись', ['.txt', ' (таймкоды).txt']);
      expect(stem, 'Запись 2');
    });
  });

  group('докачка модели', () {
    /// Сервер, который отдаёт куски по Range и умеет притвориться, что
    /// файл сменился: тогда на If-Range он обязан ответить целиком.
    Future<HttpServer> serve({
      required List<int> body,
      required String etag,
      String? expectIfRange,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        final ifRange = req.headers.value(HttpHeaders.ifRangeHeader);
        req.response.headers.set(HttpHeaders.etagHeader, etag);
        // Кусок отдаём только когда метка совпала с нынешней версией.
        if (range != null && ifRange == expectIfRange && ifRange != null) {
          final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.add(body.sublist(from));
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.add(body);
        }
        await req.response.close();
      });
      return server;
    }

    test('оборванная загрузка продолжается с того же места', () async {
      final body = List<int>.generate(4096, (i) => i % 251);
      final server = await serve(body: body, etag: '"v1"', expectIfRange: '"v1"');
      addTearDown(() => server.close(force: true));

      final dest = '${tmp.path}/model.bin';
      // Половина уже скачана, метка версии рядом — как после обрыва.
      File('$dest.part').writeAsBytesSync(body.sublist(0, 1000));
      File('$dest.part.id').writeAsStringSync('"v1"');

      final path = await Download(
              'http://127.0.0.1:${server.port}/model.bin', dest)
          .run();
      expect(path, dest);
      expect(File(dest).readAsBytesSync(), body);
      expect(File('$dest.part.id').existsSync(), isFalse, reason: 'метка убрана');
    });

    test('файл на сервере сменился — качаем заново, а не склеиваем версии',
        () async {
      final fresh = List<int>.generate(4096, (i) => (i * 7) % 251);
      // Сервер знает только новую метку: старый «.part» ему чужой.
      final server = await serve(body: fresh, etag: '"v2"', expectIfRange: '"v2"');
      addTearDown(() => server.close(force: true));

      final dest = '${tmp.path}/model.bin';
      // Огрызок от прошлой версии файла.
      File('$dest.part').writeAsBytesSync(List<int>.filled(1000, 1));
      File('$dest.part.id').writeAsStringSync('"v1"');

      final path = await Download(
              'http://127.0.0.1:${server.port}/model.bin', dest)
          .run();
      expect(path, dest);
      // Именно это раньше и ломалось: к началу старой версии дописывался
      // хвост новой, и мусор переименовывался в готовую модель.
      expect(File(dest).readAsBytesSync(), fresh);
    });

    test('огрызок без метки версии докачивать нельзя', () async {
      final body = List<int>.generate(2048, (i) => i % 251);
      // expectIfRange = null: сервер отдаст кусок, только если его попросят
      // с меткой. Если бы мы попросили без неё, тест бы это заметил.
      final server = await serve(body: body, etag: '"v1"');
      addTearDown(() => server.close(force: true));

      final dest = '${tmp.path}/model.bin';
      File('$dest.part').writeAsBytesSync(List<int>.filled(500, 9));

      final path = await Download(
              'http://127.0.0.1:${server.port}/model.bin', dest)
          .run();
      expect(path, dest);
      expect(File(dest).readAsBytesSync(), body);
    });
  });

  group('уборка временного', () {
    /// Состарить запись на диске: `Directory` в dart:io менять время
    /// не умеет, а `touch` умеет.
    Future<void> age(String path) => Process.run('touch', ['-t', '202001010000', path]);

    test('забытая папка очереди уходит, свежая остаётся', () async {
      final stale = Directory('${tmp.path}/tsukikoSTALE')..createSync();
      File('${stale.path}/000.wav').writeAsStringSync('сотня мегабайт');
      final fresh = Directory('${tmp.path}/tsukikoFRESH')..createSync();
      await age(stale.path);

      sweepRecordings(where: tmp);

      // Час записи в подготовленном звуке — это больше сотни мегабайт,
      // и лежали они там до перезагрузки: dispose мимо ⌘Q не проходит.
      expect(stale.existsSync(), isFalse);
      // А папку этого запуска трогать нельзя: в ней прямо сейчас работают.
      expect(fresh.existsSync(), isTrue);
    });

    test('чужое во временной папке не трогаем', () async {
      final alien = Directory('${tmp.path}/someone-else')..createSync();
      final alienFile = File('${tmp.path}/notes.wav')..writeAsStringSync('чужое');
      await age(alien.path);
      await age(alienFile.path);

      sweepRecordings(where: tmp);

      expect(alien.existsSync(), isTrue);
      expect(alienFile.existsSync(), isTrue);
    });

    test('записи диктовки уходят независимо от возраста', () {
      final wav = File('${tmp.path}/tsukiko-1785750609498.wav')
        ..writeAsStringSync('запись');
      sweepRecordings(where: tmp);
      expect(wav.existsSync(), isFalse);
    });
  });

}
