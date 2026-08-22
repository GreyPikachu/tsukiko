import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../core/whisper_server.dart';

/// Мост к родному коду приложения: перехват клавиш, запись с микрофона,
/// вставка текста, окна и панель у строки меню.
///
/// Этот файл платформы не знает: он весь — один MethodChannel, и на любой
/// системе выглядит одинаково. Разница живёт на той стороне канала:
/// сейчас это Swift (`macos/Runner`), на Windows будет C++ (`windows/runner`),
/// который должен отвечать на те же имена методов и слать те же события.
/// Отдельных реализаций в Dart для этого не нужно — и раньше здесь стояли
/// четыре абстрактных класса, у которых была ровно одна реализация и ни
/// одного места, где они использовались бы как типы.
///
/// То, что по-разному делается в самом Dart — пути, процессы, звук, —
/// живёт не здесь, а за границей `os.dart`.

/// Что случилось с назначенной клавишей.
enum HotkeyEdge { down, up }

class HotkeyEvent {
  const HotkeyEvent(this.id, this.edge);

  /// 'hold' или 'toggle' — какое из двух сочетаний сработало.
  final String id;
  final HotkeyEdge edge;
}




/// Что показывает плавающая панель записи.
///
/// [failed] — записи не стало текстом, и она спасена в файл. [copied] —
/// текст есть, но вставить его в чужое окно не вышло, и он ждёт в буфере
/// обмена. [cancelled] — распознавание прервали сами, запись сохранена.
/// Разные исходы, и подпись у них разная.
enum HudState { hidden, recording, transcribing, done, failed, copied, cancelled }


/// Один канал на всё приложение.
///
/// Экземпляр должен быть один на изолят: конструктор вешает обработчик
/// на общий канал, и второй экземпляр молча отобрал бы его у первого.
class NativeBridge {
  NativeBridge() {
    assert(() {
      if (_installed) {
        throw StateError('NativeBridge создан дважды в одном изоляте: '
            'второй экземпляр отбирает обработчик канала у первого.');
      }
      _installed = true;
      return true;
    }());
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('tsukiko/dictation');

  /// Только для проверки в отладке — см. конструктор.
  static bool _installed = false;

  /// Забыть, что мост уже создавали. Нужно тестам: каждый берёт свежий
  /// мост, а в приложении он один на изолят и на весь запуск.
  @visibleForTesting
  static void debugReset() => _installed = false;

  final _hotkeys = StreamController<HotkeyEvent>.broadcast();
  final _shown = StreamController<void>.broadcast();
  final _hidden = StreamController<void>.broadcast();
  final _hudActions = StreamController<String>.broadcast();
  final _reload = StreamController<void>.broadcast();
  final _tab = StreamController<String>.broadcast();
  Completer<Hotkey?>? _capture;

  /// Спросили, можно ли забрать модель. Отвечает сторона диктовки: только
  /// она знает, говорит ли человек прямо сейчас. Нет обработчика — значит
  /// это не она, и отказывать некому.
  bool Function()? onModelRequested;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'hotkey':
        final a = (call.arguments as Map).cast<String, dynamic>();
        _hotkeys.add(HotkeyEvent(
          a['id'] as String,
          a['down'] as bool ? HotkeyEdge.down : HotkeyEdge.up,
        ));
      case 'captured':
        final a = (call.arguments as Map).cast<String, dynamic>();
        _capture?.complete(Hotkey(
          (a['mods'] as List).map((e) => '$e').toList(),
          key: a['key'] as String?,
        ));
        _capture = null;
      case 'panelShown':
        _shown.add(null);
      case 'panelHidden':
        _hidden.add(null);
      case 'hud':
        _hudActions.add(call.arguments as String);
      case 'reload':
        _reload.add(null);
      case 'tab':
        _tab.add(call.arguments as String);
      case 'yieldModel':
        return onModelRequested?.call() ?? true;
    }
    return null;
  }

  Stream<HotkeyEvent> get events => _hotkeys.stream;

  Stream<void> get panelShown => _shown.stream;

  Stream<void> get panelHidden => _hidden.stream;

  /// Убрать файл в Корзину, а не стереть насовсем. Промах по кнопке
  /// «Удалить» после часа речи иначе стоил бы этого часа: из Корзины
  /// запись возвращается средствами самой системы.
  Future<bool> trash(String path) async =>
      await _channel.invokeMethod<bool>('trash', {'path': path}) ?? false;

  Stream<String> get hudActions => _hudActions.stream;

  Future<void> hud(HudState state) =>
      _channel.invokeMethod('hud', {'state': state.name});

  Future<void> bind({required Hotkey hold, required Hotkey toggle}) =>
      _channel.invokeMethod('bind', {
        'hold': hold.toJson(),
        'toggle': toggle.toJson(),
      });

  Future<Hotkey?> capture() {
    // Прошлый захват мог уже завершиться по времени: его completer тогда
    // так и остался незакрытым, и второе `complete` бросило бы исключение.
    final previous = _capture;
    if (previous != null && !previous.isCompleted) previous.complete(null);

    final c = _capture = Completer<Hotkey?>();
    _channel.invokeMethod<void>('capture');
    // Ждать вечно нельзя: пользователь может передумать и уйти.
    return c.future.timeout(const Duration(seconds: 8), onTimeout: () {
      _channel.invokeMethod<void>('cancelCapture');
      // Только своё: пока мы ждали, человек мог щёлкнуть по чипу ещё раз,
      // и в поле уже лежит новый completer. Обнулив его здесь, мы оставили
      // бы второй захват висеть навсегда.
      if (identical(_capture, c)) _capture = null;
      return null;
    });
  }

  Future<bool> permission() async =>
      await _channel.invokeMethod<bool>('permissions') ?? false;

  Future<void> requestPermission() =>
      _channel.invokeMethod('requestPermission');

  Future<void> openPermissionSettings() =>
      _channel.invokeMethod('openPermissionSettings');

  /// Попросить у диктовки модель. true — она свободна и уступила, false —
  /// человек говорит прямо сейчас, и очереди надо подождать.
  Future<bool> requestModel() async =>
      await _channel.invokeMethod<bool>('requestModel') ?? true;

  /// Настройки диктовки правит и главное окно — панели надо перечитать файл.
  Future<void> settingsChanged() => _channel.invokeMethod('settingsChanged');

  Stream<void> get settingsReloaded => _reload.stream;

  Future<void> quit() => _channel.invokeMethod('quit');

  /// Сказать родной стороне, по каким признакам узнаётся наш whisper-server.
  ///
  /// На выходе из приложения сирот добивает именно она (обычное «Завершить»
  /// сигнала в Dart не шлёт), и признаки ей нужны те же самые. Раньше они
  /// были записаны в двух местах на двух языках и могли разойтись; теперь
  /// источник один — `ourServerMarks` в dictation.dart.
  Future<void> setServerMarks(List<String> marks) =>
      _channel.invokeMethod('serverMarks', {'marks': marks});

  Future<String?> startRecording() => _channel.invokeMethod<String>('record');

  Future<String?> stopRecording() => _channel.invokeMethod<String>('stopRecord');

  Future<double> level() async =>
      await _channel.invokeMethod<double>('level') ?? 0;

  Future<bool> insert(String text) async =>
      await _channel.invokeMethod<bool>('paste', {'text': text}) ?? false;

  /// Значок в Dock. Выключенный переводит приложение в .accessory: оно
  /// пропадает и из Dock, и из ⌘Tab, а строка меню остаётся. Меняется
  /// на лету, перезапуск не нужен.
  Future<void> setDockIcon(bool visible) =>
      _channel.invokeMethod('dockIcon', {'visible': visible});

  /// Автозапуск при входе в систему. Состояние хранит сама macOS, поэтому
  /// и спрашиваем его у неё: автозапуск можно выключить в Системных
  /// настройках, и своя запись в settings.json об этом бы не узнала.
  /// Без аргумента — только спросить, с аргументом — переключить.
  Future<bool> loginItem([bool? enabled]) async =>
      await _channel.invokeMethod<bool>(
        'loginItem',
        enabled == null ? null : {'enabled': enabled},
      ) ??
      false;

  Future<void> setPanelHeight(double height) =>
      _channel.invokeMethod('panelHeight', {'height': height});

  Future<void> openMainWindow() => _channel.invokeMethod('openMainWindow');

  Future<void> openSettings([String tab = 'dictation']) =>
      _channel.invokeMethod('openSettings', {'tab': tab});

  /// Какую вкладку показать при открытии. Окно настроек спрашивает это
  /// само: сообщение об открытии приходит раньше, чем его изолят успевает
  /// подписаться на канал.
  Future<String> initialTab() async =>
      await _channel.invokeMethod<String>('initialTab') ?? 'dictation';

  /// Окно настроек уже открыто, и попросили другую вкладку.
  Stream<String> get settingsTab => _tab.stream;
}
