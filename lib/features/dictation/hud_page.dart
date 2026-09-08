import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:macos_ui/macos_ui.dart';

import '../../core/app_locale.dart';
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';

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
  }

  @override
  void dispose() {
    _states?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _onState(HudState state) {
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
    return Container(
      height: 52,
      // Поля шире, чем кажется нужным: содержимое, прижатое к скруглённому
      // краю, читается теснее, чем стоит на самом деле.
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Surface.chrome(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Surface.hairline(context)),
      ),
      child: Row(children: _content(l10n)),
    );
  }

  List<Widget> _content(AppLocalizations l10n) => switch (_state) {
        HudState.transcribing => [
            const ProgressCircle(radius: 7),
            const SizedBox(width: 12),
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
            _Meter(levels: _levels),
            const SizedBox(width: 12),
            Text(_time,
                style: _label.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()])),
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
        MacosIcon(icon, size: 15, color: color),
        const SizedBox(width: 12),
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
            if (i > 0) const SizedBox(width: 2),
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              widget.title,
              style: const TextStyle(fontSize: 12).copyWith(
                color: widget.filled ? MacosColors.white : null,
              ),
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
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? Surface.hover(context) : null,
            ),
            child: MacosIcon(
              widget.icon,
              size: 11,
              color: Surface.secondaryText(context)
                  .withValues(alpha: _hover ? 0.9 : 0.4),
            ),
          ),
        ),
      );
}
