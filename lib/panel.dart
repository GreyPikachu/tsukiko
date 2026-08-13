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

class _Panel extends StatelessWidget {
  const _Panel(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      children: [
        _Head(c),
        if (!c.perms.ok) ...[
          const SizedBox(height: 10),
          // Разрешения выдаются по одному, и просить сразу оба — значит
          // напугать вдвое. «Универсальный доступ» просим первым: он
          // нужен и для вставки, и обычно открывает перехват клавиш.
          if (!c.perms.insert)
            _Warning(
              'Без «Универсального доступа» tsukiko не перехватывает клавиши '
              'и не вставляет текст в активное окно.',
              onPressed: () => c.openPermission('insert'),
            )
          else
            _Warning(
              'Не хватает «Мониторинга ввода» — клавиши не перехватываются.',
              onPressed: () => c.openPermission('input'),
            ),
        ],
        const SizedBox(height: 12),
        _Live(c),
        if (c.vadDownload != null) ...[
          const SizedBox(height: 8),
          Text(
            'Загружаем распознавание тишины · ${c.vadDownload!.progressLabel}',
            style: Type.caption.copyWith(color: Surface.secondaryText(context)),
          ),
        ] else if (c.vadError != null) ...[
          const SizedBox(height: 8),
          _Warning(
            'Распознавание тишины не загрузилось: ${c.vadError}. '
            'Диктовать можно и так, но на паузах модель дописывает лишнее. '
            'Проверьте связь и попробуйте ещё раз.',
            button: 'Попробовать ещё раз',
            onPressed: c.retryVad,
          ),
        ],
        const SizedBox(height: 12),
        _Last(c),
        const SizedBox(height: 12),
        _Memory(c),
        const SizedBox(height: 12),
        _Models(c),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Link('Открыть tsukiko', c.openMainWindow),
          ],
        ),
      ],
    );
  }
}

/// Крупный переключатель — единственное, ради чего панель открывают чаще
/// всего. Поэтому он стоит первым и ничем не обвешан.
class _Head extends StatelessWidget {
  const _Head(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Диктовка', style: Type.emptyTitle),
                const SizedBox(height: 2),
                Text(
                  c.settings.enabled ? 'Включена' : 'Выключена',
                  style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                ),
              ],
            ),
          ),
          MacosSwitch(value: c.settings.enabled, onChanged: c.setEnabled),
        ],
      );
}

/// Живое состояние: «Готово» · «Записываю 0:04» с уровнем · «Распознаю…».
class _Live extends StatelessWidget {
  const _Live(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final (title, color) = switch (c.phase) {
      Phase.recording => (
          'Записываю ${humanDuration(c.elapsed.inMilliseconds)}',
          MacosColors.systemRedColor
        ),
      Phase.transcribing => ('Распознаю…', accent),
      Phase.idle => (
          c.settings.enabled ? 'Готово' : 'Диктовка выключена',
          c.settings.enabled ? MacosColors.systemGreenColor : Surface.secondaryText(context)
        ),
    };

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.dur(context, Motion.quick),
                  child: Text(title, key: ValueKey(title), style: Type.fileName),
                ),
              ),
              if (c.phase == Phase.transcribing)
                const SizedBox(width: 14, height: 14, child: ProgressCircle()),
            ],
          ),
          const SizedBox(height: 9),
          _Meter(level: c.phase == Phase.recording ? c.level : 0),
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

class _Last extends StatelessWidget {
  const _Last(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ПОСЛЕДНЯЯ РАСШИФРОВКА',
                style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context))),
            const SizedBox(height: 6),
            Text(
              c.last.isEmpty ? 'Пока ничего не надиктовано.' : c.last,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: c.last.isEmpty
                  ? Type.control.copyWith(color: Surface.secondaryText(context))
                  : Type.control,
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: c.last.isEmpty ? null : c.copyLast,
                  child: const Text('Скопировать'),
                ),
                const SizedBox(width: 6),
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: c.last.isEmpty ? null : c.insertAgain,
                  child: const Text('Вставить снова'),
                ),
              ],
            ),
          ],
        ),
      );
}

/// Память — та самая причина, по которой панель вообще нужна: видно,
/// сколько занято и когда освободится, и можно освободить прямо сейчас.
class _Memory extends StatelessWidget {
  const _Memory(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final left = c.server.untilUnload;
    final parts = [
      'В памяти',
      if (c.memoryMb > 0) '${(c.memoryMb / 1024).toStringAsFixed(1).replaceAll('.', ',')} ГБ',
      if (left != null) 'освободится через ${humanDuration(left.inMilliseconds)}',
    ];

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('МОДЕЛЬ',
              style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context))),
          const SizedBox(height: 6),
          Text(
            c.server.up ? parts.join(' · ') : 'Выгружена',
            style: Type.control,
          ),
          if (c.server.up) ...[
            const SizedBox(height: 9),
            PushButton(
              controlSize: ControlSize.small,
              secondary: true,
              onPressed: c.unload,
              child: const Text('Выгрузить сейчас'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Models extends StatelessWidget {
  const _Models(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final pair = modelPair(c.models);
    if (pair.fast.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Модель не найдена — распознавать нечем',
              style: Type.caption.copyWith(color: Surface.secondaryText(context))),
          const SizedBox(height: 4),
          _Link('Загрузить модель…', c.openMainWindow),
        ],
      );
    }

    // Модель одна — переключать нечего, и мёртвый переключатель только врёт,
    // будто выбор есть. Показываем, что нашлось, и путь за второй моделью.
    if (pair.fast == pair.accurate) {
      return Row(
        children: [
          Expanded(
            child: Text(
              '${modelShortName(pair.fast)} · ${modelSizeLabel(pair.fast)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.control,
            ),
          ),
          const SizedBox(width: 8),
          _Link('Загрузить другую…', c.openMainWindow),
        ],
      );
    }

    final current = c.settings.model.isNotEmpty ? c.settings.model : c.options.model;
    return _Segmented(
      options: [
        (pair.fast, 'Быстрая · ${modelShortName(pair.fast)}'),
        (pair.accurate, 'Точная · ${modelShortName(pair.accurate)}'),
      ],
      value: current == pair.accurate ? pair.accurate : pair.fast,
      onChanged: c.setModel,
    );
  }
}

// ── мелочи ──────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          color: Surface.hover(context),
          borderRadius: BorderRadius.circular(9),
        ),
        child: child,
      );
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

class _Link extends StatefulWidget {
  const _Link(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Text(
            widget.label,
            style: Type.caption.copyWith(
              color: MacosTheme.of(context).primaryColor,
              decoration: _hover ? TextDecoration.underline : null,
            ),
          ),
        ),
      );
}
