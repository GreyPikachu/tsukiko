import 'package:equatable/equatable.dart';

import '../../core/models.dart';
import '../../core/whisper_server.dart' show Hotkey;

/// Всё, что видно в окне настроек, — одним неизменяемым снимком.
///
/// От `DictationSettings` здесь лежат разобранные значения, а не сам
/// объект: он меняется внутри себя, и сравнение снимков такую правку
/// не заметило бы — окно замирало бы на устаревшем виде.
class SettingsState extends Equatable {
  const SettingsState({
    this.tab = 'transcriber',
    this.models = const [],
    this.vad,
    this.downloadTitle,
    this.downloadProgress,
    this.downloadPercent = 0,
    this.problem,
    this.allowed = true,
    // диктовка
    this.hold = Hotkey.holdDefault,
    this.toggle = Hotkey.toggleDefault,
    this.dictationModel = '',
    this.queueModel = '',
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

  /// Что лежит на диске: со своим размером и с отметкой, цел ли файл.
  final List<InstalledModel> models;

  /// Модель распознавания пауз, если она загружена. Речью не занимается,
  /// поэтому в общем списке ей не место — но и молчать о ней нельзя.
  final InstalledModel? vad;

  /// Пути годных моделей — для выпадающих списков.
  List<String> get usable =>
      [for (final m in models) if (!m.broken) m.path];

  /// Модель расшифровщика. Правит её главное окно, здесь она только
  /// показывается: без неё в списке моделей не сказать, какая из них
  /// кому служит, — а это первый вопрос, который к списку возникает.
  final String queueModel;

  /// Какой моделью распознаётся диктовка на самом деле — с учётом того,
  /// что пустой выбор означает «взять у расшифровщика».
  String get dictationModelInUse =>
      dictationModel.isNotEmpty ? dictationModel : queueModel;

  /// Кому служит модель [path]: подпись для строки списка. Пусто — никому.
  String? userOf(String path) {
    final forDictation = path == dictationModelInUse;
    final forQueue = path == queueModel;
    if (forDictation && forQueue) return 'расшифровщик и диктовка';
    if (forQueue) return 'расшифровщик';
    if (forDictation) return 'диктовка';
    return null;
  }

  /// Идущая загрузка модели: подпись, ход строкой и процент. Самого
  /// загрузчика здесь нет — он меняется внутри себя.
  final String? downloadTitle, downloadProgress;
  final int downloadPercent;

  /// Почему выбранный руками файл не годится в модель. Пусто — годится.
  final String? problem;

  /// Выдано ли разрешение на перехват клавиш и вставку текста.
  final bool allowed;

  // ── диктовка ──────────────────────────────────────────────────────────────

  final Hotkey hold, toggle;

  /// Модель диктовки. Пусто — «та же, что у расшифровщика».
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
    List<InstalledModel>? models,
    InstalledModel? vad,
    bool clearVadModel = false,
    String? downloadTitle,
    String? downloadProgress,
    int? downloadPercent,
    String? problem,
    bool? allowed,
    Hotkey? hold,
    Hotkey? toggle,
    String? dictationModel,
    String? queueModel,
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
        vad: clearVadModel ? null : (vad ?? this.vad),
        downloadTitle: clearDownload ? null : (downloadTitle ?? this.downloadTitle),
        downloadProgress:
            clearDownload ? null : (downloadProgress ?? this.downloadProgress),
        downloadPercent: clearDownload ? 0 : (downloadPercent ?? this.downloadPercent),
        problem: clearProblem ? null : (problem ?? this.problem),
        allowed: allowed ?? this.allowed,
        hold: hold ?? this.hold,
        toggle: toggle ?? this.toggle,
        dictationModel: dictationModel ?? this.dictationModel,
        queueModel: queueModel ?? this.queueModel,
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
        vad,
        downloadTitle,
        downloadProgress,
        downloadPercent,
        problem,
        allowed,
        hold.label,
        toggle.label,
        dictationModel,
        queueModel,
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
