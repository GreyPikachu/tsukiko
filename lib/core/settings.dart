import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'library.dart' show supportDir;

/// Хранение настроек на диске.
///
/// Файл настроек правят три изолята: главное окно, панель у строки меню и
/// окно настроек. Отсюда два независимых требования, и оба решаются здесь.
///
/// **Целость.** Запись идёт во временный файл рядом и переименованием
/// встаёт на место. `rename` на одной файловой системе атомарен, поэтому
/// читатель видит либо старый файл целиком, либо новый целиком. Раньше
/// файл переписывался на месте, и падение или полный диск посреди записи
/// оставляли обрезанный JSON — то есть стирали все настройки разом.
///
/// **Очередь.** «Прочитать → слить → записать» из двух изолятов сразу
/// теряет правку того, кто прочитал первым. Файловый замок для этого
/// не годится: POSIX-замки принадлежат процессу, а изоляты живут в одном
/// процессе — второй проходит сквозь замок первого, проверено. Поэтому
/// пишет всегда один изолят: кто первым занял имя в [IsolateNameServer],
/// тот и владеет файлом, остальные шлют ему правки портом и ждут ответа.
/// Читают при этом все напрямую — благодаря атомарной записи это безопасно.

/// Записать JSON так, чтобы читатель никогда не увидел половину файла.
void writeJsonAtomically(File target, Map<String, dynamic> data) {
  final tmp = File('${target.path}.tmp');
  final raf = tmp.openSync(mode: FileMode.write);
  try {
    raf.writeStringSync(const JsonEncoder.withIndent('  ').convert(data));
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  tmp.renameSync(target.path);
}

/// Общие настройки приложения: обычный JSON в Application Support.
class Settings {
  Settings._();

  /// Имя порта владельца. Одно на приложение — иначе владельцев станет
  /// столько же, сколько имён.
  static const _writerName = 'app.yuko.tsukiko/settings-writer';

  static File get _file => File('$supportDir/settings.json');

  /// Наш порт, если владелец — этот изолят. Держим ссылку: закрытый
  /// ReceivePort перестал бы принимать правки соседей.
  static ReceivePort? _owned;

  static Map<String, dynamic> load() {
    try {
      return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Слить [data] в файл, не тронув чужие ключи.
  ///
  /// Возвращается, когда правка действительно на диске: сразу после этого
  /// соседним окнам говорят перечитать файл, и читать они должны уже новое.
  static Future<void> save(Map<String, dynamic> data) async {
    final writer = _writer();
    if (writer == null) {
      _merge(data);
      return;
    }
    final reply = ReceivePort();
    writer.send([data, reply.sendPort]);
    try {
      await reply.first;
    } finally {
      reply.close();
    }
  }

  /// Порт владельца или null, если владелец — мы сами.
  static SendPort? _writer() {
    if (_owned != null) return null;

    final found = IsolateNameServer.lookupPortByName(_writerName);
    if (found != null) return found;

    // Имя занимается атомарно: если два изолята пришли сюда одновременно,
    // ровно один получит true, второй пойдёт искать заново.
    final rp = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(rp.sendPort, _writerName)) {
      rp.close();
      // Владелец мог зарегистрироваться между поиском и попыткой. Если
      // его всё-таки нет, пишем сами: потерять правку хуже, чем разойтись
      // с соседом в невозможной гонке.
      return IsolateNameServer.lookupPortByName(_writerName);
    }
    _owned = rp;
    rp.listen((message) {
      final args = message as List;
      _merge((args[0] as Map).cast<String, dynamic>());
      (args[1] as SendPort).send(null);
    });
    return null;
  }

  static void _merge(Map<String, dynamic> data) {
    try {
      Directory(supportDir).createSync(recursive: true);
      writeJsonAtomically(_file, {...load(), ...data});
    } catch (e) {
      // Настройки не сохранились. Молчать нельзя: следующий запуск придёт
      // со старыми значениями, и человек решит, что приложение их не помнит.
      stderr.writeln('tsukiko: не удалось сохранить настройки — $e');
    }
  }
}
