import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/text.dart';
import '../../core/transcript.dart';
import '../../design/design.dart';
import '../../design/mascot.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'job.dart';
import 'queue_bloc.dart';
import 'queue_event.dart';
import 'queue_state.dart';
import 'widgets/chrome.dart';
import 'widgets/queue_row.dart';
import 'widgets/scope_banner.dart';
import 'widgets/segment_row.dart';

part 'home_menus.dart';

/// Главное окно: очередь, расшифровка и инспектор.
///
/// Состоянием владеет [QueueBloc]; здесь остаётся только то, что относится
/// к самому окну, — фокусы, прокрутка, перетаскивание и панель поиска.
/// Всё, что меняет очередь, уходит событием.
class HomePage extends StatelessWidget {
  const HomePage({super.key, this.initialFiles = const []});
  final Iterable<String> initialFiles;

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => QueueBloc(NativeBridge())..add(FilesAdded(initialFiles)),
        child: const _HomeView(),
      );
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> with WidgetsBindingObserver {
  // Только про окно: очередь, настройки и распознавание живут в блоке.
  final _promptCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _queueFocus = FocusNode(debugLabel: 'очередь');
  final _transcriptScroll = ScrollController();

  bool _dragging = false, _scrolled = false, _findOpen = false;
  String _query = '';

  /// Подсказка модели правится полем ввода, а приходит из состояния:
  /// синхронизируем только когда они разошлись, иначе курсор прыгал бы
  /// на каждую букву.
  String _promptShown = '';

  QueueBloc get _bloc => context.read<QueueBloc>();
  void _send(QueueEvent e) => _bloc.add(e);
  void _sendAll() => _send(const AllSelected());
  void _sendDeselect() => _send(const SelectionCleared());
  void _sendRemove() => _send(const SelectedRemoved());
  void _sendClearFinished() => _send(const FinishedCleared());
  void _sendStart() => _send(const RunRequested());
  void _sendRetry() => _send(const RetryRequested());
  void _sendStop() => _send(const StopRequested());
  void _sendResetOverrides() => _send(const OverridesReset());
  void _sendMakeDefault() => _send(const LeadOptionsMadeDefault());
  void _sendDownload(ModelOffer m) => _send(ModelDownloadRequested(m));
  void _sendEnableVad() => _send(const VadRequested(true));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transcriptScroll.addListener(() {
      final scrolled = _transcriptScroll.hasClients && _transcriptScroll.offset > 6;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    });
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _query) setState(() => _query = _searchCtrl.text);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _send(WindowVisibilityChanged(state == AppLifecycleState.resumed));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _queueFocus.dispose();
    _transcriptScroll.dispose();
    super.dispose();
  }

  /// Поле подсказки следует за выбранной записью, но не мешает набору.
  void _syncPromptField(QueueState s) {
    final text = s.shown.prompt;
    if (text == _promptShown) return;
    _promptShown = text;
    if (_promptCtrl.text == text) return;
    _promptCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Держимся хвоста, пока пользователь сам не отлистал вверх.
  void _followTail() {
    if (!_transcriptScroll.hasClients) return;
    final pos = _transcriptScroll.position;
    if (pos.maxScrollExtent - pos.pixels > 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_transcriptScroll.hasClients) return;
      _transcriptScroll.animateTo(
        _transcriptScroll.position.maxScrollExtent,
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
      );
    });
  }

  // ── диалоги и выбор файлов ────────────────────────────────────────────────
  //
  // Всё, для чего нужно окно: блок про окна не знает и спрашивать человека
  // не умеет — он кладёт вопрос в состояние, а показывает его отсюда.

  void _showAsk(Ask ask) {
    showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: MacosIcon(
          ask.confirm ? CupertinoIcons.waveform_circle : CupertinoIcons.waveform,
          size: 56,
        ),
        title: Text(ask.title, style: Type.emptyTitle),
        message:
            Text(ask.message, textAlign: TextAlign.center, style: Type.control),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            Navigator.pop(dialogContext);
            _send(ask.confirm ? const RunConfirmed(true) : const AskDismissed());
          },
          child: Text(ask.confirm ? 'Продолжить' : 'Понятно'),
        ),
        secondaryButton: ask.confirm
            ? PushButton(
                controlSize: ControlSize.large,
                secondary: true,
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _send(const RunConfirmed(false));
                },
                child: const Text('Отмена'),
              )
            : null,
      ),
    );
  }

  void _about() => showMacosAlertDialog<void>(
        context: context,
        builder: (dialogContext) => MacosAlertDialog(
          appIcon: const MacosIcon(CupertinoIcons.waveform_circle_fill, size: 56),
          title: const Text(appName, style: Type.emptyTitle),
          message: Text(
            'Распознавание речи на самом компьютере.\n'
            'Движок: whisper.cpp · ничего не уходит в сеть.',
            textAlign: TextAlign.center,
            style: Type.control,
          ),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ),
      );

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(
        label: 'Аудио и видео',
        extensions: audioExt.map((e) => e.substring(1)).toList(),
      ),
    ]);
    if (files.isNotEmpty) _send(FilesAdded(files.map((f) => f.path)));
  }

  Future<void> _openTranscript() async {
    final f = await openFile(acceptedTypeGroups: [
      XTypeGroup(
        label: 'Расшифровки',
        extensions: transcriptExt.map((e) => e.substring(1)).toList(),
      ),
    ]);
    if (f != null) _send(TranscriptOpened(f.path));
  }

  /// Выбранный руками файл проверяем: «.bin» лежит на чём угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры — человеку
  /// из неё не понять, что он выбрал не то.
  Future<void> _pickModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML', extensions: ['bin'])]);
    if (f == null) return;
    final problem = modelFileProblem(f.path);
    if (problem != null) return _showAsk(Ask('Это не модель распознавания', problem));
    _send(ModelChosen(f.path));
  }

  Future<void> _saveAs(QueueState s, [ExportFormat? format]) async {
    final f = format ?? formatById(s.saveFormat);
    final jobs = s.readyTargets;
    if (jobs.isEmpty) return;
    // Одна запись — обычный «Сохранить как…»; несколько — выбор папки,
    // потому что спрашивать имя шесть раз подряд невыносимо.
    if (jobs.length > 1) return _exportInto(jobs, [f]);

    final job = jobs.single;
    final loc = await getSaveLocation(
      suggestedName: f.fileName(_stem(job.name)),
      acceptedTypeGroups: [
        XTypeGroup(label: f.label, extensions: [f.ext.substring(1)]),
      ],
    );
    if (loc == null) return;
    // Диалог мог отдать путь без расширения — дописываем сами.
    final path = loc.path.toLowerCase().endsWith(f.ext) ? loc.path : '${loc.path}${f.ext}';
    _send(SaveRequested(job, path, f));
  }

  Future<void> _exportAll(QueueState s) async {
    final jobs = s.readyTargets.isNotEmpty
        ? s.readyTargets
        : s.jobs.where((j) => j.done).toList();
    if (jobs.isEmpty) return;
    await _exportInto(jobs, s.libraryFormats.map(formatById).toList());
  }

  Future<void> _exportInto(List<Job> jobs, List<ExportFormat> formats) async {
    if (formats.isEmpty) return;
    final dir = await getDirectoryPath(confirmButtonText: 'Экспортировать');
    if (dir != null) _send(ExportRequested(jobs, dir, formats));
  }

  String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  void _copy([ExportFormat? format]) {
    final s = _bloc.state;
    _send(CopyRequested(format ?? formatById(s.copyFormat)));
  }

  /// Из главного окна настройки открываются на вкладке расшифровщика:
  /// это его окно, и «Настройки…» отсюда — про него. На диктовку ведёт
  /// её собственная панель у строки меню.
  Future<void> _openSettings([String tab = 'transcriber']) =>
      _bloc.bridge.openSettings(tab);

  /// Показать исходную запись. Её могли убрать мимо приложения — тогда
  /// говорим об этом, а не открываем пустое место.
  Future<void> _revealSource(String path) async {
    if (await revealInFinder(path)) return;
    _send(StatusReported('Файла «${os.basename(path)}» больше нет на диске'));
  }

  // ── как называется занятость ──────────────────────────────────────────────

  String _modelUseBy(QueueState s) => s.transcribing
      ? 'расшифровка'
      : s.dictationHoldsModel
          ? 'диктовка'
          : s.modelUse.by;

  String _modelUseLabel(QueueState s) => s.transcribing
      ? 'Занято расшифровкой'
      : s.dictationHoldsModel
          ? 'Занято диктовкой'
          : s.modelUse.label;

  String _modelUseDetail(QueueState s) => s.transcribing
      ? 'Расшифровываем запись прямо сейчас.'
      : s.dictationHoldsModel
          ? 'Диктовка держит модель в памяти. Очередь ей уступает.'
          : s.modelUse.detail;

  static const _cmd = SingleActivator(LogicalKeyboardKey.keyO, meta: true);

  List<Object?>? _menuSignature;
  List<PlatformMenuItem> _menuCache = const [];

  /// Настроение кота выводится из того, что приложение делает прямо сейчас.
  Mood _mood(QueueState s, Job? job) => moodFor(
        dragging: _dragging,
        running: s.running,
        jobActive: job?.active ?? false,
        hasJobs: job != null,
        longWait: (job?.segments.isEmpty ?? true) && job?.raw == null,
      );

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QueueBloc, QueueState>(
      listenWhen: (was, now) =>
          was.ask != now.ask ||
          was.shown.prompt != now.shown.prompt ||
          (was.lead?.live.length ?? 0) != (now.lead?.live.length ?? 0),
      listener: (context, s) {
        _syncPromptField(s);
        // Новый фрагмент — держимся хвоста, пока человек сам не отлистал.
        if ((s.lead?.live.length ?? 0) > 0) _followTail();
        final ask = s.ask;
        if (ask != null) _showAsk(ask);
      },
      builder: (context, s) => _window(s),
    );
  }

  Widget _window(QueueState s) => PlatformMenuBar(
        menus: _menus(s),
        child: MacosWindow(
          sidebar: Sidebar(
            minWidth: 248,
            startWidth: 276,
            builder: (context, controller) => _queue(s, controller),
            bottom: _queueButtons(s),
          ),
          endSidebar: Sidebar(
            minWidth: 290,
            startWidth: 312,
            maxWidth: 380,
            shownByDefault: true,
            builder: (context, controller) => _inspector(s, controller),
          ),
          child: MacosScaffold(
            toolBar: _toolbar(s),
            children: [
              ContentArea(
                builder: (context, _) => Stack(
                  children: [
                    Positioned.fill(
                      child: Column(children: [
                        if (_findOpen) _findBar(s),
                        Expanded(child: _transcriptArea(s)),
                      ]),
                    ),
                    Positioned(
                        left: 0, right: 0, bottom: 0, child: _statusBar(s)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  ToolBar _toolbar(QueueState s) {
    final ready = s.readyTargets.isNotEmpty;
    final copyFormat = formatById(s.copyFormat);
    final saveFormat = formatById(s.saveFormat);

    return ToolBar(
      title: ToolbarTitle(subtitle: _subtitle(s)),
      titleWidth: 240,
      enableBlur: true,
      // Кромка появляется только когда под панель что-то уехало.
      dividerColor: _scrolled ? Surface.hairline(context) : MacosColors.transparent,
      actions: [
        ToolBarIconButton(
          label: 'Добавить',
          icon: const MacosIcon(CupertinoIcons.add),
          showLabel: false,
          tooltipMessage: 'Добавить аудио · ⌘O',
          onPressed: _pickFiles,
        ),
        ToolBarIconButton(
          label: s.running ? 'Остановить' : 'Распознать',
          icon: MacosIcon(s.running
              ? CupertinoIcons.stop_fill
              : s.yieldBusyModel && s.modelUse.busy
                  ? CupertinoIcons.pause_circle
                  : CupertinoIcons.play_fill),
          showLabel: false,
          tooltipMessage: s.running
              ? (s.waitingForModel
                  ? 'Ожидание: ${_modelUseBy(s)} ещё работает · остановить ⌘.'
                  : 'Остановить · ⌘.')
              : s.yieldBusyModel && s.modelUse.busy
                  ? 'Модель занята (${_modelUseBy(s)}) — распознавание начнётся, как только она освободится · ⌘⏎'
                  : 'Распознать очередь · ⌘⏎',
          onPressed: s.running ? _sendStop : (s.hasPending ? _sendStart : null),
        ),
        ToolBarIconButton(
          label: 'Распознать заново',
          icon: const MacosIcon(CupertinoIcons.arrow_counterclockwise),
          showLabel: false,
          tooltipMessage: 'Распознать заново с текущими настройками · ⌥⌘R',
          onPressed: s.running || !s.targets.any((j) => !j.imported) ? null : _sendRetry,
        ),
        const ToolBarSpacer(spacerUnits: 1),

        // Кнопка повторяет прошлый выбор, стрелка рядом даёт его сменить.
        ToolBarIconButton(
          label: 'Копировать',
          icon: const MacosIcon(CupertinoIcons.doc_on_clipboard),
          showLabel: false,
          tooltipMessage: 'Копировать: ${copyFormat.label.toLowerCase()}',
          onPressed: ready ? () => _copy() : null,
        ),
        ToolBarPullDownButton(
          label: 'Формат копирования',
          icon: CupertinoIcons.doc_on_clipboard,
          tooltipMessage: 'Выбрать, что копировать',
          items: ready
              ? [
                  for (final f in const [formatPlainText, formatTimedText, formatSrt, formatVtt])
                    _formatItem(f, s.copyFormat, () => _copy(f)),
                ]
              : null,
        ),
        ToolBarIconButton(
          label: 'Сохранить',
          icon: const MacosIcon(CupertinoIcons.arrow_down_doc),
          showLabel: false,
          tooltipMessage: 'Сохранить: ${saveFormat.label.toLowerCase()} · ⌘S',
          onPressed: ready ? () => _saveAs(s) : null,
        ),
        ToolBarPullDownButton(
          label: 'Формат сохранения',
          icon: CupertinoIcons.arrow_down_doc,
          tooltipMessage: 'Выбрать формат файла',
          items: ready
              ? [
                  for (final f in exportFormats) _formatItem(f, s.saveFormat, () => _saveAs(s, f)),
                  const MacosPulldownMenuDivider(),
                  MacosPulldownMenuItem(
                    title: const Text('Экспортировать в папку…'),
                    label: 'Экспортировать в папку',
                    onTap: () => _exportAll(s),
                  ),
                ]
              : null,
        ),
        ToolBarIconButton(
          label: 'Найти',
          icon: const MacosIcon(CupertinoIcons.search),
          showLabel: false,
          tooltipMessage: 'Найти в расшифровке · ⌘F',
          onPressed: s.lead == null ? null : _openFind,
        ),
      ],
    );
  }

  /// Панель поиска приходит сверху и уходит по Esc — как в Safari и Xcode,
  /// а не занимает место в панели инструментов всё время.
  Widget _findBar(QueueState s) => Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
        decoration: BoxDecoration(
          color: Surface.chrome(context),
          border: Border(bottom: BorderSide(color: Surface.hairline(context))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    _closeFind();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: MacosSearchField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  placeholder: 'Найти в расшифровке',
                  placeholderStyle: Surface.placeholder(context),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _findSummary(s),
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
            const SizedBox(width: 6),
            MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.xmark, size: 12),
              onPressed: _closeFind,
            ),
          ],
        ),
      );

  String _findSummary(QueueState s) {
    final job = s.lead;
    if (job == null || _query.trim().isEmpty) return 'Esc — закрыть';
    final hits = _visibleSegments(job).length;
    return hits == 0 ? 'Ничего не найдено' : 'Найдено: ${segmentsLabel(hits)}';
  }

  void _openFind() {
    setState(() => _findOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeFind() {
    setState(() {
      _findOpen = false;
      _query = '';
      _searchCtrl.clear();
    });
    _queueFocus.requestFocus();
  }

  /// Галочкой отмечен формат, который повторяет кнопка.
  MacosPulldownMenuItem _formatItem(ExportFormat f, String current, VoidCallback tap) =>
      MacosPulldownMenuItem(
        label: f.label,
        onTap: tap,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              child: f.id == current
                  ? const MacosIcon(CupertinoIcons.checkmark_alt, size: 12)
                  : null,
            ),
            Text(f.label),
          ],
        ),
      );

  String? _subtitle(QueueState s) {
    if (s.selected.length > 1) return 'Выбрано: ${recordsLabel(s.selected.length)}';
    final job = s.lead;
    if (job != null) return job.name;
    if (s.jobs.isEmpty) return null;
    return 'В очереди: ${recordsLabel(s.jobs.length)}';
  }

  // ── очередь ───────────────────────────────────────────────────────────────

  Widget _queue(QueueState s, ScrollController controller) {
    if (s.jobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Text(
            'Очередь пуста.\nПеретащите сюда аудио или нажмите «Добавить».',
            textAlign: TextAlign.center,
            style: Type.caption.copyWith(color: Surface.secondaryText(context), height: 1.5),
          ),
        ),
      );
    }
    // Клавиши работают, когда список в фокусе, — как в любом списке macOS.
    return Focus(
      focusNode: _queueFocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final shift = HardwareKeyboard.instance.isShiftPressed;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowDown:
            _send(SelectionStepped(1, extend: shift));
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            _send(SelectionStepped(-1, extend: shift));
            return KeyEventResult.handled;
          case LogicalKeyboardKey.backspace:
          case LogicalKeyboardKey.delete:
            _sendRemove();
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        itemCount: s.jobs.length,
        itemBuilder: (context, i) {
          final job = s.jobs[i];
          return ContextMenuRegion(
            // Правый щелчок по невыделенной записи сначала выделяет её —
            // как в Finder. Это действие жеста, а не построения меню:
            // раньше выделение менялось внутри actions(), то есть setState
            // случался посреди сборки списка пунктов.
            onOpen: () {
              if (!s.selected.contains(job)) _send(JobSelected(job));
            },
            actions: () => _rowActions(s, job),
            child: QueueRow(
              job: job,
              selected: s.selected.contains(job),
              lead: identical(job, s.lead),
              customised: job.overrides != null,
              onTap: () {
                _queueFocus.requestFocus();
                final keys = HardwareKeyboard.instance;
                if (keys.isMetaPressed) {
                  _send(JobToggled(job));
                } else if (keys.isShiftPressed) {
                  _send(SelectionExtended(job));
                } else {
                  _send(JobSelected(job));
                }
              },
            ),
          );
        },
      ),
    );
  }

  /// Пункты меню правого щелчка. Считает по нынешнему выделению и ничего
  /// не меняет: выделить запись под курсором — дело жеста (onOpen).
  List<MenuAction> _rowActions(QueueState s, Job job) {
    final many = s.selected.length > 1;
    final ready = s.readyTargets.isNotEmpty;
    return [
      MenuAction(
        'Скопировать ${formatById(s.copyFormat).label.toLowerCase()}',
        onSelected: ready ? () => _copy() : null,
        shortcut: '⇧⌘C',
      ),
      MenuAction('Сохранить как…',
          onSelected: ready ? () => _saveAs(s) : null, shortcut: '⌘S'),
      const MenuAction.separator(),
      MenuAction(
        many ? 'Распознать заново выбранные' : 'Распознать заново',
        onSelected: s.running || !s.targets.any((j) => !j.imported) ? null : _sendRetry,
        shortcut: '⌥⌘R',
      ),
      MenuAction(
        'Показать в ${os.fileManagerName}',
        onSelected: () => _revealSource(job.path),
        shortcut: '⌘R',
      ),
      const MenuAction.separator(),
      if (job.overrides != null)
        MenuAction('Вернуть общие настройки', onSelected: _sendResetOverrides),
      MenuAction(
        many ? 'Убрать выбранные' : 'Убрать из очереди',
        onSelected: s.targets.any((j) => j.active) ? null : _sendRemove,
        shortcut: '⌫',
      ),
    ];
  }

  Widget _queueButtons(QueueState s) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: PushButton(
                controlSize: ControlSize.regular,
                onPressed: _pickFiles,
                child: const Text('Добавить'),
              ),
            ),
            const SizedBox(width: 8),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: s.targets.isEmpty || s.targets.any((j) => j.active)
                  ? null
                  : _sendRemove,
              child: const Text('Убрать'),
            ),
          ],
        ),
      );


  // ── расшифровка ───────────────────────────────────────────────────────────

  /// Отфильтрованная расшифровка и то, для чего она посчитана.
  ///
  /// Считать заново на каждый кадр нельзя: во время распознавания окно
  /// перерисовывается десятки раз в секунду, а на длинной записи это
  /// `toLowerCase` по каждому фрагменту. Ответ меняется, только когда
  /// меняется запрос или сама расшифровка, — по ним и сверяемся.
  List<Segment>? _filtered;
  ({Job? job, String query, int count})? _filterFor;

  List<Segment> _visibleSegments(Job job) {
    final all = job.segments;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;

    final key = (job: job, query: q, count: all.length);
    final cached = _filtered;
    if (cached != null && _filterFor == key) return cached;

    final hits = all.where((s) => s.text.toLowerCase().contains(q)).toList();
    _filterFor = key;
    return _filtered = hits;
  }

  Widget _transcriptArea(QueueState s) {
    final job = s.lead;

    Widget content;
    if (job == null && s.models.isEmpty) {
      // Пустее пустого: распознавать нечем. Пока модели нет, разговор про
      // перетаскивание файлов бессмыслен.
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: 'Нужна модель распознавания',
          subtitle: 'Она работает на этом компьютере, поэтому её надо один раз\n'
              'загрузить. Tiny — просто попробовать, Large v3 Turbo — точность.',
          action: _modelDownload(),
        ),
      );
    } else if (job == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: 'Перетащите аудио сюда',
          subtitle: 'ogg, m4a, mp3, wav и видео — распознаём локально,\n'
              'ничего не уходит в сеть.',
        ),
      );
    } else if (job.segments.isEmpty && job.raw == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: job.active ? 'Слушаем…' : 'Готово к распознаванию',
          subtitle: job.active
              ? 'Текст начнёт появляться, как только модель\nразберёт первый фрагмент.'
              : 'Нажмите «Распознать» в панели сверху · ⌘⏎',
        ),
      );
    } else if (job.transcript == null && job.raw != null) {
      content = SingleChildScrollView(
        controller: _transcriptScroll,
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 64),
        child: SelectableText(job.raw!, style: Type.body),
      );
    } else {
      final segments = _visibleSegments(job);
      if (segments.isEmpty) {
        content = Center(
          child: EmptyNotice(
            icon: CupertinoIcons.search,
            title: 'Ничего не найдено',
            subtitle: 'В этой расшифровке нет «$_query».',
          ),
        );
      } else {
        content = ListView.builder(
          controller: _transcriptScroll,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 66),
          itemCount: segments.length,
          // Ключом служит сам сегмент: время начала у двух соседних
          // фрагментов совпадает (VAD режет по паузам и выдаёт их
          // с одной меткой), и Flutter падал на одинаковых ключах.
          itemBuilder: (context, i) => SegmentRow(
            key: ObjectKey(segments[i]),
            segment: segments[i],
            showTimestamp: s.timestamps,
            highlight: _query.trim(),
            onCopied: () => _send(const StatusReported('Фрагмент скопирован')),
          ),
        );
      }
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _send(FilesAdded(details.files.map((f) => f.path)));
      },
      child: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned.fill(child: DropVeil(active: _dragging)),
        ],
      ),
    );
  }

  /// Правая половина строки состояния: чем эта расшифровка вообще является.
  String? _stats(QueueState s) {
    final job = s.lead;
    if (job == null || !job.done) return null;
    final segs = job.segments;
    if (segs.isEmpty) return null;
    final words = wordCount(segs.map((s) => s.text).join(' '));
    final parts = [
      if (job.transcript != null) segmentsLabel(segs.length),
      wordsLabel(words),
      humanDuration(segs.last.to),
      if (job.took != null) 'за ${humanDuration(job.took!.inMilliseconds)}',
    ];
    return parts.join(' · ');
  }

  Widget _statusBar(QueueState s) {
    final job = s.lead;
    final busy = s.running && (job?.active ?? false);
    final eta = busy ? job!.eta : null;
    final stats = busy ? null : _stats(s);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Surface.chrome(context),
            border: Border(top: BorderSide(color: Surface.hairline(context))),
          ),
          child: Row(
            children: [
              if (busy) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressCircle(value: (job!.progress * 100).clamp(0, 100)),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.dur(context, Motion.quick),
                  child: Text(
                    s.status,
                    key: ValueKey(s.status),
                    style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (eta != null && eta.inSeconds > 3)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    'осталось ≈ ${humanDuration(eta.inMilliseconds)}',
                    style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                  ),
                ),
              if (stats != null)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    stats,
                    style: Type.caption.copyWith(color: Surface.secondaryText(context)),
                  ),
                ),
              ModelChip(
                info: s.modelUse,
                label: _modelUseLabel(s),
                detail: _modelUseDetail(s),
                busy: s.modelUse.busy || s.transcribing,
                yielding: s.yieldBusyModel,
                waiting: s.waitingForModel,
                onTap: () {
                  _send(const YieldToggled());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── инспектор ─────────────────────────────────────────────────────────────

  /// Кнопка с пустого экрана: сами модели живут на своей вкладке
  /// в настройках, там же их и качают.
  Widget _modelDownload() => PushButton(
        controlSize: ControlSize.large,
        onPressed: () => _openSettings('models'),
        child: const Text('Загрузить модель…'),
      );


  /// В инспекторе — только то, что осмысленно менять от записи к записи:
  /// чем, на каком языке и как разбирать именно эту запись. Всё, что для
  /// всех записей одно (куда сохранять текст, метки времени, ожидание
  /// занятой модели), живёт на вкладке «Расшифровщик» в окне настроек,
  /// а диктовка — на своей. Инспектор целиком принадлежит расшифровщику,
  /// и ни одна настройка диктовки сюда не попадает.
  Widget _inspector(QueueState s, ScrollController controller) {
    final o = s.shown;
    final own = s.lead?.overrides;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
          Gap.edgeNarrow, Gap.inner, Gap.edgeNarrow, Gap.section),
      children: [
        ScopeBanner(
          selection: s.selected.length,
          name: s.lead?.name,
          changed: own == null ? const [] : own.diffAgainst(s.defaults),
          onReset: own == null ? null : _sendResetOverrides,
          onMakeDefault: own == null ? null : _sendMakeDefault,
        ),
        const SectionTitle('Модель расшифровщика'),
        ModelField(
          installed: s.models,
          value: o.model,
          onChosen: (v) => _send(OptionsEdited((x) => x.copyWith(model: v))),
          onDownload: _sendDownload,
        ),
        if (s.downloadProgress != null) ...[
          const SizedBox(height: Gap.inner),
          ModelDownload(
            title: s.download?.title ?? 'модель',
            progress: s.downloadProgress!,
            percent: s.downloadPercent,
            onCancel: () => _send(const DownloadCancelled()),
          ),
        ],
        const SizedBox(height: Gap.inner),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: _pickModel,
          child: const Text('Выбрать свой файл модели…'),
        ),
        const Hint('Диктовка может работать этой же моделью или своей — '
            'это решается на вкладке «Диктовка» в настройках.'),
        const SectionTitle('Язык речи'),
        MacosPopupButton<String>(
          value: o.lang,
          items: [
            for (final l in languages)
              MacosPopupMenuItem(value: l, child: Text(languageName(l))),
          ],
          onChanged: (v) => _send(OptionsEdited((x) => x.copyWith(lang: v ?? 'auto'))),
        ),
        const Hint('На смешанной речи выберите язык вручную — так точнее.'),
        const SectionTitle('Пунктуация'),
        Check('Ставить знаки препинания', o.punctuate,
            (v) => _send(OptionsEdited((x) => x.copyWith(punctuate: v)))),
        const Hint('Без этого модель на разговорной речи пишет сплошным нижним '
            'регистром. Своя подсказка ниже заменяет режим.', under: true),
        const SectionTitle('Разбивка на фрагменты'),
        MacosPopupButton<int>(
          value: o.maxLen,
          items: const [
            MacosPopupMenuItem(value: 0, child: Text('На усмотрение модели')),
            MacosPopupMenuItem(value: 32, child: Text('До 32 символов')),
            MacosPopupMenuItem(value: 42, child: Text('До 42 — под субтитры')),
            MacosPopupMenuItem(value: 64, child: Text('До 64 символов')),
            MacosPopupMenuItem(value: 100, child: Text('До 100 символов')),
          ],
          onChanged: (v) => _send(OptionsEdited((x) => x.copyWith(maxLen: v ?? 0))),
        ),
        const SizedBox(height: Gap.item),
        Check('Резать по паузам (VAD)', o.vad, (v) {
          if (v && o.vadModel.isEmpty) {
            _sendEnableVad();
          } else {
            _send(OptionsEdited((x) => x.copyWith(vad: v)));
          }
        }),
        if (o.vad)
          Padding(
            padding: const EdgeInsets.only(left: 25, top: Gap.hint),
            child: Text(
              o.vadModel.isEmpty ? 'Нужен файл модели VAD' : os.basename(o.vadModel),
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
          ),
        const SectionTitle('Скорость'),
        MacosPopupButton<int>(
          value: o.threads,
          items: [
            for (var t = 2; t <= Platform.numberOfProcessors; t += 2)
              MacosPopupMenuItem(value: t, child: Text('$t ${plural(t, 'поток', 'потока', 'потоков')}')),
          ],
          onChanged: (v) => _send(OptionsEdited((x) => x.copyWith(threads: v ?? o.threads))),
        ),
        const SectionTitle('Подсказка модели'),
        AppTextField(
          controller: _promptCtrl,
          placeholder: 'Имена, термины, названия',
          maxLines: 3,
          onChanged: (v) => _send(OptionsEdited((x) => x.copyWith(prompt: v))),
        ),
        const Hint('Слова из подсказки модель пишет правильнее.'),

        // Остальное — куда сохранять текст, диктовка, склад моделей,
        // поведение приложения — живёт в своём окне. Дорога туда должна
        // быть видна и отсюда.
        const SizedBox(height: Gap.section),
        // Открываем вкладку расшифровщика: из главного окна следующий
        // вопрос — что станет с готовым текстом, а не как настроена
        // диктовка. Вкладки в окне рядом, промахнуться некуда.
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: () => _openSettings('transcriber'),
          child: Text('Настройки расшифровщика… ${os.settingsShortcut}'),
        ),
        const SizedBox(height: Gap.item),
        Text(
          !s.whisperFound ? 'whisper-cli не найден' : 'Локально · whisper.cpp',
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
        ),
      ],
    );
  }
}

// ── элементы ────────────────────────────────────────────────────────────────

