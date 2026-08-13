import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'design.dart';
import 'dictation.dart';
import 'engine.dart';
import 'platform_mac.dart';

/// Панель у строки меню и вся диктовка. Живёт на отдельном движке Flutter,
/// который работает и со спрятанной панелью, — поэтому диктовка не зависит
/// от того, открыто ли главное окно.
void runPanel() {
  WidgetsFlutterBinding.ensureInitialized();
  // Сервер мог пережить падение приложения: полтора гигабайта, которые
  // иначе не вернёт никто.
  killStaleServer();
  sweepRecordings();
  runApp(PanelApp(DictationController(MacPlatform())));
}

enum Phase { idle, recording, transcribing }

class DictationController extends ChangeNotifier {
  DictationController(this.platform) {
    server = WhisperServer(
      idleTimeout: Duration(seconds: settings.idleSeconds),
      onChanged: _onServerChanged,
    );
    platform.events.listen(_onHotkey);
    // Кнопки плавающей панели — те же два действия, что и клавиши.
    platform.hudActions.listen((a) => a == 'cancel' ? cancel() : stop());
    platform.panelShown.listen((_) => _refresh());
    // Те же настройки правит инспектор главного окна — там они и живут.
    platform.settingsReloaded.listen((_) => _reloadSettings());
    _apply();

    unawaited(_ensureVad());

    // Обратный отсчёт до выгрузки идёт на экране — секунды хватает.
    Timer.periodic(const Duration(seconds: 1), (_) => _tickServer());
    ProcessSignal.sigterm.watch().listen((_) => _bye());
    ProcessSignal.sigint.watch().listen((_) => _bye());
  }

  final MacPlatform platform;
  DictationSettings settings = DictationSettings.load();
  late final WhisperServer server;

  Phase phase = Phase.idle;
  String last = '';
  double level = 0;
  Duration elapsed = Duration.zero;
  int memoryMb = 0;
  Permissions perms = const Permissions();
  List<String> models = findModels();

  /// Идёт загрузка модели тишины. Пока она идёт, диктовка работает без VAD.
  Download? vadDownload;

  /// Почему модель тишины так и не приехала. Сеть могла лежать ровно в те
  /// секунды, когда приложение стартовало, — второго шанса без кнопки
  /// не было бы до следующего запуска.
  String? vadError;

  String? _wav;
  DateTime? _startedAt;
  Timer? _meter;

  Never _bye() {
    server.shutdown();
    exit(0);
  }

  /// Настройки распознавания диктовки: своё только модель, подсказка и VAD,
  /// остальное — общее с очередью. Язык всегда «авто»: диктуют на разных
  /// языках вперемешку, и выбирать его руками каждый раз некому.
  RunOptions get options {
    final base = RunOptions.fromJson(
      Settings.load(),
      const RunOptions(model: '', lang: 'auto', threads: 4),
    );
    // На диктовке VAD включён всегда, независимо от галки в очереди: фразы
    // короткие, и на секундах тишины whisper сочиняет «Продолжение следует…».
    final vad = File(vadModelPath).existsSync();
    return base.copyWith(
      model: settings.model.isNotEmpty ? settings.model : base.model,
      lang: 'auto',
      prompt: settings.prompt,
      vad: vad,
      vadModel: vad ? vadModelPath : '',
    );
  }

  /// Модель тишины весит меньше мегабайта и качается один раз. Не вышло —
  /// диктуем без неё: галлюцинации на тишине хуже, чем ничего, но молчащая
  /// диктовка хуже вдвойне.
  Future<void> _ensureVad() async {
    if (File(vadModelPath).existsSync() || vadDownload != null) return;
    final d = Download(vadModelUrl, vadModelPath);
    vadDownload = d;
    vadError = null;
    notifyListeners();
    final path = await d.run(onProgress: notifyListeners);
    vadDownload = null;
    vadError = path == null ? d.error : null;
    notifyListeners();
  }

  /// Повтор после неудачи. Недокачанное лежит в «.part», так что второй
  /// заход продолжит с того же места, а не начнёт сначала.
  Future<void> retryVad() => _ensureVad();

  Future<void> _reloadSettings() async {
    final was = settings;
    settings = DictationSettings.load();
    server.idleTimeout = Duration(seconds: settings.idleSeconds);
    // Подсказку и модель сервер читает при запуске — значит новые он
    // увидит только с новым запуском. Память отдаём сразу, поднимется
    // он снова на следующей фразе.
    if (was.prompt != settings.prompt || was.model != settings.model) {
      server.shutdown();
    }
    await _apply();
  }

  Future<void> _apply() async {
    // Приложение всегда стартует со значком в Dock: LSUIElement в Info.plist
    // спрятал бы его навсегда, а настройка должна переключаться на лету.
    // Значит спрятать его может только Dart, и как можно раньше.
    await platform.setDockIcon((Settings.load()['dockIcon'] as bool?) ?? true);
    await platform.bind(hold: settings.hold, toggle: settings.toggle);
    perms = await platform.permissions();
    notifyListeners();
  }

  Future<void> _refresh() async {
    models = findModels();
    perms = await platform.permissions();
    notifyListeners();
  }

  void _onServerChanged() {
    if (!server.up) memoryMb = 0;
    notifyListeners();
  }

  Future<void> _tickServer() async {
    // Пока разрешения не выданы, спрашиваем о них снова: человек уходит
    // выдавать их в другое приложение и возвращается к открытой панели.
    // Тот же вопрос заново создаёт перехват клавиш — без перезапуска.
    if (!perms.ok) {
      final now = await platform.permissions();
      if (now.input != perms.input || now.insert != perms.insert) {
        perms = now;
        notifyListeners();
      }
    }
    if (!server.up) return;
    memoryMb = await server.footprintMb();
    notifyListeners();
  }

  void _onHotkey(HotkeyEvent e) {
    if (!settings.enabled) return;
    if (e.id == 'hold') {
      e.edge == HotkeyEdge.down ? start() : stop();
      return;
    }
    if (e.edge == HotkeyEdge.down) {
      phase == Phase.recording ? stop() : start();
    }
  }

  Future<void> start() async {
    if (phase != Phase.idle) return;
    // Сервер поднимается параллельно записи: пока человек говорит, модель
    // успевает загрузиться, и после отпускания клавиши ждать уже нечего.
    unawaited(server.ensureUp(options));
    final path = await platform.startRecording();
    if (path == null) return;
    _wav = path;
    _startedAt = DateTime.now();
    phase = Phase.recording;
    if (settings.hud) unawaited(platform.hud(HudState.recording));
    elapsed = Duration.zero;
    _meter = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      level = await platform.level();
      elapsed = DateTime.now().difference(_startedAt ?? DateTime.now());
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> stop() async {
    if (phase != Phase.recording) return;
    _stopMeter();
    phase = Phase.transcribing;
    if (settings.hud) unawaited(platform.hud(HudState.transcribing));
    notifyListeners();

    final path = await platform.stopRecording() ?? _wav;
    _wav = null;
    var ok = false;
    if (path != null) {
      final text = await server.transcribe(path);
      _discard(path);
      if (text.isNotEmpty) {
        last = text;
        // «Только в буфер» — для тех, кто вставит сам и туда, куда решит.
        ok = settings.insert
            ? await platform.insert(text)
            : await copyLast().then((_) => true);
      }
    }
    // Панель уходит с подтверждением, только если было что вставлять:
    // галочка после тишины была бы неправдой.
    await platform.hud(ok ? HudState.done : HudState.hidden);
    phase = Phase.idle;
    notifyListeners();
  }

  /// Передумал. Записанное выбрасываем, ничего не распознаём и не
  /// вставляем — молча, как будто ничего и не начиналось.
  Future<void> cancel() async {
    if (phase != Phase.recording) return;
    _stopMeter();
    phase = Phase.idle;
    unawaited(platform.hud(HudState.hidden));
    notifyListeners();
    _discard(await platform.stopRecording() ?? _wav);
    _wav = null;
  }

  void _stopMeter() {
    _meter?.cancel();
    _meter = null;
    level = 0;
  }

  void _discard(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  // ── правки из панели ──────────────────────────────────────────────────────

  void _save() {
    settings.save();
    notifyListeners();
  }

  void setEnabled(bool v) {
    settings.enabled = v;
    if (!v && phase == Phase.recording) cancel();
    _save();
  }

  void setModel(String path) {
    settings.model = path;
    _save();
    // Модель меняется только перезапуском сервера — но не сейчас, а на
    // следующей фразе: сегодняшнюю память отдаём сразу.
    if (server.up && server.model != path) server.shutdown();
  }

  Future<void> copyLast() async {
    if (last.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: last));
  }

  /// Спасение, когда вставка ушла не в то окно: панель прячется, фокус
  /// возвращается прежнему приложению, и текст идёт туда.
  Future<void> insertAgain() async {
    if (last.isEmpty) return;
    await platform.hidePanel();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    await platform.insert(last);
  }

  void unload() => server.shutdown();

  Future<void> openMainWindow() => platform.openMainWindow();

  Future<void> openPermission(String which) => platform.openPermission(which);

  Future<void> quit() => platform.quit();
}

// ── интерфейс ───────────────────────────────────────────────────────────────

class PanelApp extends StatelessWidget {
  const PanelApp(this.controller, {super.key});
  final DictationController controller;

  @override
  Widget build(BuildContext context) => MacosApp(
        title: appName,
        theme: MacosThemeData.light(),
        darkTheme: MacosThemeData.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        // Фон рисует NSVisualEffectView под этим слоем — своим здесь
        // ничего не закрашиваем, иначе материал не будет виден.
        color: const Color(0x00000000),
        home: PanelBody(controller),
      );
}

class PanelBody extends StatelessWidget {
  const PanelBody(this.controller, {super.key});
  final DictationController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _Panel(controller),
      );
}

/// Поповер по образцу системных: сверху то, ради чего его открывают,
/// в середине подробности, внизу — уход из панели. Рамок нет, области
/// разделяют волосяные линии, фон — материал под слоем Flutter.
class _Panel extends StatelessWidget {
  const _Panel(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 4),
              children: [
                _Header(c),
                const _Divider(),
                _Live(c),
                _Notices(c),
                const _Divider(),
                _Last(c),
                const _Divider(),
                _Model(c),
              ],
            ),
          ),
          // Действия ухода живут внизу и отделены — так во всех поповерах
          // системы: сначала состояние, в конце «закрыть за собой дверь».
          const _Divider(),
          _Footer(c),
        ],
      );
}

/// Заголовок с главным выключателем. Ради него панель чаще всего и
/// открывают, поэтому он первый и ничем не обвешан.
class _Header extends StatelessWidget {
  const _Header(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Диктовка', style: Type.emptyTitle),
                  const SizedBox(height: 1),
                  Text(
                    c.settings.enabled ? 'Включена' : 'Выключена',
                    style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                  ),
                ],
              ),
            ),
            MacosSwitch(value: c.settings.enabled, onChanged: c.setEnabled),
          ],
        ),
      );
}

/// Крупное главное состояние: «Готово», «Записываю 0:04», «Распознаю…».
/// Под ним — уровень сигнала во время записи и напоминание о клавишах
/// в покое: два размера вместо рамок и подписей.
class _Live extends StatelessWidget {
  const _Live(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final recording = c.phase == Phase.recording;
    final (title, color) = switch (c.phase) {
      Phase.recording => ('Записываю', MacosColors.systemRedColor),
      Phase.transcribing => ('Распознаю…', accent),
      Phase.idle => (
          c.settings.enabled ? 'Готово' : 'Диктовка выключена',
          c.settings.enabled
              ? MacosColors.systemGreenColor
              : Surface.secondaryText(context)
        ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.dur(context, Motion.quick),
                  // По умолчанию AnimatedSwitcher складывает старое и новое
                  // по центру, и главная надпись уезжала от своей точки.
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
                  ),
                  child: Text(title, key: ValueKey(title), style: Type.stateTitle),
                ),
              ),
              if (recording)
                Text(
                  humanDuration(c.elapsed.inMilliseconds),
                  style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                ),
              if (c.phase == Phase.transcribing)
                const SizedBox(width: 14, height: 14, child: ProgressCircle()),
            ],
          ),
          const SizedBox(height: 10),
          if (recording)
            _Meter(level: c.level)
          else
            Text(
              '${c.settings.hold.label} — держать · '
              '${c.settings.toggle.label} — нажать',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
        ],
      ),
    );
  }
}

/// Уровень сигнала: не столбики-эквалайзер, а одна полоса — она отвечает
/// на единственный вопрос «меня вообще слышно?».
class _Meter extends StatelessWidget {
  const _Meter({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Surface.hover(context))),
            AnimatedFractionallySizedBox(
              duration: Motion.dur(context, const Duration(milliseconds: 120)),
              curve: Curves.easeOut,
              widthFactor: level.clamp(0, 1),
              child: ColoredBox(color: accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// То, что требует внимания: невыданные разрешения и модель тишины.
/// В спокойном состоянии этого блока нет вовсе.
class _Notices extends StatelessWidget {
  const _Notices(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final d = c.vadDownload;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          // Разрешения выдаются по одному, и просить сразу оба — значит
          // напугать вдвое. «Универсальный доступ» просим первым: он нужен
          // и для вставки, и обычно открывает перехват клавиш.
          if (!c.perms.insert)
            _Warning(
              'Без «Универсального доступа» tsukiko не перехватывает клавиши '
              'и не вставляет текст в активное окно.',
              onPressed: () => c.openPermission('insert'),
            )
          else if (!c.perms.input)
            _Warning(
              'Не хватает «Мониторинга ввода» — клавиши не перехватываются.',
              onPressed: () => c.openPermission('input'),
            ),
          if (d != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Загружаем распознавание тишины · ${d.progressLabel}',
                style: Type.caption.copyWith(color: Surface.secondaryText(context)),
              ),
            )
          else if (c.vadError != null)
            _Warning(
              'Распознавание тишины не загрузилось: ${c.vadError}. '
              'Диктовать можно и так, но на паузах модель дописывает лишнее.',
              button: 'Попробовать ещё раз',
              onPressed: c.retryVad,
            ),
        ],
      ),
    );
  }
}

class _Last extends StatelessWidget {
  const _Last(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Последняя расшифровка',
                style: Type.caption.copyWith(color: Surface.secondaryText(context))),
            const SizedBox(height: 5),
            Text(
              c.last.isEmpty ? 'Пока ничего не надиктовано.' : c.last,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: c.last.isEmpty
                  ? Type.control.copyWith(color: Surface.secondaryText(context))
                  : Type.control,
            ),
            // Кнопки без текста нечего делать: пустая пара мертвецов только
            // занимает место в и без того тесном поповере.
            if (c.last.isNotEmpty) ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: c.copyLast,
                    child: const Text('Скопировать'),
                  ),
                  const SizedBox(width: 6),
                  PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: c.insertAgain,
                    child: const Text('Вставить снова'),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
}

/// Модель: что загружено, сколько занимает и когда освободится. Та самая
/// причина, по которой панель вообще нужна.
class _Model extends StatelessWidget {
  const _Model(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final pair = modelPair(c.models);
    final left = c.server.untilUnload;
    final grey = Type.caption.copyWith(color: Surface.secondaryText(context));

    final state = !c.server.up
        ? 'Выгружена'
        : [
            if (c.memoryMb > 0)
              '${(c.memoryMb / 1024).toStringAsFixed(1).replaceAll('.', ',')} ГБ в памяти'
            else
              'В памяти',
            if (left != null) 'освободится через ${humanDuration(left.inMilliseconds)}',
          ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  pair.fast.isEmpty
                      ? 'Модель не найдена'
                      : modelShortName(
                          c.settings.model.isNotEmpty ? c.settings.model : c.options.model),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.fileName,
                ),
              ),
              if (c.server.up)
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: c.unload,
                  child: const Text('Выгрузить'),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(pair.fast.isEmpty ? 'Распознавать нечем' : state, style: grey),
          // Переключать нечего, пока модель одна: мёртвый переключатель
          // врёт, будто выбор есть.
          if (pair.fast.isNotEmpty && pair.fast != pair.accurate) ...[
            const SizedBox(height: 9),
            _Segmented(
              options: [
                (pair.fast, 'Быстрая'),
                (pair.accurate, 'Точная'),
              ],
              value: (c.settings.model.isNotEmpty ? c.settings.model : c.options.model) ==
                      pair.accurate
                  ? pair.accurate
                  : pair.fast,
              onChanged: c.setModel,
            ),
          ],
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
        child: Column(
          children: [
            _MenuRow('Открыть tsukiko…', c.openMainWindow),
            _MenuRow('Завершить tsukiko', c.quit, shortcut: '⌘Q'),
          ],
        ),
      );
}

// ── мелочи ──────────────────────────────────────────────────────────────────

/// Волосяная линия во всю ширину: в поповерах системы области разделяет
/// именно она, а не рамка вокруг каждой.
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: Surface.hairline(context));
}

/// Строка-действие как в системном меню: подсветка во всю ширину под
/// курсором, ярлык справа.
class _MenuRow extends StatefulWidget {
  const _MenuRow(this.label, this.onTap, {this.shortcut});
  final String label;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? accent : MacosColors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: Type.control.copyWith(color: _hover ? MacosColors.white : null),
                ),
              ),
              if (widget.shortcut != null)
                Text(
                  widget.shortcut!,
                  style: Type.control.copyWith(
                    color: _hover ? MacosColors.white : Surface.secondaryText(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Переключатель из двух-трёх равных вариантов. В macos_ui такой есть,
/// но он завязан на MacosTabController, а здесь состояние приходит извне.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(String, String)> options;
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Surface.isDark(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Surface.hover(context),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          for (final (id, label) in options)
            Expanded(
              child: GestureDetector(
                onTap: onChanged == null ? null : () => onChanged!(id),
                child: AnimatedContainer(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    color: id == value
                        ? (dark ? const Color(0xFF55585E) : MacosColors.white)
                        : MacosColors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: id == value
                        ? const [
                            BoxShadow(
                              color: Color(0x1A000000),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            )
                          ]
                        : null,
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.control.copyWith(
                      color: onChanged == null ? Surface.secondaryText(context) : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text, {required this.onPressed, this.button = 'Открыть настройки'});
  final String text;
  final String button;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
        decoration: BoxDecoration(
          color: MacosColors.systemOrangeColor.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: Type.caption.copyWith(height: 1.35)),
            const SizedBox(height: 7),
            PushButton(
              controlSize: ControlSize.small,
              secondary: true,
              onPressed: onPressed,
              child: Text(button),
            ),
          ],
        ),
      );
}
