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
    platform.panelShown.listen((_) => _refresh());
    _apply();

    // Обратный отсчёт до выгрузки идёт на экране — секунды хватает.
    Timer.periodic(const Duration(seconds: 1), (_) => _tickServer());
    ProcessSignal.sigterm.watch().listen((_) => _bye());
    ProcessSignal.sigint.watch().listen((_) => _bye());
  }

  final MacPlatform platform;
  final DictationSettings settings = DictationSettings.load();
  late final WhisperServer server;

  Phase phase = Phase.idle;
  String last = '';
  double level = 0;
  Duration elapsed = Duration.zero;
  int memoryMb = 0;
  bool accessibility = true;
  List<String> models = findModels();

  String? _wav;
  DateTime? _startedAt;
  Timer? _meter;

  Never _bye() {
    server.shutdown();
    exit(0);
  }

  /// Настройки распознавания диктовки: своё только модель и язык,
  /// остальное — общее с очередью, включая галку VAD.
  RunOptions get options {
    final base = RunOptions.fromJson(
      Settings.load(),
      const RunOptions(model: '', lang: 'auto', threads: 4),
    );
    return base.copyWith(
      model: settings.model.isNotEmpty ? settings.model : base.model,
      lang: settings.lang,
    );
  }

  Future<void> _apply() async {
    await platform.bind(hold: settings.hold, toggle: settings.toggle);
    accessibility = await platform.accessibilityGranted();
    notifyListeners();
  }

  Future<void> _refresh() async {
    models = findModels();
    accessibility = await platform.accessibilityGranted();
    notifyListeners();
  }

  void _onServerChanged() {
    if (!server.up) memoryMb = 0;
    notifyListeners();
  }

  Future<void> _tickServer() async {
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
    _meter?.cancel();
    _meter = null;
    level = 0;
    phase = Phase.transcribing;
    notifyListeners();

    final path = await platform.stopRecording() ?? _wav;
    _wav = null;
    if (path != null) {
      final text = await server.transcribe(path, lang: settings.lang);
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (text.isNotEmpty) {
        last = text;
        await platform.insert(text);
      }
    }
    phase = Phase.idle;
    notifyListeners();
  }

  // ── правки из панели ──────────────────────────────────────────────────────

  void _save() {
    settings.save();
    notifyListeners();
  }

  void setEnabled(bool v) {
    settings.enabled = v;
    if (!v && phase == Phase.recording) stop();
    _save();
  }

  void setLang(String v) {
    settings.lang = v;
    _save();
  }

  void setModel(String path) {
    settings.model = path;
    _save();
    // Модель меняется только перезапуском сервера — но не сейчас, а на
    // следующей фразе: сегодняшнюю память отдаём сразу.
    if (server.up && server.model != path) server.shutdown();
  }

  void setIdleSeconds(int v) {
    settings.idleSeconds = v;
    server.idleTimeout = Duration(seconds: v);
    _save();
  }

  Future<void> reassign(String id) async {
    final hk = await platform.capture();
    if (hk == null) return;
    id == 'hold' ? settings.hold = hk : settings.toggle = hk;
    settings.save();
    await _apply();
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

  Future<void> requestAccessibility() async {
    await platform.accessibilityGranted(prompt: true);
    await _refresh();
  }
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
        if (!c.accessibility) ...[
          const SizedBox(height: 10),
          _Warning(
            'Без «Универсального доступа» клавиши не перехватываются.',
            onPressed: c.requestAccessibility,
          ),
        ],
        const SizedBox(height: 12),
        _Live(c),
        const SizedBox(height: 12),
        _Keys(c),
        const SizedBox(height: 12),
        _Lang(c),
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

class _Keys extends StatelessWidget {
  const _Keys(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          children: [
            _KeyRow(
              'Держать и говорить',
              c.settings.hold.label,
              () => c.reassign('hold'),
            ),
            const SizedBox(height: 8),
            _KeyRow(
              'Нажать · ещё раз — стоп',
              c.settings.toggle.label,
              () => c.reassign('toggle'),
            ),
          ],
        ),
      );
}

class _KeyRow extends StatefulWidget {
  const _KeyRow(this.label, this.keys, this.onTap);
  final String label, keys;
  final VoidCallback onTap;

  @override
  State<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<_KeyRow> {
  bool _hover = false, _waiting = false;

  Future<void> _tap() async {
    setState(() => _waiting = true);
    widget.onTap();
    await Future<void>.delayed(const Duration(seconds: 8));
    if (mounted) setState(() => _waiting = false);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _waiting ? null : _tap,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                ),
              ),
              AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _hover || _waiting
                      ? Surface.pressed(context)
                      : Surface.hover(context),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  _waiting ? 'Нажмите сочетание…' : widget.keys,
                  style: Type.control,
                ),
              ),
            ],
          ),
        ),
      );
}

class _Lang extends StatelessWidget {
  const _Lang(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => _Segmented(
        options: const [
          ('auto', 'Авто'),
          ('ru', 'Русский'),
          ('en', 'English'),
        ],
        value: c.settings.lang,
        onChanged: c.setLang,
      );
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
          const SizedBox(height: 9),
          _Idle(c),
        ],
      ),
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text('Держать в памяти',
                style: Type.caption.copyWith(color: Surface.secondaryText(context))),
          ),
          MacosPopupButton<int>(
            value: c.settings.idleSeconds,
            items: const [
              MacosPopupMenuItem(value: 30, child: Text('30 секунд')),
              MacosPopupMenuItem(value: 60, child: Text('1 минуту')),
              MacosPopupMenuItem(value: 180, child: Text('3 минуты')),
              MacosPopupMenuItem(value: 600, child: Text('10 минут')),
              MacosPopupMenuItem(value: 3600, child: Text('1 час')),
            ],
            onChanged: (v) => c.setIdleSeconds(v ?? 180),
          ),
        ],
      );
}

class _Models extends StatelessWidget {
  const _Models(this.c);
  final DictationController c;

  @override
  Widget build(BuildContext context) {
    final pair = modelPair(c.models);
    if (pair.fast.isEmpty) {
      return Text('Модели не найдены',
          style: Type.caption.copyWith(color: Surface.secondaryText(context)));
    }
    final current = c.settings.model.isNotEmpty ? c.settings.model : c.options.model;
    final same = pair.fast == pair.accurate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Segmented(
          options: [
            (pair.fast, 'Быстрая · ${modelSizeLabel(pair.fast)}'),
            (pair.accurate, 'Точная · ${modelSizeLabel(pair.accurate)}'),
          ],
          value: current == pair.accurate ? pair.accurate : pair.fast,
          onChanged: same ? null : c.setModel,
        ),
        if (same) ...[
          const SizedBox(height: 6),
          Text(
            'Найдена одна модель. Вторую можно добавить в главном окне.',
            style: Type.caption.copyWith(color: Surface.secondaryText(context)),
          ),
        ],
      ],
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
  const _Warning(this.text, {required this.onPressed});
  final String text;
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
              child: const Text('Открыть настройки'),
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
