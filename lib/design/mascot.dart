import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../l10n/gen/app_localizations.dart';
import 'design.dart';

/// Настроения лунного кота. Каждому соответствует свой анимированный webp
/// в assets/mascot — кадры вырезаны покадрово из рисунков автора.
enum Mood {
  /// Пусто, ждём файлы.
  idle,

  /// Файл в очереди, но распознавание не запущено.
  waiting,

  /// Идёт распознавание — кот прислушивается.
  listening,

  /// Модель долго думает над фрагментом.
  thinking,

  /// Тапнули по коту или задание завершилось.
  happy,

  /// Файл тащат в окно.
  surprised,
}

extension _Asset on Mood {
  String get file => switch (this) {
        Mood.idle || Mood.waiting => 'idle',
        Mood.listening => 'listen',
        Mood.thinking => 'think',
        Mood.happy => 'happy',
        Mood.surprised => 'surprise',
      };

  /// Насколько кот «подан вперёд». Возбуждённые состояния крупнее и ярче.
  double get scale => switch (this) {
        Mood.surprised => 1.07,
        Mood.happy => 1.05,
        Mood.listening => 1.02,
        _ => 1.0,
      };

  double get opacity => switch (this) {
        Mood.idle => 0.62,
        Mood.waiting => 0.72,
        Mood.listening || Mood.thinking => 0.9,
        Mood.happy || Mood.surprised => 1.0,
      };

  /// Сила свечения под котом.
  double get glow => switch (this) {
        Mood.idle => 0.10,
        Mood.waiting => 0.14,
        Mood.listening => 0.30,
        Mood.thinking => 0.22,
        Mood.happy => 0.34,
        Mood.surprised => 0.40,
      };
}

/// Лунный кот. Полупрозрачный, реагирует на состояние приложения и на тычок.
///
/// Смена настроения — кроссфейд, потому что кадры сняты из разных сцен и
/// резкая склейка была бы заметна. Поверх статичных кадров идёт лёгкое
/// покачивание, чтобы кот не выглядел приклеенным.
class Mascot extends StatefulWidget {
  const Mascot({
    super.key,
    required this.mood,
    this.height = 132,
    this.interactive = true,
  });

  final Mood mood;
  final double height;

  /// Можно ли тыкать в кота. В углу — да, в вуали перетаскивания — нет.
  final bool interactive;

  @override
  State<Mascot> createState() => _MascotState();
}

class _MascotState extends State<Mascot> with WidgetsBindingObserver {
  /// Настроение, навязанное тычком. Живёт недолго и уступает место обычному.
  Mood? _poke;
  int _pokeToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Mood get _mood => _poke ?? widget.mood;

  void _tap() {
    if (!widget.interactive) return;
    final token = ++_pokeToken;
    setState(() => _poke = Mood.happy);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && token == _pokeToken) setState(() => _poke = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mood = _mood;
    final accent = MacosTheme.of(context).primaryColor;

    // Кадры кота — анимированный webp: каждый новый кадр декодируется и
    // перерисовывает окно, это около 11 % процессора без перерыва. Пока окно
    // не в фокусе, смотреть на кота некому; Image слушает TickerMode и
    // замирает на последнем кадре.
    //
    // Приглушение стоит вплотную к картинке, а не поверх всего кота, и это
    // не мелочь раскладки. Раньше TickerMode накрывал и переходы: смена
    // настроения, начатая при потерянном фокусе, запускала кроссфейд, чей
    // ticker в ту же секунду оказывался приглушён, — и въезжающий кадр
    // застывал прозрачным до самого возвращения фокуса. Со стороны это
    // выглядит так, будто кот пропал совсем: свечение под ним есть, а его
    // самого нет.
    //
    // gaplessPlayback — тот же случай с другой стороны. Смена признака
    // TickerMode это смена унаследованного виджета, а на неё Image заново
    // разрешает свой поток кадров. Без gaplessPlayback он на это время
    // выбрасывает уже показанный кадр и рисует пустоту; с ним — держит
    // последний, пока не придёт следующий.
    Widget cat = TickerMode(
      enabled: WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed,
      child: Image.asset(
        'assets/mascot/${mood.file}.webp',
        height: widget.height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => SizedBox(height: widget.height),
      ),
    );

    // Ключ должен быть на самом верхнем узле, иначе AnimatedSwitcher не
    // заметит смену настроения и кроссфейда не будет.
    cat = KeyedSubtree(key: ValueKey(mood.file), child: cat);

    return Semantics(
        label: AppLocalizations.of(context).semanticsMascotLabel,
        button: widget.interactive,
        child: MouseRegion(
          cursor: widget.interactive
              ? SystemMouseCursors.click
              : MouseCursor.defer,
          child: GestureDetector(
            onTap: _tap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedScale(
              duration: Motion.dur(context, Motion.toss),
              curve: Motion.curve(context, Motion.tossCurve),
              scale: mood.scale,
              child: AnimatedOpacity(
                duration: Motion.dur(context, Motion.settle),
                curve: Motion.curve(context, Motion.settleCurve),
                opacity: mood.opacity,
                child: SizedBox(
                  height: widget.height * 1.18,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      // Свечение живёт отдельным слоем: так его можно гасить,
                      // не трогая прозрачность самого кота.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedContainer(
                            duration: Motion.dur(context, Motion.settle),
                            curve: Motion.curve(context, Motion.settleCurve),
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0, 0.35),
                                radius: 0.78,
                                colors: [
                                  accent.withValues(alpha: mood.glow),
                                  accent.withValues(alpha: mood.glow * 0.35),
                                  accent.withValues(alpha: 0),
                                ],
                                stops: const [0, 0.5, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        child: AnimatedSwitcher(
                          duration: Motion.dur(
                            context,
                            const Duration(milliseconds: 300),
                          ),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.bottomCenter,
                            children: [...previous, ?current],
                          ),
                          child: cat,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
  }
}

/// Кот как заглушка пустого экрана: сам зверь, заголовок и подпись.
class MascotPlaceholder extends StatelessWidget {
  const MascotPlaceholder({
    super.key,
    required this.mood,
    required this.title,
    required this.subtitle,
    this.height = 138,
    this.action,
  });

  final Mood mood;
  final String title, subtitle;
  final double height;

  /// Кнопка под подписью: пустой экран, из которого ничего нельзя сделать, —
  /// тупик, а не подсказка.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Mascot(mood: mood, height: height),
            const SizedBox(height: 16),
            Text(title, style: Type.emptyTitle, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Type.control.copyWith(
                color: Surface.secondaryText(context),
                height: 1.5,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              SizedBox(width: 260, child: action),
            ],
          ],
        ),
      );
}

/// Сопоставляет состояние приложения настроению кота.
Mood moodFor({
  required bool dragging,
  required bool running,
  required bool jobActive,
  required bool hasJobs,
  required bool longWait,
}) {
  if (dragging) return Mood.surprised;
  if (running && jobActive) return longWait ? Mood.thinking : Mood.listening;
  if (hasJobs) return Mood.waiting;
  return Mood.idle;
}
