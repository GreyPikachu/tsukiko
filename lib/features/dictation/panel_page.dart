import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../platform/bridge.dart';
import '../../platform/os.dart';
import '../../design/design.dart';
import '../../core/logger.dart';
import '../../core/whisper_server.dart' show sweepRecordings;
import 'dictation_cubit.dart';
import 'dictation_history.dart';
import 'dictation_state.dart';
import '../../core/app_locale.dart';
import '../../core/models.dart';
import '../../core/text.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../legacy_migration.dart';
import '../../core/labels.dart';
import '../../core/library.dart' show revealInFinder;
import '../../core/settings.dart';

/// Панель у строки меню и вся диктовка. Живёт на отдельном движке Flutter,
/// который работает и со спрятанной панелью, — поэтому диктовка не зависит
/// от того, открыто ли главное окно.
///
/// Состоянием владеет [DictationCubit]; здесь только то, что рисуется.
Future<void> runPanel() async {
  Log.info(
    'App',
    'runPanel started on ${os.platformId} (${Platform.operatingSystemVersion}), Tsukiko $appVersion',
  );
  refreshLocale();
  WidgetsFlutterBinding.ensureInitialized();
  sweepRecordings();
  // Модели прежней установки переезжают к нам до того, как кто-нибудь
  // спросит их список. Какой из движков стартует первым — не наше дело,
  // поэтому переезд зовут обе точки входа, и он идемпотентен.
  await migrateLegacyModels();
  runApp(const PanelApp());
}

// ── интерфейс ───────────────────────────────────────────────────────────────

class PanelApp extends StatelessWidget {
  const PanelApp({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => DictationCubit(NativeBridge()),
        child: const _PanelApp(),
      );
}

class _PanelApp extends StatelessWidget {
  const _PanelApp();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Locale?>(
        valueListenable: appLocale,
        builder: (context, locale, _) => MacosApp(
          locale: locale,
          title: appName,
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: ThemeMode.system,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Фон рисует NSVisualEffectView под этим слоем — своим здесь
          // ничего не закрашиваем, иначе материал не будет виден.
          color: const Color(0x00000000),
          home: const PanelBody(),
        ),
      );
}

class PanelBody extends StatelessWidget {
  const PanelBody({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<DictationCubit, DictationState>(
        builder: (context, state) => _Panel(state),
      );
}

/// Поповер по образцу системных: сверху то, ради чего его открывают,
/// в середине подробности, внизу — уход из панели. Рамок нет, области
/// разделяют волосяные линии, фон — материал под слоем Flutter.
///
/// Высота окна — не константа, а высота этого столбца: предупреждения
/// приходят и уходят, расшифровка бывает в три строки и в ноль, и панель
/// с запасом «на всякий случай» зияла бы пустотой посередине. Меряем
/// после раскладки и сообщаем macOS — окно растёт вниз от значка.
class _Panel extends StatefulWidget {
  const _Panel(this.state);
  final DictationState state;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  // Ключ и последняя сообщённая высота — поля состояния, а не статика
  // виджета. Статика работала лишь потому, что панель в приложении одна:
  // второй экземпляр (тест, будущий второй поповер) молча делил бы
  // с первым и ключ, и «уже сообщённую» высоту.
  final _content = GlobalKey();
  double _reported = 0;

  DictationState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    // Кадр за кадром одно и то же число дёргало бы окно на каждой секунде
    // обратного отсчёта: шлём только при настоящем изменении.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final h = _content.currentContext?.size?.height.ceilToDouble();
      if (h == null || h == _reported) return;
      _reported = h;
      unawaited(context.read<DictationCubit>().reportHeight(h));
    });

    // Фон панели. На macOS под слоем Flutter стоит материал окна, и
    // красить нечего; на Windows под ним нет ничего — панель выходила
    // чёрным прямоугольником у значка.
    final ground = Surface.sidebar(context);
    final body = SingleChildScrollView(
      child: Column(
        key: _content,
        mainAxisSize: MainAxisSize.min,
        // Без растяжения по ширине блоки съёжились бы до своего текста
        // и встали по центру: раньше ширину задавал ListView.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(s),
          const _Divider(),
          _Live(s),
          _Notices(s),
          const _Divider(),
          _History(s),
          const _Divider(),
          _Model(s),
          // Действия ухода живут внизу и отделены — так во всех поповерах
          // системы: сначала состояние, в конце «закрыть за собой дверь».
          const _Divider(),
          _Footer(s),
        ],
      ),
    );
    return ground == null ? body : ColoredBox(color: ground, child: body);
  }
}

/// Заголовок с главным выключателем. Ради него панель чаще всего и
/// открывают, поэтому он первый и ничем не обвешан.
class _Header extends StatelessWidget {
  const _Header(this.s);
  final DictationState s;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
        padding: const EdgeInsets.fromLTRB(
            Gap.edgeNarrow, Gap.item, Gap.edgeNarrow, Gap.item),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsTabDictation, style: Type.emptyTitle),
                  const SizedBox(height: Gap.tight),
                  Text(
                    s.enabled ? l10n.dictationEnabledState : l10n.dictationDisabledState,
                    style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                  ),
                ],
              ),
            ),
            MacosSwitch(
              value: s.enabled,
              onChanged: context.read<DictationCubit>().setEnabled,
            ),
          ],
        ),
      );
  }
}

/// Крупное главное состояние: «Готово», «Записываю 0:04», «Распознаю…».
/// Под ним — уровень сигнала во время записи и напоминание о клавишах
/// в покое: два размера вместо рамок и подписей.
class _Live extends StatelessWidget {
  const _Live(this.s);
  final DictationState s;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = MacosTheme.of(context).primaryColor;
    final recording = s.recording;
    final (title, color) = switch (s.phase) {
      Phase.recording => (l10n.liveRecording, MacosColors.systemRedColor),
      Phase.transcribing => (l10n.liveTranscribing, accent),
      Phase.idle => (
          s.enabled ? l10n.liveReady : l10n.liveDictationOff,
          s.enabled
              ? MacosColors.systemGreenColor
              : Surface.secondaryText(context)
        ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Gap.edgeNarrow, Gap.item, Gap.edgeNarrow, Gap.item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                // Тот же поперечник, что у точки состояния модели в
                // главном окне: одна и та же отметка в двух окнах не
                // имеет права быть разного размера.
                width: Gap.inner,
                height: Gap.inner,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: Gap.inner),
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
                  humanDuration(s.elapsed.inMilliseconds),
                  style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                ),
              if (s.phase == Phase.transcribing) ...[
                const SizedBox(
                    width: IconSize.button,
                    height: IconSize.button,
                    child: ProgressCircle()),
                // Тот же крестик, что и в плавающей панели, и на том же
                // месте относительно прогресса: одно действие — один вид
                // в обеих панелях, искать его дважды не приходится.
                const SizedBox(width: Gap.inner),
                _AbortButton(
                  onPressed: context.read<DictationCubit>().abortTranscription,
                ),
              ],
            ],
          ),
          const SizedBox(height: Gap.item),
          if (recording)
            _Meter(level: s.level)
          else
            _Keys(s),
        ],
      ),
    );
  }
}

/// Чем начать диктовать: по строке на сочетание, каждое — плашкой, как
/// в настройках. Одной строкой через точку они читались как выдуманная
/// подпись, а не как то, что можно поменять. Щелчок ведёт туда, где их
/// и меняют.
class _Keys extends StatefulWidget {
  const _Keys(this.s);
  final DictationState s;

  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final grey = Type.caption.copyWith(color: Surface.secondaryText(context));
    Widget row(String keys, String what) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.hint),
          // Подпись слева, плашка справа — ровно как в настройках, где
          // эти же сочетания и назначают.
          child: Row(
            children: [
              Expanded(child: Text(what, maxLines: 2, style: grey)),
              const SizedBox(width: Gap.inner),
              KeyCap(keys, lit: _hover),
            ],
          ),
        );

    return MacosTooltip(
      message: l10n.tooltipChangeInSettings,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => context.read<DictationCubit>().openSettings('dictation'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row(widget.s.holdLabel, l10n.keyActionHold),
              row(widget.s.toggleLabel, l10n.keyActionToggle),
            ],
          ),
        ),
      ),
    );
  }
}

/// Крестик отмены рядом с индикатором. Не кнопка с подписью: часовую
/// запись прерывают раз в месяц, и громкая кнопка рядом с «Распознаю…»
/// читалась бы как основное намерение. В покое приглушён, под курсором
/// проявляется — есть, когда его ищут, и молчит, когда не нужен.
class _AbortButton extends StatefulWidget {
  const _AbortButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_AbortButton> createState() => _AbortButtonState();
}

class _AbortButtonState extends State<_AbortButton> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) => MacosTooltip(
        message: AppLocalizations.of(context).abortRecognitionAction,
        child: Semantics(
          button: true,
          label: AppLocalizations.of(context).abortRecognitionAction,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              // Отклик на нажатие, а не на отпускании — как везде в панели.
              onTapDown: (_) => setState(() => _down = true),
              onTapUp: (_) => setState(() => _down = false),
              onTapCancel: () => setState(() => _down = false),
              onTap: widget.onPressed,
              child: AnimatedScale(
                duration: Motion.dur(context, Motion.press),
                scale: _down ? 0.94 : 1,
                child: AnimatedContainer(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  // Кружок и значок в нём — ровно те же, что у крестика
                  // плавающей панели: одно действие обязано быть одного
                  // размера в обоих окнах, иначе его ищут заново.
                  width: IconSize.button + Gap.inner,
                  height: IconSize.button + Gap.inner,
                  decoration: BoxDecoration(
                    color: _hover ? Surface.hover(context) : MacosColors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: MacosIcon(
                    CupertinoIcons.xmark,
                    size: IconSize.button,
                    color: Surface.secondaryText(context)
                        .withValues(alpha: _hover ? 1 : 0.55),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
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
        height: Gap.hint,
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
  const _Notices(this.s);
  final DictationState s;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<DictationCubit>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.edgeNarrow),
      child: Column(
        children: [
          // Разрешение одно, и просят его в два приёма: сначала системный
          // запрос — он и заводит tsukiko в списке выключенным, — а уже
          // потом настройки, где остаётся щёлкнуть переключатель.
          if (!s.allowed)
            _Warning(
              l10n.warningNoAccessibility(os.accessibilityName, appName),
              button: l10n.buttonRequestPermission,
              onPressed: cubit.requestPermission,
              second: l10n.buttonOpenSettings,
              onSecond: cubit.openPermissionSettings,
            ),
          // Молчаливая потеря записи — худшее, что может случиться:
          // человек договорил и не получил ничего. Говорим, что случилось
          // и где лежит запись, чтобы её можно было распознать вручную.
          // Есть спасённая запись — ведём к ней и даём убрать её, если она
          // не нужна: удаление идёт в Корзину, поэтому промах не страшен.
          // Текст уцелел и лежит в буфере — предлагаем положить его туда
          // ещё раз.
          if (s.failure != null)
            _Warning(
              s.failure!,
              button: s.failurePath != null
                  ? l10n.buttonShowRecording
                  : s.last.isNotEmpty
                      ? l10n.buttonCopy
                      : null,
              // Ни записи, ни текста — предлагать нечего. Такая беда
              // остаётся просто сообщением и уходит сама.
              onPressed: s.failurePath != null
                  ? cubit.revealFailure
                  : s.last.isNotEmpty
                      ? cubit.copyLast
                      : null,
              second: s.failurePath != null ? l10n.buttonDelete : null,
              onSecond: s.failurePath != null ? cubit.discardFailure : null,
            ),
          if (s.sweptMb > 0)
            _Warning(
              l10n.sweptRecoveredMemory(sizeLabelMb(s.sweptMb)),
              button: l10n.buttonUnderstood,
              onPressed: cubit.forgetSweep,
            ),
          if (s.vadProgress != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.inner),
              child: Text(
                l10n.vadLoadingProgress(s.vadProgress!),
                style: Type.caption.copyWith(color: Surface.secondaryText(context)),
              ),
            )
          else if (s.vadError != null)
            _Warning(
              l10n.vadLoadFailed(s.vadError!),
              button: l10n.buttonRetry,
              onPressed: cubit.retryVad,
            ),
        ],
      ),
    );
  }
}

/// Блок истории диктовок: последняя запись на виду, предыдущие — под аккуратным
/// спойлером с ограничением высоты, чтобы поповер не раздувался за экран.
class _History extends StatefulWidget {
  const _History(this.s);
  final DictationState s;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  bool _expanded = false;

  DictationState get s => widget.s;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<DictationCubit>();
    final history = s.history;
    final hasHistory = history.isNotEmpty;
    final latest = hasHistory ? history.first : null;
    final older = hasHistory && history.length > 1 ? history.sublist(1) : const <DictationEntry>[];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.edgeNarrow,
        vertical: Gap.item,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Заголовок и кнопка очистки всей истории
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.lastTranscriptTitle,
                  style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                ),
              ),
              if (hasHistory)
                MacosTooltip(
                  message: l10n.menuClearHistory,
                  child: Semantics(
                    button: true,
                    label: l10n.menuClearHistory,
                    child: _HistoryActionIcon(
                      icon: CupertinoIcons.trash,
                      size: 13,
                      onTap: () {
                        try {
                          cubit.clearHistory();
                        } catch (e, st) {
                          Log.warn('Panel', 'Ошибка вызова clearHistory: $e', e, st);
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Gap.hint),

          // Последняя расшифровка
          if (!hasHistory)
            Text(
              l10n.noDictationYet,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Type.control.copyWith(color: Surface.secondaryText(context)),
            )
          else ...[
            Text(
              latest!.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Type.control,
            ),
            const SizedBox(height: Gap.item),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: () {
                    try {
                      cubit.copyLast();
                    } catch (e, st) {
                      Log.warn('Panel', 'Ошибка копирования последней записи: $e', e, st);
                    }
                  },
                  child: Text(l10n.buttonCopy),
                ),
                const Spacer(),
                Text(
                  _formatTime(latest.createdAt),
                  style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                ),
              ],
            ),
          ],

          // Предыдущие записи (аккордеон)
          if (older.isNotEmpty) ...[
            const SizedBox(height: Gap.item),
            _AccordionToggle(
              expanded: _expanded,
              count: older.length,
              onToggle: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded) ...[
              const SizedBox(height: Gap.hint),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final entry in older)
                        _HistoryItemRow(
                          key: ValueKey(entry.id),
                          entry: entry,
                          onCopy: () {
                            try {
                              cubit.copyEntry(entry.id);
                            } catch (e, st) {
                              Log.warn('Panel', 'Ошибка копирования записи ${entry.id}: $e', e, st);
                            }
                          },
                          onDelete: () {
                            try {
                              cubit.deleteHistoryEntry(entry.id);
                            } catch (e, st) {
                              Log.warn('Panel', 'Ошибка удаления записи ${entry.id}: $e', e, st);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _AccordionToggle extends StatefulWidget {
  const _AccordionToggle({
    required this.expanded,
    required this.count,
    required this.onToggle,
  });

  final bool expanded;
  final int count;
  final VoidCallback onToggle;

  @override
  State<_AccordionToggle> createState() => _AccordionToggleState();
}

class _AccordionToggleState extends State<_AccordionToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).previousTranscriptsCount(widget.count);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: Gap.hint, horizontal: Gap.inner),
          decoration: BoxDecoration(
            color: _hover ? Surface.hover(context) : MacosColors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Type.caption.copyWith(
                    color: _hover ? MacosTheme.of(context).typography.body.color : Surface.secondaryText(context),
                  ),
                ),
              ),
              MacosIcon(
                widget.expanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                size: 12,
                color: Surface.secondaryText(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryItemRow extends StatefulWidget {
  const _HistoryItemRow({
    super.key,
    required this.entry,
    required this.onCopy,
    required this.onDelete,
  });

  final DictationEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  State<_HistoryItemRow> createState() => _HistoryItemRowState();
}

class _HistoryItemRowState extends State<_HistoryItemRow> {
  bool _hover = false;
  bool _copied = false;

  void _handleCopy() {
    try {
      widget.onCopy();
      setState(() => _copied = true);
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (e, st) {
      Log.warn('Panel', 'Ошибка копирования: $e', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: Gap.hint),
        padding: const EdgeInsets.symmetric(horizontal: Gap.inner, vertical: Gap.hint),
        decoration: BoxDecoration(
          color: _hover ? Surface.hover(context) : MacosColors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Surface.hairline(context),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.entry.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(height: 1.25),
            ),
            const SizedBox(height: Gap.tight),
            Row(
              children: [
                Text(
                  _formatTime(widget.entry.createdAt),
                  style: Type.timestamp.copyWith(
                    color: Surface.secondaryText(context),
                  ),
                ),
                const Spacer(),
                MacosTooltip(
                  message: _copied ? l10n.tooltipCopied : l10n.buttonCopy,
                  child: _HistoryActionIcon(
                    icon: _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
                    size: 13,
                    lit: _copied,
                    onTap: _handleCopy,
                  ),
                ),
                const SizedBox(width: Gap.tight),
                MacosTooltip(
                  message: l10n.buttonDelete,
                  child: _HistoryActionIcon(
                    icon: CupertinoIcons.xmark,
                    size: 11,
                    onTap: widget.onDelete,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryActionIcon extends StatefulWidget {
  const _HistoryActionIcon({
    required this.icon,
    required this.onTap,
    this.size = 14,
    this.lit = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool lit;

  @override
  State<_HistoryActionIcon> createState() => _HistoryActionIconState();
}

class _HistoryActionIconState extends State<_HistoryActionIcon> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: Motion.dur(context, Motion.press),
          scale: _down ? 0.90 : 1.0,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _down
                  ? Surface.pressed(context)
                  : (_hover ? Surface.hover(context) : MacosColors.transparent),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: MacosIcon(
              widget.icon,
              size: widget.size,
              color: widget.lit
                  ? accent
                  : Surface.secondaryText(context).withValues(alpha: _hover ? 1 : 0.65),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Модель: что загружено, сколько занимает и когда освободится. Та самая
/// причина, по которой панель вообще нужна.
class _Model extends StatelessWidget {
  const _Model(this.s);
  final DictationState s;

  @override
  Widget build(BuildContext context) {
    // Всё готовым значением из состояния: считать размеры файлов и читать
    // settings.json на каждом кадре панели здесь было нечем оправдать —
    // во время записи это выходило десять чтений диска в секунду.
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<DictationCubit>();
    final left = s.untilUnload;
    final grey = Type.caption.copyWith(color: Surface.secondaryText(context));

    final serverState = !s.serverUp
        ? l10n.modelUnloaded
        : [
            if (s.memoryMb > 0)
              l10n.modelSizeInMemory(l10n.sizeGb(s.memoryMb / 1024))
            else
              l10n.modelInMemory,
            if (left != null) l10n.modelFreesIn(humanDuration(left.inMilliseconds)),
          ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Gap.edgeNarrow, vertical: Gap.item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Имя модели и есть выбор модели: раньше здесь стояла надпись,
          // а под кнопками — переключатель на два положения, «Быстро ·
          // Точно». Он показывался, только когда моделей ровно две:
          // одна или три — и выбора не было вовсе. Список честнее и
          // работает при любом их числе.
          if (!s.hasModels)
            Text(l10n.modelNotFound,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.fileName)
          else
            SizedBox(width: double.infinity, child: MacosPopupButton<String>(
              value: s.models.contains(s.chosenModel) ? s.chosenModel : null,
              hint: Text(l10n.modelNotChosen, style: Type.fileName),
              items: [
                for (final path in s.models)
                  MacosPopupMenuItem(
                    value: path,
                    // modelLabel, а не modelDisplayName: одна и та же
                    // модель в двух папках дала бы две одинаковые строки,
                    // и какая из них выбрана — не понять.
                    child: Text(modelLabel(path, s.models),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              // Выбранное вступает в силу сразу; сервер при этом
              // перезапускается только если модель правда сменилась —
              // об этом заботится сам cubit.setModel.
              onChanged: (v) => v == null ? null : cubit.setModel(v),
            )),
          const SizedBox(height: Gap.hint),
          Text(!s.hasModels ? l10n.nothingToRecognizeWith : serverState, style: grey),
          // Кнопки под текстом, как в блоке последней расшифровки: два
          // соседних блока, устроенных по-разному, читаются как два разных
          // языка в одной панели.
          const SizedBox(height: Gap.item),
          Row(
            children: [
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: () => cubit.openSettings('models'),
                child: Text(l10n.buttonDownloadAnother),
              ),
              if (s.serverUp) ...[
                const SizedBox(width: Gap.inner),
                // Пока идёт запись или распознавание, модель занята делом,
                // и выгружать её нельзя: кнопка, которая делает вид, что
                // может, — обещание, которого приложение не сдержит.
                MacosTooltip(
                  message: s.phase == Phase.idle
                      ? l10n.tooltipFreeMemoryNextPhrase
                      : l10n.tooltipModelBusy,
                  child: PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: s.phase == Phase.idle ? cubit.unload : null,
                    child: Text(l10n.buttonUnload),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.s);
  final DictationState s;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.hint),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.inner,
              vertical: Gap.hint,
            ),
            child: Row(
              children: [
                _FooterIconButton(
                  icon: CupertinoIcons.waveform_circle,
                  tooltip: l10n.menuOpenRecordingsFolder,
                  onTap: () {
                    final settings = Settings.load();
                    final path =
                        (settings['libraryPath'] as String?)?.isNotEmpty == true
                            ? settings['libraryPath'] as String
                            : os.defaultLibraryPath;
                    revealInFinder(path, createIfMissing: true);
                  },
                ),
                const SizedBox(width: Gap.hint),
                _FooterIconButton(
                  icon: CupertinoIcons.cube_box,
                  tooltip: l10n.menuOpenModelsFolder,
                  onTap: () => revealInFinder(os.modelsDir, createIfMissing: true),
                ),
                const SizedBox(width: Gap.hint),
                _FooterIconButton(
                  icon: CupertinoIcons.doc_plaintext,
                  tooltip: l10n.menuOpenLogsFolder,
                  onTap: () => Log.openLogsFolder(),
                ),
              ],
            ),
          ),
          const _Divider(),
          _MenuRow(
            l10n.menuOpenApp(appName),
            context.read<DictationCubit>().openMainWindow,
          ),
          _MenuRow(
            l10n.menuDictationSettingsEllipsis,
            () => context.read<DictationCubit>().openSettings('dictation'),
            shortcut: os.settingsShortcut,
          ),
          _MenuRow(
            l10n.menuQuitApp(appName),
            context.read<DictationCubit>().quit,
            shortcut: os.hasSystemMenuBar
                ? os.menuShortcut(const ['cmd'], 'q')
                : null,
          ),
        ],
      ),
    );
  }
}

/// Компактная кнопка-значок для нижней панели с тактильным откликом.
class _FooterIconButton extends StatefulWidget {
  const _FooterIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_FooterIconButton> createState() => _FooterIconButtonState();
}

class _FooterIconButtonState extends State<_FooterIconButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) => MacosTooltip(
        message: widget.tooltip,
        child: Semantics(
          button: true,
          label: widget.tooltip,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTapDown: (_) => setState(() => _down = true),
              onTapUp: (_) => setState(() => _down = false),
              onTapCancel: () => setState(() => _down = false),
              onTap: widget.onTap,
              child: AnimatedScale(
                duration: Motion.dur(context, Motion.press),
                scale: _down ? 0.92 : 1.0,
                child: AnimatedContainer(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _down
                        ? Surface.pressed(context)
                        : (_hover
                            ? Surface.hover(context)
                            : MacosColors.transparent),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: MacosIcon(
                    widget.icon,
                    size: IconSize.button,
                    color: Surface.secondaryText(context)
                        .withValues(alpha: _hover ? 1 : 0.65),
                  ),
                ),
              ),
            ),
          ),
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
          // Те же поля, что у строки контекстного меню в главном окне:
          // это один и тот же вид списка команд.
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.inner, vertical: Gap.hint),
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

class _Warning extends StatelessWidget {
  const _Warning(
    this.text, {
    this.onPressed,
    this.button,
    this.second,
    this.onSecond,
  });
  final String text;

  /// Пусто — берём общую подпись «Открыть настройки»: ей отвечают все
  /// нынешние места, кроме тех, что просят своё.
  final String? button;

  /// Пусто — кнопок нет вовсе. Не всякая беда поправима: записи, которой
  /// уже нет, не поможет ни одна кнопка, а мёртвая только обманывает.
  final VoidCallback? onPressed;
  final String? second;
  final VoidCallback? onSecond;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
        margin: const EdgeInsets.only(bottom: Gap.inner),
        // Самостоятельная плашка, поле в ступень «между настройками» —
        // как у ScopeBanner в инспекторе главного окна.
        padding: const EdgeInsets.all(Gap.item),
        decoration: BoxDecoration(
          color: MacosColors.systemOrangeColor.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: Type.caption.copyWith(height: 1.35)),
            if (onPressed != null) ...[
            const SizedBox(height: Gap.item),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onPressed,
                  child: Text(button ?? l10n.buttonOpenSettings),
                ),
                if (second != null) ...[
                  const SizedBox(width: Gap.inner),
                  PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: onSecond,
                    child: Text(second!),
                  ),
                ],
              ],
            ),
            ],
          ],
        ),
      );
  }
}
