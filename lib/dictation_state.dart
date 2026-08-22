import 'package:equatable/equatable.dart';

/// Что делает диктовка прямо сейчас.
enum Phase { idle, recording, transcribing }

/// Всё, что видно в панели у строки меню, — одним неизменяемым снимком.
///
/// Здесь только значения, и это не формальность. Cubit решает,
/// перерисовывать ли панель, сравнивая новый снимок со старым, а сравнивать
/// изменяемые объекты бессмысленно: у `DictationSettings` и `Download`
/// содержимое меняется без замены самого объекта, и панель молча замирала
/// бы на устаревшем виде. Поэтому от настроек здесь лежат уже разобранные
/// подписи, а от загрузки — готовая строка хода.
///
/// Службы (сервер, мост к системе, таймеры) в состояние не входят вовсе:
/// ими владеет сам Cubit, а наружу отдаёт только то, что рисуется.
class DictationState extends Equatable {
  const DictationState({
    this.phase = Phase.idle,
    this.enabled = true,
    this.holdLabel = '',
    this.toggleLabel = '',
    this.last = '',
    this.level = 0,
    this.elapsed = Duration.zero,
    this.allowed = true,
    this.sweptMb = 0,
    this.failure,
    this.failurePath,
    this.vadProgress,
    this.vadError,
    this.serverUp = false,
    this.untilUnload,
    this.memoryMb = 0,
    this.chosenModel = '',
    this.ownModel = false,
    this.fastModel = '',
    this.accurateModel = '',
  });

  final Phase phase;

  /// Главный выключатель и подписи назначенных сочетаний.
  final bool enabled;
  final String holdLabel, toggleLabel;

  /// Последняя расшифровка — то, что можно скопировать ещё раз.
  final String last;

  /// Уровень сигнала 0…1 и время с начала записи.
  final double level;
  final Duration elapsed;

  /// Выдан ли «Универсальный доступ».
  final bool allowed;

  /// Сколько мегабайт вернул подбор забытых серверов на старте.
  final int sweptMb;

  /// Что пошло не так и где лежит спасённая запись. Путь есть — можно
  /// показать её в проводнике и убрать в Корзину; пути нет — беда была
  /// не с записью (например, не удалась вставка текста).
  final String? failure, failurePath;

  /// Ход загрузки модели тишины готовой строкой и причина, по которой
  /// она не приехала.
  final String? vadProgress, vadError;

  /// Сервер поднят, и сколько ему осталось до выгрузки по простою.
  final bool serverUp;
  final Duration? untilUnload;
  final int memoryMb;

  /// Модель, под которой работает диктовка, и своя ли она: пустая своя
  /// настройка значит «как у расшифровщика».
  final String chosenModel;
  final bool ownModel;

  /// Пара «быстрая · точная» из того, что нашлось на диске. Совпадают —
  /// значит модель одна, и переключать нечего.
  final String fastModel, accurateModel;

  bool get hasModels => fastModel.isNotEmpty;
  bool get canSwitchModel => fastModel.isNotEmpty && fastModel != accurateModel;
  bool get recording => phase == Phase.recording;

  DictationState copyWith({
    Phase? phase,
    bool? enabled,
    String? holdLabel,
    String? toggleLabel,
    String? last,
    double? level,
    Duration? elapsed,
    bool? allowed,
    int? sweptMb,
    String? failure,
    String? failurePath,
    String? vadProgress,
    String? vadError,
    bool? serverUp,
    Duration? untilUnload,
    int? memoryMb,
    String? chosenModel,
    bool? ownModel,
    String? fastModel,
    String? accurateModel,
    // Обнулять поля через copyWith иначе нечем: `null` в именованном
    // параметре не отличить от «не передали».
    bool clearFailure = false,
    bool clearVad = false,
    bool clearUnload = false,
  }) =>
      DictationState(
        phase: phase ?? this.phase,
        enabled: enabled ?? this.enabled,
        holdLabel: holdLabel ?? this.holdLabel,
        toggleLabel: toggleLabel ?? this.toggleLabel,
        last: last ?? this.last,
        level: level ?? this.level,
        elapsed: elapsed ?? this.elapsed,
        allowed: allowed ?? this.allowed,
        sweptMb: sweptMb ?? this.sweptMb,
        failure: clearFailure ? null : (failure ?? this.failure),
        failurePath: clearFailure ? null : (failurePath ?? this.failurePath),
        vadProgress: clearVad ? null : (vadProgress ?? this.vadProgress),
        vadError: clearVad ? null : (vadError ?? this.vadError),
        serverUp: serverUp ?? this.serverUp,
        untilUnload: clearUnload ? null : (untilUnload ?? this.untilUnload),
        memoryMb: memoryMb ?? this.memoryMb,
        chosenModel: chosenModel ?? this.chosenModel,
        ownModel: ownModel ?? this.ownModel,
        fastModel: fastModel ?? this.fastModel,
        accurateModel: accurateModel ?? this.accurateModel,
      );

  @override
  List<Object?> get props => [
        phase,
        enabled,
        holdLabel,
        toggleLabel,
        last,
        level,
        elapsed,
        allowed,
        sweptMb,
        failure,
        failurePath,
        vadProgress,
        vadError,
        serverUp,
        untilUnload,
        memoryMb,
        chosenModel,
        ownModel,
        fastModel,
        accurateModel,
      ];
}
