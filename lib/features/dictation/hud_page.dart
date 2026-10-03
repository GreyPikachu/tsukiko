import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:macos_ui/macos_ui.dart';

import '../../core/app_locale.dart';
import '../../core/logger.dart';
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';

/// Плавающая панель записи — та, что приходит сама, пока человек диктует.
///
/// Отвечает на единственный вопрос: «система меня слышит и работает?» —
/// и уходит, как только ответила.
///
/// На macOS та же панель написана на SwiftUI и остаётся там: она стоит
/// на системном материале окна (`NSVisualEffectView`, размытие того, что
/// **за** окном) и на неактивирующей `NSPanel`. Ни того, ни другого Flutter
/// не рисует — он размывает лишь то, что нарисовал сам, — а отдельный
/// движок под неё стоит около 110 МБ памяти (замерено) как раз тогда,
/// когда модель занимает полтора гигабайта. Здесь это оправдано: своей
/// панели на Windows не было вовсе.
Future<void> runHud() async {
  Log.info(
    'App',
    'runHud started on ${os.platformId} (${Platform.operatingSystemVersion}), Tsukiko $appVersion',
  );
  refreshLocale();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HudApp());
}

class HudApp extends StatelessWidget {
  const HudApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
    valueListenable: appLocale,
    builder: (context, locale, _) => MacosApp(
      locale: locale,
      theme: MacosThemeData.light(),
      darkTheme: MacosThemeData.dark(),
      themeMode: ThemeMode.system,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HudView(),
    ),
  );
}

class HudView extends StatefulWidget {
  const HudView({super.key, this.bridge});

  /// Свой мост нужен только тестам: в приложении он один на изолят.
  final NativeBridge? bridge;

  @override
  State<HudView> createState() => _HudViewState();
}

class _HudViewState extends State<HudView> {
  late final NativeBridge _bridge = widget.bridge ?? NativeBridge();
  StreamSubscription<HudState>? _states;
  Timer? _ticker;
  StreamSubscription<Map<String, dynamic>>? _queue;
  StreamSubscription<Map<String, dynamic>>? _layout;
  bool _editing = false;
  double _scale = 1;
  Offset _drag = Offset.zero;
  int _pending = 0;
  bool _processing = false;

  HudState _state = HudState.hidden;
  Duration _elapsed = Duration.zero;
  DateTime? _startedAt;

  /// История уровня: полоски бегут справа налево, как настоящий сигнал.
  List<double> _levels = List.filled(_bars, 0);
  static const _bars = 22;

  @override
  void initState() {
    super.initState();
    _states = _bridge.hudStates.listen(_onState);
    _queue = _bridge.hudQueue.listen(_onQueue);
    _layout = _bridge.hudLayout.listen(_onLayout);
    _bridge.currentHudLayout().then(_onLayout);
    _bridge.currentHudQueue().then(_onQueue);
    _queryInitialState();
  }

  Future<void> _queryInitialState() async {
    try {
      final state = await _bridge.currentHudState();
      if (state != null && mounted) {
        _onState(state);
      }
    } catch (_) {
      // Игнорируем ошибку опроса начального состояния
    }
  }

  @override
  void dispose() {
    _states?.cancel();
    _queue?.cancel();
    _layout?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _onLayout(Map<String, dynamic> layout) {
    if (!mounted) return;
    setState(() {
      _editing = layout['editing'] == true;
      final scale = (layout['scaleValue'] as num?)?.toDouble() ?? 1;
      _scale = scale.isFinite ? scale.clamp(.8, 1.6) : 1;
    });
  }

  Widget _draggable(Widget child) => MouseRegion(
    cursor: SystemMouseCursors.move,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _drag = Offset.zero,
      onPanUpdate: (event) {
        _drag += event.delta;
        _bridge.changeHudLayout({'dx': _drag.dx, 'dy': _drag.dy, 'end': false});
      },
      onPanEnd: (_) => _bridge.changeHudLayout({
        'dx': _drag.dx,
        'dy': _drag.dy,
        'end': true,
      }),
      onPanCancel: () => _bridge.changeHudLayout({
        'dx': _drag.dx,
        'dy': _drag.dy,
        'end': true,
      }),
      child: child,
    ),
  );

  void _onQueue(Map<String, dynamic> queue) {
    if (!mounted) return;
    setState(() {
      _pending = (queue['pending'] as num?)?.toInt() ?? 0;
      _processing = queue['processing'] == true;
    });
  }

  void _onState(HudState state) {
    if (state == _state) return;
    if (!mounted) return;
    setState(() {
      _state = state;
      if (state == HudState.recording) {
        _startedAt = DateTime.now();
        _elapsed = Duration.zero;
        _levels = List.filled(_bars, 0);
      }
    });
    // Уровень нужен только пока пишут: в остальных состояниях панель
    // ничего не слушает, и опрос был бы работой впустую.
    state == HudState.recording ? _startTicker() : _stopTicker();
  }

  /// Тридцать раз в секунду — столько же, сколько на macOS: полоски
  /// должны шевелиться, а не дёргаться.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) async {
      final level = await _bridge.level();
      if (!mounted) return;
      setState(() {
        _levels = [..._levels.skip(1), level];
        final started = _startedAt;
        if (started != null) _elapsed = DateTime.now().difference(started);
      });
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  String get _time {
    final total = _elapsed.inSeconds;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = _editing ? 600.0 : MediaQuery.sizeOf(context).width / _scale;
    final height = _editing ? 156.0 : 52.0;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (!_editing || event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _bridge.changeHudLayout({'save': false});
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          _bridge.changeHudLayout({'save': true});
          return KeyEventResult.handled;
        }
        final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
        final delta = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
          LogicalKeyboardKey.arrowRight => Offset(step, 0),
          LogicalKeyboardKey.arrowUp => Offset(0, -step),
          LogicalKeyboardKey.arrowDown => Offset(0, step),
          _ => null,
        };
        if (delta == null) return KeyEventResult.ignored;
        _bridge.changeHudLayout({'nudgeX': delta.dx, 'nudgeY': delta.dy});
        return KeyEventResult.handled;
      },
      child: SizedBox(
        width: width * _scale,
        height: height * _scale,
        child: FittedBox(
          fit: BoxFit.contain,
          child: Container(
            width: width,
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: Gap.edge),
            decoration: BoxDecoration(
              color: Surface.chrome(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Surface.hairline(context)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_editing) ...[
                  _draggable(
                    Text(
                      l10n.hudLayoutTitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.hudLayoutHint,
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      if (_editing) ...[
                        _draggable(_Meter(levels: _levels)),
                        const SizedBox(width: 12),
                        Text(l10n.hudDrag, style: _label),
                        const Spacer(),
                      ] else
                        ..._content(l10n),
                      if (!_editing && (_pending > 0 || _processing))
                        _queueButton(l10n),
                    ],
                  ),
                ),
                if (_editing)
                  Row(
                    children: [
                      Text(l10n.hudScale, style: const TextStyle(fontSize: 11)),
                      Expanded(
                        child: CupertinoSlider(
                          value: _scale,
                          min: .8,
                          max: 1.6,
                          divisions: 8,
                          onChanged: (value) =>
                              _bridge.changeHudLayout({'scaleValue': value}),
                        ),
                      ),
                      Text(
                        '${(_scale * 100).round()}%',
                        style: const TextStyle(fontSize: 11),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: _bridge.resetHud,
                        child: Text(
                          l10n.hudReset,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: () =>
                            _bridge.changeHudLayout({'save': false}),
                        child: Text(
                          l10n.hudCancel,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: () =>
                            _bridge.changeHudLayout({'save': true}),
                        child: Text(
                          l10n.hudSave,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueButton(AppLocalizations l10n) => CupertinoButton(
    padding: const EdgeInsets.only(left: 8),
    minimumSize: const Size(28, 28),
    onPressed: () => _bridge.showHudQueueMenu({
      'record': l10n.hudRecordNext,
      'abort': l10n.hudAbortCurrent,
      'clearQueue': l10n.hudClearQueue,
    }),
    child: Text(
      '${_pending + (_processing ? 1 : 0)}',
      style: _label,
      semanticsLabel: l10n.hudQueueCount(_pending),
    ),
  );

  List<Widget> _content(AppLocalizations l10n) => switch (_state) {
    HudState.transcribing => [
      _draggable(
        const SizedBox(
          width: 24,
          height: 28,
          child: Center(child: ProgressCircle(radius: 7)),
        ),
      ),
      const SizedBox(width: Gap.control),
      Text(l10n.hudTranscribing, style: _label, maxLines: 1),
      const Spacer(),
      // Часовая запись считается минутами, и выйти из этого иначе
      // нельзя ничем. Крестик — то же, чем отменяют загрузку.
      _IconButton(
        icon: CupertinoIcons.xmark,
        onPressed: () => _bridge.hudAction('abort'),
      ),
    ],
    HudState.cancelled => _message(
      CupertinoIcons.xmark_circle_fill,
      Surface.secondaryText(context),
      l10n.hudCancelled,
    ),
    HudState.done => _message(
      CupertinoIcons.checkmark_circle_fill,
      MacosColors.systemGreenColor,
      l10n.hudDone,
    ),
    HudState.failed => _message(
      CupertinoIcons.exclamationmark_triangle_fill,
      MacosColors.systemOrangeColor,
      l10n.hudFailed,
    ),
    HudState.copied => _message(
      CupertinoIcons.doc_on_clipboard,
      MacosColors.systemOrangeColor,
      l10n.hudCopied,
    ),
    HudState.silent => _message(
      CupertinoIcons.mic_slash,
      Surface.secondaryText(context),
      l10n.hudSilent,
    ),
    _ => [
      _draggable(_Meter(levels: _levels)),
      const SizedBox(width: Gap.control),
      Text(
        _time,
        style: _label.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      const Spacer(),
      _HudButton(
        title: l10n.hudCancel,
        filled: false,
        onPressed: () => _bridge.hudAction('cancel'),
      ),
      const SizedBox(width: Gap.inner),
      _HudButton(
        title: l10n.hudStop,
        filled: true,
        onPressed: () => _bridge.hudAction('stop'),
      ),
    ],
  };

  List<Widget> _message(IconData icon, Color color, String text) => [
    MacosIcon(icon, size: IconSize.button, color: color),
    const SizedBox(width: Gap.control),
    Text(text, style: _label, maxLines: 1),
    const Spacer(),
  ];
}

/// Подпись на панели: те же 13 пунктов средней насыщенности, что
/// и в SwiftUI-версии.
const _label = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

/// Уровень сигнала полосками. Это не украшение: пока они шевелятся,
/// видно, что микрофон действительно слышит, а не пишет тишину.
class _Meter extends StatelessWidget {
  const _Meter({required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final color = Surface.isDark(context)
        ? const Color(0x8CFFFFFF)
        : const Color(0x8C000000);
    return SizedBox(
      width: 100,
      height: 26,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final (i, level) in levels.indexed) ...[
            if (i > 0) const SizedBox(width: Gap.tight),
            AnimatedContainer(
              duration: Motion.dur(context, Motion.quick),
              curve: Motion.curve(context, Motion.quickCurve),
              width: 2.5,
              height: (level * 24).clamp(2.5, 24),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1.25),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HudButton extends StatefulWidget {
  const _HudButton({
    required this.title,
    required this.filled,
    required this.onPressed,
  });
  final String title;
  final bool filled;
  final VoidCallback onPressed;

  @override
  State<_HudButton> createState() => _HudButtonState();
}

class _HudButtonState extends State<_HudButton> {
  bool _hover = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final background = widget.filled
        ? (_hover ? accent.withValues(alpha: 0.9) : accent)
        : _pressed
        ? Surface.pressed(context)
        : _hover
        ? Surface.hover(context)
        : Surface.hairline(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Отклик на нажатие, а не на отпускании: задержка убивает
        // ощущение прямоты.
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: Gap.control),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              widget.title,
              style: const TextStyle(
                fontSize: 12,
              ).copyWith(color: widget.filled ? MacosColors.white : null),
            ),
          ),
        ),
      ),
    );
  }
}

/// Крестик отмены. Не кнопка с подписью: действие редкое, и громкая
/// кнопка рядом с «Распознаю…» читалась бы как основное намерение.
class _IconButton extends StatefulWidget {
  const _IconButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onPressed,
      child: Container(
        // Кружок шире значка на [Gap.inner]: полоса низкая, и
        // мимо мелкой цели тут промахиваются чаще всего.
        width: IconSize.button + Gap.inner,
        height: IconSize.button + Gap.inner,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _hover ? Surface.hover(context) : null,
        ),
        child: MacosIcon(
          widget.icon,
          size: IconSize.button,
          color: Surface.secondaryText(
            context,
          ).withValues(alpha: _hover ? 0.9 : 0.4),
        ),
      ),
    ),
  );
}
