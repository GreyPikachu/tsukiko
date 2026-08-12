import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode, SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'design.dart';
import 'engine.dart';
import 'mascot.dart';
import 'panel.dart' show runPanel;

part 'job.dart';
part 'home_queue.dart';
part 'home_transcribe.dart';
part 'home_export.dart';
part 'home_dialogs.dart';
part 'home_menus.dart';
part 'widgets_queue.dart';
part 'widgets_transcript.dart';
part 'widgets_inspector.dart';
part 'widgets_chrome.dart';

/// Точка входа второго движка Flutter — того, что рисует панель у строки
/// меню и ведёт диктовку. Она обязана лежать именно здесь: FlutterEngine
/// на macOS ищет точку входа только в корневой библиотеке приложения.
@pragma('vm:entry-point')
void panelMain() => runPanel();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Настоящий материал окна: содержимое во всю высоту, титульная полоса прозрачная.
  await const MacosWindowUtilsConfig(toolbarStyle: NSWindowToolbarStyle.unified).apply();
  final lock = acquireSingleInstanceLock();
  runApp(TsukikoApp(
    alreadyRunning: lock == null,
    initialFiles: args.where((a) => FileSystemEntity.typeSync(a) != FileSystemEntityType.notFound),
  ));
}

class TsukikoApp extends StatelessWidget {
  const TsukikoApp({
    super.key,
    required this.alreadyRunning,
    this.initialFiles = const [],
  });
  final bool alreadyRunning;
  final Iterable<String> initialFiles;

  @override
  Widget build(BuildContext context) => MacosApp(
        title: appName,
        theme: MacosThemeData.light(),
        darkTheme: MacosThemeData.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        home: alreadyRunning
            ? const _AlreadyRunning()
            : HomePage(initialFiles: initialFiles),
      );
}

class _AlreadyRunning extends StatelessWidget {
  const _AlreadyRunning();

  @override
  Widget build(BuildContext context) => MacosWindow(
        child: MacosScaffold(children: [
          ContentArea(
            builder: (context, _) => Center(
              child: _Placeholder(
                icon: CupertinoIcons.square_stack_3d_up,
                title: '$appName уже открыта',
                subtitle: 'Две копии загрузили бы модель в память дважды.',
              ),
            ),
          ),
        ]),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialFiles = const []});
  final Iterable<String> initialFiles;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _jobs = <Job>[];
  final _sel = <Job>{};
  Job? _lead;

  final _promptCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _queueFocus = FocusNode(debugLabel: 'очередь');
  final _transcriptScroll = ScrollController();
  final _whisper = findWhisper();

  bool _running = false, _stopRequested = false, _dragging = false, _scrolled = false;
  bool _findOpen = false;
  String _status = 'Готово';
  String _query = '';
  Process? _proc;
  Directory? _tmp;
  Timer? _modelTimer, _saveTimer;
  ModelUse _modelUse = const ModelUse(ModelState.free);
  Set<String> _modelUsers = <String>{};
  CpuSample _cpu = const CpuSample.empty();
  bool _polling = false;
  int _tick = 0;

  List<String> _models = [];
  late RunOptions _defaults;

  /// Идущая загрузка модели. Одна на всё окно: сеть общая, а два полуторагиговых
  /// файла разом просто мешают друг другу.
  Download? _download;

  // Настройки самого приложения — они не бывают «своими у записи».
  bool _timestamps = true, _yieldBusyModel = true, _saveNextToSource = false;
  bool _toLibrary = true;
  String _libraryPath = defaultLibraryPath;
  List<String> _libraryFormats = const ['txt'];

  // Приложение помнит, чем вы пользуетесь: кнопка повторяет прошлый выбор,
  // а стрелка рядом позволяет его сменить.
  String _copyFormat = formatPlainText.id;
  String _saveFormat = formatPlainText.id;
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    _models = findModels();

    var threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 16);
    if (threads.isOdd) threads -= 1;

    final s = Settings.load();
    _defaults = RunOptions.fromJson(
      s,
      RunOptions(
        model: _models.isNotEmpty ? _models.first : '',
        lang: 'auto',
        threads: threads,
      ),
    );
    _rescanModels();
    _timestamps = (s['timestamps'] as bool?) ?? true;
    _yieldBusyModel =
        (s['yieldBusyModel'] as bool?) ?? (s['yieldDictara'] as bool?) ?? true;
    _saveNextToSource = (s['saveNextToSource'] as bool?) ?? false;
    _toLibrary = (s['toLibrary'] as bool?) ?? true;
    _libraryPath = (s['libraryPath'] as String?) ?? defaultLibraryPath;
    _copyFormat = _knownFormat(s['copyFormat'], formatPlainText.id);
    _saveFormat = _knownFormat(s['saveFormat'], formatPlainText.id);
    _recent = ((s['recent'] as List?)?.cast<String>() ?? const [])
        .where((p) => File(p).existsSync())
        .toList();
    // Раньше форматы хранились расширениями («.txt») — переводим в имена.
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    if (formats != null && formats.isNotEmpty) _libraryFormats = formats;
    _promptCtrl.text = _defaults.prompt;

    _transcriptScroll.addListener(() {
      final scrolled = _transcriptScroll.hasClients && _transcriptScroll.offset > 6;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    });
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _query) setState(() => _query = _searchCtrl.text);
    });

    _pollModel();
    // Диктовка короткая: между «отпустил клавишу» и «текст готов» проходит
    // пара секунд. Реже чем раз в 700 мс её просто не видно.
    _modelTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) => _pollModel());

    if (widget.initialFiles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addPaths(widget.initialFiles));
    }
  }

  /// setState помечен @protected: из вынесенных в part-файлы расширений
  /// его не вызвать напрямую, а поведение должно остаться прежним.
  void _set(VoidCallback change) => setState(change);

  /// Перечитать модели с диска: скачанное ложится в папку, которую
  /// findModels() и так просматривает. Выбранный вручную файл из чужой папки
  /// дописываем — иначе он исчез бы из списка. Пропавший файл не дописываем:
  /// список из одной мёртвой строки выглядит так, будто модель есть.
  void _rescanModels() {
    final found = findModels();
    final own = _defaults.model;
    _models = own.isEmpty || found.contains(own) || !File(own).existsSync()
        ? found
        : [...found, own];
  }

  String _knownFormat(Object? id, String fallback) =>
      exportFormats.any((f) => f.id == id) ? id as String : fallback;

  @override
  void dispose() {
    _modelTimer?.cancel();
    _saveTimer?.cancel();
    _proc?.kill();
    _tmp?.deleteSync(recursive: true);
    _writeSettings();
    _promptCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _queueFocus.dispose();
    _transcriptScroll.dispose();
    super.dispose();
  }

  // ── настройки ─────────────────────────────────────────────────────────────

  /// Раньше настройки писались только при выходе, и ⌘Q мимо dispose стирал
  /// все правки за сеанс. Теперь пишем сразу, но не чаще раза в полсекунды —
  /// иначе каждая буква в подсказке уходила бы на диск.
  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _writeSettings);
  }

  void _writeSettings() => Settings.save({
        ..._defaults.toJson(),
        'timestamps': _timestamps,
        'yieldBusyModel': _yieldBusyModel,
        'modelUsers': _modelUsers.toList(),
        'saveNextToSource': _saveNextToSource,
        'toLibrary': _toLibrary,
        'libraryPath': _libraryPath,
        'libraryFormats': _libraryFormats,
        'copyFormat': _copyFormat,
        'saveFormat': _saveFormat,
        'recent': _recent,
      });

  /// Настройки, которые сейчас показывает инспектор: общие, если ничего
  /// не выбрано, иначе — настройки ведущей записи.
  RunOptions get _shown => _sel.isEmpty ? _defaults : (_lead?.overrides ?? _defaults);

  RunOptions _optionsFor(Job job) => job.overrides ?? _defaults;

  /// Правка уходит туда, куда смотрит инспектор: в общие настройки или
  /// во все выбранные записи сразу.
  void _edit(RunOptions Function(RunOptions) change) {
    setState(() {
      if (_sel.isEmpty) {
        _defaults = change(_defaults);
      } else {
        for (final job in _sel) {
          job.overrides = change(job.overrides ?? _defaults);
        }
      }
    });
    _persist();
  }

  void _resetOverrides() {
    setState(() {
      for (final job in _sel) {
        job.overrides = null;
      }
      _status = 'Настройки записи сброшены';
    });
    _syncPromptField();
  }

  void _makeDefault() {
    final own = _lead?.overrides;
    if (own == null) return;
    setState(() {
      _defaults = own;
      _status = 'Эти настройки стали общими';
    });
    _persist();
  }

  void _syncPromptField() {
    final text = _shown.prompt;
    if (_promptCtrl.text == text) return;
    _promptCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Один опрос занятости. Разница CPU считается между соседними опросами,
  /// поэтому замер надо сохранять всегда, даже когда на экране ничего
  /// не поменялось.
  Future<void> _pollModel() async {
    if (_polling) return;
    _polling = true;
    try {
      final use = await modelUsage(
        modelPath: _shown.model,
        others: _models,
        learned: _modelUsers,
        ignorePid: _proc?.pid,
        previous: _cpu,
        // lsof — самая дорогая часть опроса, а нужен он только чтобы поймать
        // короткий момент загрузки модели в память.
        probeHolders: _tick++ % 3 == 0,
      );
      _cpu = use.cpu;
      if (!mounted) return;
      if (use.label != _modelUse.label ||
          use.detail != _modelUse.detail ||
          use.learned.length != _modelUsers.length) {
        setState(() {
          _modelUse = use;
          _modelUsers = use.learned;
        });
      }
    } finally {
      _polling = false;
    }
  }

  // ── меню в строке меню ────────────────────────────────────────────────────

  static const _cmd = SingleActivator(LogicalKeyboardKey.keyO, meta: true);

  String? _menuSignature;
  List<PlatformMenuItem> _menuCache = const [];

  // ── интерфейс ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: _menus(),
      child: MacosWindow(
        sidebar: Sidebar(
          minWidth: 248,
          startWidth: 276,
          builder: (context, controller) => _queue(controller),
          bottom: _queueButtons(),
        ),
        endSidebar: Sidebar(
          minWidth: 290,
          startWidth: 312,
          maxWidth: 380,
          shownByDefault: true,
          builder: (context, controller) => _inspector(controller),
        ),
        child: MacosScaffold(
          toolBar: _toolbar(),
          children: [
            ContentArea(
              builder: (context, _) => Stack(
                children: [
                  Positioned.fill(
                    child: Column(children: [
                      if (_findOpen) _findBar(),
                      Expanded(child: _transcriptArea()),
                    ]),
                  ),
                  Positioned(left: 0, right: 0, bottom: 0, child: _statusBar()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  ToolBar _toolbar() {
    final ready = _readyTargets.isNotEmpty;
    final copyFormat = formatById(_copyFormat);
    final saveFormat = formatById(_saveFormat);

    return ToolBar(
      title: _ToolbarTitle(subtitle: _subtitle()),
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
          label: _running ? 'Остановить' : 'Распознать',
          icon: MacosIcon(_running
              ? CupertinoIcons.stop_fill
              : _yieldBusyModel && _modelUse.busy
                  ? CupertinoIcons.pause_circle
                  : CupertinoIcons.play_fill),
          showLabel: false,
          tooltipMessage: _running
              ? (_waitingForModel
                  ? 'Ждём, пока ${_modelUse.by} закончит · остановить ⌘.'
                  : 'Остановить · ⌘.')
              : _yieldBusyModel && _modelUse.busy
                  ? 'Модель занята (${_modelUse.by}) — начнём, как только освободится · ⌘⏎'
                  : 'Распознать очередь · ⌘⏎',
          onPressed: _running ? _stop : (_hasPending ? _start : null),
        ),
        ToolBarIconButton(
          label: 'Распознать заново',
          icon: const MacosIcon(CupertinoIcons.arrow_counterclockwise),
          showLabel: false,
          tooltipMessage: 'Распознать заново с текущими настройками · ⌥⌘R',
          onPressed: _running || !_targets.any((j) => !j.imported) ? null : _retry,
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
                    _formatItem(f, _copyFormat, () => _copy(f)),
                ]
              : null,
        ),
        ToolBarIconButton(
          label: 'Сохранить',
          icon: const MacosIcon(CupertinoIcons.arrow_down_doc),
          showLabel: false,
          tooltipMessage: 'Сохранить: ${saveFormat.label.toLowerCase()} · ⌘S',
          onPressed: ready ? () => _saveAs() : null,
        ),
        ToolBarPullDownButton(
          label: 'Формат сохранения',
          icon: CupertinoIcons.arrow_down_doc,
          tooltipMessage: 'Выбрать формат файла',
          items: ready
              ? [
                  for (final f in exportFormats) _formatItem(f, _saveFormat, () => _saveAs(f)),
                  const MacosPulldownMenuDivider(),
                  MacosPulldownMenuItem(
                    title: const Text('Экспортировать в папку…'),
                    label: 'Экспортировать в папку',
                    onTap: _exportAll,
                  ),
                ]
              : null,
        ),
        ToolBarIconButton(
          label: 'Найти',
          icon: const MacosIcon(CupertinoIcons.search),
          showLabel: false,
          tooltipMessage: 'Найти в расшифровке · ⌘F',
          onPressed: _job == null ? null : _openFind,
        ),
      ],
    );
  }

  /// Панель поиска приходит сверху и уходит по Esc — как в Safari и Xcode,
  /// а не занимает место в панели инструментов всё время.
  Widget _findBar() => Container(
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
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _findSummary(),
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

  String _findSummary() {
    final job = _job;
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

  String? _subtitle() {
    if (_sel.length > 1) return 'Выбрано: ${recordsLabel(_sel.length)}';
    final job = _lead;
    if (job != null) return job.name;
    if (_jobs.isEmpty) return null;
    return 'В очереди: ${recordsLabel(_jobs.length)}';
  }

  // ── очередь ───────────────────────────────────────────────────────────────

  Widget _queue(ScrollController controller) {
    if (_jobs.isEmpty) {
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
            _step(1, extend: shift);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            _step(-1, extend: shift);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.backspace:
          case LogicalKeyboardKey.delete:
            _removeSelected();
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        itemCount: _jobs.length,
        itemBuilder: (context, i) {
          final job = _jobs[i];
          return ContextMenuRegion(
            actions: () => _rowActions(job),
            child: _QueueRow(
              job: job,
              selected: _sel.contains(job),
              lead: identical(job, _lead),
              customised: job.overrides != null,
              onTap: () {
                _queueFocus.requestFocus();
                final keys = HardwareKeyboard.instance;
                if (keys.isMetaPressed) {
                  _toggleSelect(job);
                } else if (keys.isShiftPressed) {
                  _extendSelect(job);
                } else {
                  _select(job);
                }
              },
            ),
          );
        },
      ),
    );
  }

  /// Меню правого щелчка работает с тем, по чему щёлкнули: если запись
  /// не в выделении, она сначала становится выделенной — как в Finder.
  List<MenuAction> _rowActions(Job job) {
    if (!_sel.contains(job)) _select(job);
    final many = _sel.length > 1;
    final ready = _readyTargets.isNotEmpty;
    return [
      MenuAction(
        'Скопировать ${formatById(_copyFormat).label.toLowerCase()}',
        onSelected: ready ? () => _copy() : null,
        shortcut: '⇧⌘C',
      ),
      MenuAction('Сохранить как…',
          onSelected: ready ? () => _saveAs() : null, shortcut: '⌘S'),
      const MenuAction.separator(),
      MenuAction(
        many ? 'Распознать заново выбранные' : 'Распознать заново',
        onSelected: _running || !_targets.any((j) => !j.imported) ? null : _retry,
        shortcut: '⌥⌘R',
      ),
      MenuAction(
        'Показать в Finder',
        onSelected: () => revealInFinder(job.file.path),
        shortcut: '⌘R',
      ),
      const MenuAction.separator(),
      if (job.overrides != null)
        MenuAction('Вернуть общие настройки', onSelected: _resetOverrides),
      MenuAction(
        many ? 'Убрать выбранные' : 'Убрать из очереди',
        onSelected: _targets.any((j) => j.active) ? null : _removeSelected,
        shortcut: '⌫',
      ),
    ];
  }

  Widget _queueButtons() => Padding(
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
              onPressed: _targets.isEmpty || _targets.any((j) => j.active)
                  ? null
                  : _removeSelected,
              child: const Text('Убрать'),
            ),
          ],
        ),
      );

  /// Настроение кота выводится из того, что приложение делает прямо сейчас.
  Mood _mood(Job? job) => moodFor(
        dragging: _dragging,
        running: _running,
        jobActive: job?.active ?? false,
        hasJobs: job != null,
        longWait: (job?.segments.isEmpty ?? true) && job?.raw == null,
      );

  // ── расшифровка ───────────────────────────────────────────────────────────

  List<Segment> _visibleSegments(Job job) {
    final all = job.segments;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((s) => s.text.toLowerCase().contains(q)).toList();
  }

  Widget _transcriptArea() {
    final job = _job;

    Widget content;
    if (job == null && _models.isEmpty) {
      // Пустее пустого: распознавать нечем. Пока модели нет, разговор про
      // перетаскивание файлов бессмыслен.
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(job),
          title: 'Нужна модель распознавания',
          subtitle: 'Она работает на этом компьютере, поэтому её надо один раз\n'
              'загрузить. Tiny — просто попробовать, Large v3 turbo — точность.',
          action: _modelDownload(),
        ),
      );
    } else if (job == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(job),
          title: 'Перетащите аудио сюда',
          subtitle: 'ogg, m4a, mp3, wav и видео — распознаём локально,\n'
              'ничего не уходит в сеть.',
        ),
      );
    } else if (job.segments.isEmpty && job.raw == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(job),
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
          child: _Placeholder(
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
          itemBuilder: (context, i) => _SegmentRow(
            key: ValueKey('${job.file.path}#${segments[i].from}'),
            segment: segments[i],
            showTimestamp: _timestamps,
            highlight: _query.trim(),
            onCopied: () => setState(() => _status = 'Фрагмент скопирован'),
          ),
        );
      }
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _addPaths(details.files.map((f) => f.path));
      },
      child: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned.fill(child: _DropVeil(active: _dragging)),
        ],
      ),
    );
  }

  /// Правая половина строки состояния: чем эта расшифровка вообще является.
  String? _stats() {
    final job = _lead;
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

  Widget _statusBar() {
    final job = _job;
    final busy = _running && (job?.active ?? false);
    final eta = busy ? job!.eta : null;
    final stats = busy ? null : _stats();

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
                    _status,
                    key: ValueKey(_status),
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
              _ModelChip(
                info: _modelUse,
                yielding: _yieldBusyModel,
                waiting: _waitingForModel,
                onTap: () {
                  setState(() => _yieldBusyModel = !_yieldBusyModel);
                  _persist();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── инспектор ─────────────────────────────────────────────────────────────

  /// Один и тот же загрузчик стоит в инспекторе и в пустом экране: когда
  /// моделей нет вовсе, вести человека надо оттуда, где он смотрит.
  Widget _modelDownload() => _ModelDownload(
        active: _download,
        onPick: _downloadModel,
        onCancel: () => setState(() => _download?.cancel()),
      );

  Widget _inspector(ScrollController controller) {
    final o = _shown;
    final own = _lead?.overrides;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
      children: [
        _ScopeBanner(
          selection: _sel.length,
          name: _lead?.name,
          changed: own == null ? const [] : own.diffAgainst(_defaults),
          onReset: own == null ? null : _resetOverrides,
          onMakeDefault: own == null ? null : _makeDefault,
        ),
        const _SectionTitle('Модель'),
        MacosPopupButton<String>(
          value: _models.contains(o.model) ? o.model : null,
          hint: const Text('Не выбрана'),
          items: [
            for (final m in _models)
              MacosPopupMenuItem(value: m, child: Text(m.split('/').last)),
          ],
          onChanged: (v) => _edit((x) => x.copyWith(model: v ?? '')),
        ),
        const SizedBox(height: 8),
        PushButton(
          controlSize: ControlSize.small,
          secondary: true,
          onPressed: _pickModel,
          child: const Text('Выбрать другой файл…'),
        ),
        const SizedBox(height: 8),
        _modelDownload(),
        const _SectionTitle('Язык речи'),
        MacosPopupButton<String>(
          value: o.lang,
          items: [
            for (final l in languages)
              MacosPopupMenuItem(value: l, child: Text(languageName(l))),
          ],
          onChanged: (v) => _edit((x) => x.copyWith(lang: v ?? 'auto')),
        ),
        const _Hint('На смешанной речи выберите язык вручную — так точнее.'),
        const _SectionTitle('Пунктуация'),
        _Check('Ставить знаки препинания', o.punctuate,
            (v) => _edit((x) => x.copyWith(punctuate: v))),
        const _Hint('Без этого модель на разговорной речи пишет сплошным нижним '
            'регистром. Своя подсказка ниже заменяет режим.'),
        const _SectionTitle('Разбивка на фрагменты'),
        MacosPopupButton<int>(
          value: o.maxLen,
          items: const [
            MacosPopupMenuItem(value: 0, child: Text('На усмотрение модели')),
            MacosPopupMenuItem(value: 32, child: Text('До 32 символов')),
            MacosPopupMenuItem(value: 42, child: Text('До 42 — под субтитры')),
            MacosPopupMenuItem(value: 64, child: Text('До 64 символов')),
            MacosPopupMenuItem(value: 100, child: Text('До 100 символов')),
          ],
          onChanged: (v) => _edit((x) => x.copyWith(maxLen: v ?? 0)),
        ),
        const SizedBox(height: 10),
        _Check('Резать по паузам (VAD)', o.vad, (v) {
          if (v && o.vadModel.isEmpty) {
            _enableVad();
          } else {
            _edit((x) => x.copyWith(vad: v));
          }
        }),
        if (o.vad)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Text(
              o.vadModel.isEmpty ? 'Нужен файл модели VAD' : o.vadModel.split('/').last,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
          ),
        const _SectionTitle('Скорость'),
        MacosPopupButton<int>(
          value: o.threads,
          items: [
            for (var t = 2; t <= Platform.numberOfProcessors; t += 2)
              MacosPopupMenuItem(value: t, child: Text('$t ${plural(t, 'поток', 'потока', 'потоков')}')),
          ],
          onChanged: (v) => _edit((x) => x.copyWith(threads: v ?? o.threads)),
        ),
        const _SectionTitle('Подсказка модели'),
        MacosTextField(
          controller: _promptCtrl,
          placeholder: 'Имена, термины, названия',
          maxLines: 3,
          onChanged: (v) => _edit((x) => x.copyWith(prompt: v)),
        ),
        const _Hint('Слова из подсказки модель пишет правильнее.'),

        // Ниже — настройки самого приложения: они общие всегда.
        const _SectionTitle('Библиотека'),
        _LibraryPath(
          path: _libraryPath,
          onReveal: () => revealInFinder(_libraryPath),
          onChange: _pickLibrary,
        ),
        const SizedBox(height: 8),
        _Check('Складывать расшифровки сюда', _toLibrary, (v) {
          setState(() => _toLibrary = v);
          _persist();
        }),
        if (_toLibrary) ...[
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 8, bottom: 2),
            child: Text('ФОРМАТЫ',
                style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context))),
          ),
          for (final f in exportFormats)
            _Check('${f.label} · ${f.suffix}', _libraryFormats.contains(f.id), (v) {
              setState(() {
                final next = [..._libraryFormats];
                v ? next.add(f.id) : next.remove(f.id);
                // Пустой набор при включённой библиотеке означал бы тишину.
                _libraryFormats = next.isEmpty ? [f.id] : next;
              });
              _persist();
            }),
          _Hint(_libraryFormats.length > 1
              ? 'Файлы раскладываются по месяцам, и у каждой записи своя папка — '
                  'форматов больше одного.'
              : 'Файлы раскладываются по месяцам: $appName/'
                  '${monthFolder(DateTime.now())}/'),
        ],
        const _SectionTitle('Вид'),
        _Check('Показывать метки времени', _timestamps, (v) {
          setState(() => _timestamps = v);
          _persist();
        }),
        const _Hint('Только на экране. Что попадёт в файл, решает выбранный '
            'формат, а не эта галка.'),
        _Check('Класть текст рядом с исходником', _saveNextToSource, (v) {
          setState(() => _saveNextToSource = v);
          _persist();
        }),
        const _Hint('Чистый текст без таймкодов, имя как у аудиофайла.'),
        _Check('Ждать, если модель занята', _yieldBusyModel, (v) {
          setState(() => _yieldBusyModel = v);
          _persist();
        }),
        const _Hint('Пока модель держит другая программа — диктовка, ещё один whisper — '
            'очередь стоит и не отбирает у неё память и GPU.'),
        const SizedBox(height: 20),
        Text(
          _whisper == null ? 'whisper-cli не найден' : 'Локально · whisper.cpp',
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
        ),
      ],
    );
  }
}

// ── элементы ────────────────────────────────────────────────────────────────

