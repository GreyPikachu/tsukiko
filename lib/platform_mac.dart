import 'dart:async';

import 'package:flutter/services.dart';

import 'dictation.dart';

/// Граница платформы. Всё, что упирается в macOS — перехват клавиш,
/// запись с микрофона, вставка текста, панель у строки меню, — живёт
/// за этими интерфейсами и нигде больше.
///
/// На Windows появится второй набор реализаций: CGEventTap заменит
/// SetWindowsHookEx(WH_KEYBOARD_LL), NSPanel — обычное окно без рамки,
/// AVAudioRecorder — WASAPI. Остальной Dart об этом не узнает.

/// Что случилось с назначенной клавишей.
enum HotkeyEdge { down, up }

class HotkeyEvent {
  const HotkeyEvent(this.id, this.edge);

  /// 'hold' или 'toggle' — какое из двух сочетаний сработало.
  final String id;
  final HotkeyEdge edge;
}

abstract class HotkeyBackend {
  /// Назначить сочетания. Зажатое [hold] пишет, пока держат; [toggle]
  /// включает и выключает запись нажатием.
  Future<void> bind({required Hotkey hold, required Hotkey toggle});

  Stream<HotkeyEvent> get events;

  /// Поймать следующее сочетание, чтобы пользователь назначил своё.
  Future<Hotkey?> capture();

  /// Выдан ли «Универсальный доступ» — единственное нужное разрешение:
  /// им живёт и перехват клавиш, и вставка текста в чужое окно.
  Future<bool> permission();

  /// Показать системный запрос. Настройки при этом не открываем: они
  /// перекрыли бы диалог, и разрешение осталось бы неспрошенным.
  Future<void> requestPermission();

  /// Открыть раздел «Универсальный доступ» в системных настройках.
  Future<void> openPermissionSettings();
}

abstract class AudioRecorder {
  /// Начать запись. Возвращает путь к WAV 16 кГц моно — ровно тому,
  /// что whisper ест без пересчёта.
  Future<String?> startRecording();

  /// Остановить и отдать путь к готовому файлу.
  Future<String?> stopRecording();

  /// Уровень сигнала 0…1 для индикатора в панели.
  Future<double> level();
}

abstract class TextInserter {
  /// Вставить текст в активное поле ввода, вернув буфер обмена как был.
  Future<bool> insert(String text);
}

/// Что показывает плавающая панель записи.
enum HudState { hidden, recording, transcribing, done, failed }

abstract class PanelPresenter {
  /// Плавающая панель поверх всех окон: пока она на экране, видно,
  /// что система слушает или считает.
  Future<void> hud(HudState state);

  /// «Отменить» и «Остановить», нажатые в ней мышью.
  Stream<String> get hudActions;

  Future<void> hidePanel();

  /// Высота содержимого панели: окно подгоняется под неё, как системный
  /// поповер, — иначе внизу остаётся пустота на всё, чего сейчас нет.
  Future<void> setPanelHeight(double height);

  /// Полноценное окно tsukiko со всей очередью и настройками.
  Future<void> openMainWindow();

  /// Панель выехала — самое время пересчитать всё, что в ней видно.
  Stream<void> get panelShown;
}

/// Единственная реализация: одна прослойка на Swift, один канал.
class MacPlatform
    implements HotkeyBackend, AudioRecorder, TextInserter, PanelPresenter {
  MacPlatform() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('tsukiko/dictation');

  final _hotkeys = StreamController<HotkeyEvent>.broadcast();
  final _shown = StreamController<void>.broadcast();
  final _hudActions = StreamController<String>.broadcast();
  final _reload = StreamController<void>.broadcast();
  Completer<Hotkey?>? _capture;

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
      case 'hud':
        _hudActions.add(call.arguments as String);
      case 'reload':
        _reload.add(null);
    }
    return null;
  }

  @override
  Stream<HotkeyEvent> get events => _hotkeys.stream;

  @override
  Stream<void> get panelShown => _shown.stream;

  @override
  Stream<String> get hudActions => _hudActions.stream;

  @override
  Future<void> hud(HudState state) =>
      _channel.invokeMethod('hud', {'state': state.name});

  @override
  Future<void> bind({required Hotkey hold, required Hotkey toggle}) =>
      _channel.invokeMethod('bind', {
        'hold': hold.toJson(),
        'toggle': toggle.toJson(),
      });

  @override
  Future<Hotkey?> capture() {
    _capture?.complete(null);
    final c = _capture = Completer<Hotkey?>();
    _channel.invokeMethod<void>('capture');
    // Ждать вечно нельзя: пользователь может передумать и уйти.
    return c.future.timeout(const Duration(seconds: 8), onTimeout: () {
      _channel.invokeMethod<void>('cancelCapture');
      _capture = null;
      return null;
    });
  }

  @override
  Future<bool> permission() async =>
      await _channel.invokeMethod<bool>('permissions') ?? false;

  @override
  Future<void> requestPermission() =>
      _channel.invokeMethod('requestPermission');

  @override
  Future<void> openPermissionSettings() =>
      _channel.invokeMethod('openPermissionSettings');

  /// Настройки диктовки правит и главное окно — панели надо перечитать файл.
  Future<void> settingsChanged() => _channel.invokeMethod('settingsChanged');

  Stream<void> get settingsReloaded => _reload.stream;

  Future<void> quit() => _channel.invokeMethod('quit');

  @override
  Future<String?> startRecording() => _channel.invokeMethod<String>('record');

  @override
  Future<String?> stopRecording() => _channel.invokeMethod<String>('stopRecord');

  @override
  Future<double> level() async =>
      await _channel.invokeMethod<double>('level') ?? 0;

  @override
  Future<bool> insert(String text) async =>
      await _channel.invokeMethod<bool>('paste', {'text': text}) ?? false;

  /// Значок в Dock. Выключенный переводит приложение в .accessory: оно
  /// пропадает и из Dock, и из ⌘Tab, а строка меню остаётся. Меняется
  /// на лету, перезапуск не нужен.
  Future<void> setDockIcon(bool visible) =>
      _channel.invokeMethod('dockIcon', {'visible': visible});

  @override
  Future<void> hidePanel() => _channel.invokeMethod('hidePanel');

  @override
  Future<void> setPanelHeight(double height) =>
      _channel.invokeMethod('panelHeight', {'height': height});

  @override
  Future<void> openMainWindow() => _channel.invokeMethod('openMainWindow');
}
