import 'package:equatable/equatable.dart';

import '../../core/whisper_server.dart' show Hotkey;

/// Всё, что видно в окне настроек, — одним неизменяемым снимком.
///
/// От `DictationSettings` здесь лежат разобранные значения, а не сам
/// объект: он меняется внутри себя, и сравнение снимков такую правку
/// не заметило бы — окно замирало бы на устаревшем виде.
class SettingsState extends Equatable {
  const SettingsState({
    this.tab = 'dictation',
    this.models = const [],
    this.downloadTitle,
    this.downloadProgress,
    this.downloadPercent = 0,
    this.problem,
    this.allowed = true,
    // диктовка
    this.hold = Hotkey.holdDefault,
    this.toggle = Hotkey.toggleDefault,
    this.dictationModel = '',
    this.threads = 4,
    this.punctuate = true,
    this.prompt = '',
    this.idleSeconds = 180,
    this.insert = true,
    this.hud = true,
    // приложение
    this.toLibrary = true,
    this.saveNextToSource = false,
    this.timestamps = true,
    this.yieldBusyModel = true,
    this.dockIcon = true,
    this.loginItem = false,
    this.libraryPath = '',
    this.libraryFormats = const ['txt'],
  });

  /// Какая вкладка открыта. Приходит и снаружи: окно могут попросить
  /// открыться сразу на «Моделях».
  final String tab;

  final List<String> models;

  /// Идущая загрузка модели: подпись, ход строкой и процент. Самого
  /// загрузчика здесь нет — он меняется внутри себя.
  final String? downloadTitle, downloadProgress;
  final int downloadPercent;

  /// Почему выбранный руками файл не годится в модель. Пусто — годится.
  final String? problem;

  /// Выдан ли «Универсальный доступ».
  final bool allowed;

  // ── диктовка ──────────────────────────────────────────────────────────────

  final Hotkey hold, toggle;

  /// Пусто — «как у расшифровщика».
  final String dictationModel;

  final int threads;
  final bool punctuate;
  final String prompt;
  final int idleSeconds;
  final bool insert, hud;

  // ── приложение ────────────────────────────────────────────────────────────

  final bool toLibrary, saveNextToSource, timestamps, yieldBusyModel, dockIcon;

  /// Автозапуск живёт в системе, а не в settings.json: его можно выключить
  /// в системных настройках мимо нас.
  final bool loginItem;

  final String libraryPath;
  final List<String> libraryFormats;

  bool get downloading => downloadProgress != null;

  SettingsState copyWith({
    String? tab,
    List<String>? models,
    String? downloadTitle,
    String? downloadProgress,
    int? downloadPercent,
    String? problem,
    bool? allowed,
    Hotkey? hold,
    Hotkey? toggle,
    String? dictationModel,
    int? threads,
    bool? punctuate,
    String? prompt,
    int? idleSeconds,
    bool? insert,
    bool? hud,
    bool? toLibrary,
    bool? saveNextToSource,
    bool? timestamps,
    bool? yieldBusyModel,
    bool? dockIcon,
    bool? loginItem,
    String? libraryPath,
    List<String>? libraryFormats,
    // Обнулять поля иначе нечем: `null` в именованном параметре
    // не отличить от «не передали».
    bool clearDownload = false,
    bool clearProblem = false,
  }) =>
      SettingsState(
        tab: tab ?? this.tab,
        models: models ?? this.models,
        downloadTitle: clearDownload ? null : (downloadTitle ?? this.downloadTitle),
        downloadProgress:
            clearDownload ? null : (downloadProgress ?? this.downloadProgress),
        downloadPercent: clearDownload ? 0 : (downloadPercent ?? this.downloadPercent),
        problem: clearProblem ? null : (problem ?? this.problem),
        allowed: allowed ?? this.allowed,
        hold: hold ?? this.hold,
        toggle: toggle ?? this.toggle,
        dictationModel: dictationModel ?? this.dictationModel,
        threads: threads ?? this.threads,
        punctuate: punctuate ?? this.punctuate,
        prompt: prompt ?? this.prompt,
        idleSeconds: idleSeconds ?? this.idleSeconds,
        insert: insert ?? this.insert,
        hud: hud ?? this.hud,
        toLibrary: toLibrary ?? this.toLibrary,
        saveNextToSource: saveNextToSource ?? this.saveNextToSource,
        timestamps: timestamps ?? this.timestamps,
        yieldBusyModel: yieldBusyModel ?? this.yieldBusyModel,
        dockIcon: dockIcon ?? this.dockIcon,
        loginItem: loginItem ?? this.loginItem,
        libraryPath: libraryPath ?? this.libraryPath,
        libraryFormats: libraryFormats ?? this.libraryFormats,
      );

  @override
  List<Object?> get props => [
        tab,
        models,
        downloadTitle,
        downloadProgress,
        downloadPercent,
        problem,
        allowed,
        hold.label,
        toggle.label,
        dictationModel,
        threads,
        punctuate,
        prompt,
        idleSeconds,
        insert,
        hud,
        toLibrary,
        saveNextToSource,
        timestamps,
        yieldBusyModel,
        dockIcon,
        loginItem,
        libraryPath,
        libraryFormats,
      ];
}
