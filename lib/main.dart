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

class Job {
  Job(this.file, {this.imported = false});
  final File file;

  /// Расшифровку открыли из файла — распознавать в ней нечего.
  final bool imported;

  JobState state = JobState.queued;

  /// Уточнение к состоянию: «Русский · 42 фрагмента». Пусто — показываем
  /// само состояние.
  String? detail;

  double progress = 0;
  final List<Segment> live = [];
  Transcript? transcript;
  String? raw;

  /// Свои настройки записи. null — берутся общие.
  RunOptions? overrides;

  DateTime? startedAt;
  Duration? took;

  String get name => file.path.split('/').last;
  bool get active =>
      state == JobState.converting || state == JobState.transcribing;
  bool get done => transcript != null || raw != null;
  List<Segment> get segments => transcript?.segments ?? live;

  /// Сколько ещё осталось, если считать, что дальше пойдёт с той же скоростью.
  Duration? get eta {
    final started = startedAt;
    if (started == null || progress < 0.05) return null;
    final spent = DateTime.now().difference(started);
    return spent * ((1 - progress) / progress);
  }

  void reset() {
    transcript = null;
    raw = null;
    live.clear();
    progress = 0;
    detail = null;
    took = null;
    startedAt = null;
    state = JobState.queued;
  }
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
    if (_defaults.model.isNotEmpty && !_models.contains(_defaults.model)) {
      _models = [..._models, _defaults.model];
    }
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

  // ── выделение ─────────────────────────────────────────────────────────────

  Job? get _job => _lead;

  /// Что попадёт под команду: выбранное, а если не выбрано ничего —
  /// ведущая запись. Так меню и кнопки одинаково понимают «применить к».
  List<Job> get _targets =>
      _sel.isNotEmpty ? _jobs.where(_sel.contains).toList() : [?_lead];

  List<Job> get _readyTargets => _targets.where((j) => j.done).toList();

  void _select(Job job) {
    setState(() {
      _sel
        ..clear()
        ..add(job);
      _lead = job;
    });
    _syncPromptField();
  }

  void _toggleSelect(Job job) {
    setState(() {
      if (!_sel.remove(job)) _sel.add(job);
      _lead = _sel.contains(job) ? job : (_sel.isEmpty ? null : _sel.last);
    });
    _syncPromptField();
  }

  void _extendSelect(Job job) {
    final lead = _lead;
    if (lead == null) return _select(job);
    final a = _jobs.indexOf(lead), b = _jobs.indexOf(job);
    if (a < 0 || b < 0) return _select(job);
    setState(() {
      _sel.addAll(_jobs.sublist(a < b ? a : b, (a < b ? b : a) + 1));
      _lead = job;
    });
    _syncPromptField();
  }

  void _selectAll() {
    if (_jobs.isEmpty) return;
    setState(() {
      _sel
        ..clear()
        ..addAll(_jobs);
      _lead ??= _jobs.first;
    });
    _syncPromptField();
  }

  void _deselect() {
    setState(() {
      _sel.clear();
      _lead = null;
    });
    _syncPromptField();
  }

  void _step(int delta, {bool extend = false}) {
    if (_jobs.isEmpty) return;
    final from = _lead == null ? -1 : _jobs.indexOf(_lead!);
    final next = (from + delta).clamp(0, _jobs.length - 1);
    extend ? _extendSelect(_jobs[next]) : _select(_jobs[next]);
  }

  // ── очередь ───────────────────────────────────────────────────────────────

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  void _remember(String path) {
    setState(() => _recent = [path, ..._recent.where((p) => p != path)].take(10).toList());
    _persist();
  }

  void _addPaths(Iterable<String> paths) {
    var added = 0, duplicates = 0, skipped = 0;
    Job? last;
    for (final p in paths) {
      if (FileSystemEntity.isDirectorySync(p)) {
        final inner = Directory(p)
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where((f) => audioExt.contains(_ext(f)))
            .toList()
          ..sort();
        _addPaths(inner);
        continue;
      }
      // Готовую расшифровку тоже принимаем перетаскиванием — раньше она
      // молча отбрасывалась, и открыть её можно было только через диалог.
      if (transcriptExt.contains(_ext(p))) {
        _import(p);
        continue;
      }
      if (!audioExt.contains(_ext(p))) {
        skipped++;
        continue;
      }
      if (_jobs.any((j) => j.file.path == p)) {
        duplicates++;
        continue;
      }
      last = Job(File(p));
      _jobs.add(last);
      _remember(p);
      added++;
    }
    // Молчаливый отказ — худший вид отказа: файл не появился, и непонятно,
    // почему. Говорим про каждый случай.
    setState(() {
      if (added > 0) {
        _status = added == 1 ? 'Файл добавлен' : 'Добавлено: ${filesLabel(added)}';
      } else if (duplicates > 0) {
        _status = duplicates == 1
            ? 'Этот файл уже в очереди'
            : 'Эти файлы уже в очереди';
      } else if (skipped > 0) {
        _status = 'Такие файлы не поддерживаются';
      }
    });
    if (last != null && _sel.isEmpty) _select(last);
  }

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(
        label: 'Аудио и видео',
        extensions: audioExt.map((e) => e.substring(1)).toList(),
      ),
    ]);
    _addPaths(files.map((f) => f.path));
  }

  void _removeSelected() {
    final doomed = _targets.where((j) => !j.active).toSet();
    if (doomed.isEmpty) return;
    final at = _jobs.indexOf(doomed.first);
    setState(() {
      _jobs.removeWhere(doomed.contains);
      _sel.removeAll(doomed);
      if (_lead != null && doomed.contains(_lead)) {
        _lead = _jobs.isEmpty ? null : _jobs[at.clamp(0, _jobs.length - 1)];
        if (_lead != null && _sel.isEmpty) _sel.add(_lead!);
      }
      _status = doomed.length == 1
          ? 'Запись убрана из очереди'
          : 'Убрано из очереди: ${recordsLabel(doomed.length)}';
    });
    _syncPromptField();
  }

  void _clearFinished() {
    final doomed = _jobs.where((j) => j.done).toSet();
    if (doomed.isEmpty) return;
    setState(() {
      _jobs.removeWhere(doomed.contains);
      _sel.removeAll(doomed);
      if (doomed.contains(_lead)) _lead = _jobs.isEmpty ? null : _jobs.first;
      _status = 'Готовые записи убраны';
    });
    _syncPromptField();
  }

  // ── распознавание ─────────────────────────────────────────────────────────

  bool get _hasPending => _jobs.any((j) => !j.done && !j.imported);

  /// Очередь запущена, но стоит и уступает чужому распознаванию.
  bool get _waitingForModel =>
      _running && _jobs.any((j) => j.state == JobState.waiting);

  Future<void> _retry() async {
    final again = _targets.where((j) => !j.imported).toList();
    if (again.isEmpty || _running) return;
    setState(() {
      for (final job in again) {
        job.reset();
      }
      _status = again.length == 1
          ? 'Распознаём заново'
          : 'Распознаём заново: ${recordsLabel(again.length)}';
    });
    await _start();
  }

  /// Пока модель занята кем-то другим — стоим и не поднимаем свою.
  /// Состояние берём у общего опросчика: он и так обновляется каждые 700 мс,
  /// второй такой же опрос рядом только жёг бы процессор.
  /// Возвращает false, если ожидание прервали кнопкой «Остановить».
  Future<bool> _yieldWhileBusy(Job job) async {
    var waited = false;
    while (_yieldBusyModel && !_stopRequested && _modelUse.busy) {
      if (!waited || job.state != JobState.waiting) {
        setState(() {
          job.state = JobState.waiting;
          _status = 'Уступаем: ${_modelUse.by} распознаёт речь';
        });
      }
      waited = true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (waited && !_stopRequested) {
      setState(() => _status = 'Модель освободилась — продолжаем');
    }
    return !_stopRequested;
  }

  Future<void> _start() async {
    if (_running) return;
    final whisper = _whisper;
    if (whisper == null) {
      _alert('Не найден whisper-cli',
          'Ожидается /opt/homebrew/bin/whisper-cli.\nУстановка: brew install whisper-cpp');
      return;
    }
    if (_defaults.model.isEmpty && _jobs.every((j) => _optionsFor(j).model.isEmpty)) {
      _alert('Не выбрана модель', 'Укажите файл ggml-*.bin в настройках справа.');
      return;
    }
    if (!_hasPending) return;

    if (!_yieldBusyModel && _modelUse.busy) {
      final go = await _confirm(
        'Модель уже занята',
        '${_modelUse.detail}\n'
        'Одновременная работа замедлит обе стороны. Продолжить?',
      );
      if (!go) return;
    }

    setState(() {
      _running = true;
      _stopRequested = false;
    });
    _tmp ??= await Directory.systemTemp.createTemp(appName);

    for (var i = 0; i < _jobs.length; i++) {
      if (_stopRequested) break;
      final job = _jobs[i];
      if (job.done || job.imported) continue;
      final opts = _optionsFor(job);
      if (opts.model.isEmpty) {
        setState(() {
          job.state = JobState.failed;
          job.detail = 'Не выбрана модель';
        });
        continue;
      }

      if (!await _yieldWhileBusy(job)) break;

      setState(() {
        job.state = JobState.converting;
        job.startedAt = DateTime.now();
        _lead = job;
        if (_sel.length <= 1) {
          _sel
            ..clear()
            ..add(job);
        }
      });
      _syncPromptField();

      final base = '${_tmp!.path}/${i.toString().padLeft(3, '0')}';
      final wav = await toWav(job.file.path, '$base.wav');

      // Подготовка звука занимает секунды — за это время сосед мог начать
      // распознавать заново. Проверяем ещё раз вплотную к запуску.
      if (!await _yieldWhileBusy(job)) break;

      setState(() {
        job.state = JobState.transcribing;
        _status = job.name;
      });
      final proc = await Process.start(whisper, buildArgs(opts, wav, base));
      _proc = proc;

      void onLine(String line) {
        if (!mounted) return;
        final seg = parseSegmentLine(line);
        if (seg != null) {
          setState(() => job.live.add(seg));
          _followTail();
          return;
        }
        final p = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
        if (p != null) {
          setState(() => job.progress = double.parse(p.group(1)!) / 100);
        }
        final l = RegExp(r'auto-detected language:\s*(\w+)').firstMatch(line);
        if (l != null) {
          setState(() => _status = '${job.name} · ${languageName(l.group(1)!)}');
        }
      }

      final outSub =
          proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      final errSub =
          proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      final code = await proc.exitCode;
      await outSub.cancel();
      await errSub.cancel();
      _proc = null;

      if (_stopRequested) {
        setState(() => job.state = JobState.cancelled);
        break;
      }

      final jsonFile = File('$base.json');
      if (code != 0 || !jsonFile.existsSync()) {
        setState(() {
          job.state = JobState.failed;
          _status = 'Не удалось распознать «${job.name}»';
        });
        continue;
      }

      final t = parseWhisperJson(await jsonFile.readAsString());
      job.transcript = t;

      if (_saveNextToSource) {
        try {
          final path = job.file.path;
          await File('${path.substring(0, path.lastIndexOf('.'))}.txt')
              .writeAsString(renderPlain(t.segments, false));
        } catch (_) {}
      }
      final placed = _toLibrary ? await _fileToLibrary(job) : null;

      setState(() {
        job.progress = 1;
        job.state = JobState.done;
        job.took = job.startedAt == null
            ? null
            : DateTime.now().difference(job.startedAt!);
        job.detail = '${languageName(t.lang)} · ${segmentsLabel(t.segments.length)}';
        if (placed != null) _status = placed;
      });
    }

    setState(() {
      _running = false;
      _status = _stopRequested ? 'Остановлено' : 'Готово';
    });
    _writeSettings();
  }

  /// Раскладка по месяцам; когда форматов больше одного — у записи своя папка.
  /// Возвращает строку для статуса или null, если положить не удалось.
  Future<String?> _fileToLibrary(Job job) async {
    if (_libraryFormats.isEmpty) return null;
    try {
      final formats = _libraryFormats.map(formatById).toList();
      final plan = planPlacement(
        root: _libraryPath,
        stem: _stem(job.name),
        formatCount: formats.length,
      );
      await Directory(plan.dir).create(recursive: true);
      final stem = formats.length == 1
          ? freeStem(plan.dir, plan.stem, formats.first.suffix)
          : plan.stem;
      for (final f in formats) {
        await _write(job, '${plan.dir}/${f.fileName(stem)}', f);
      }
      final where = plan.dir.replaceFirst(_libraryPath, appName);
      return 'Сохранено в «$where»';
    } catch (e) {
      return 'Не удалось записать в библиотеку: $e';
    }
  }

  /// Держимся хвоста, пока пользователь сам не отлистал вверх — не отбираем управление.
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

  void _stop() {
    if (!_running) return;
    _stopRequested = true;
    _proc?.kill();
    setState(() => _status = 'Останавливаем…');
  }

  // ── экспорт / импорт / копирование ────────────────────────────────────────

  /// Импортированный текст без разметки отдаём как есть, всё остальное —
  /// в запрошенном формате.
  String _render(Job job, ExportFormat f) {
    final t = job.transcript;
    if (t == null) {
      return job.raw ?? renderPlain(job.live, f.id == 'txt-ts');
    }
    return renderAs(f, t, name: job.name);
  }

  /// Несколько записей склеиваются с заголовками — иначе в буфере получается
  /// стена текста, в которой не видно, где кончилась одна запись.
  String _renderAll(List<Job> jobs, ExportFormat f) => jobs.length == 1
      ? _render(jobs.first, f)
      : jobs.map((j) => '— ${j.name} —\n${_render(j, f)}').join('\n\n');

  Future<void> _copy([ExportFormat? format]) async {
    final f = format ?? formatById(_copyFormat);
    final jobs = _readyTargets;
    if (jobs.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _renderAll(jobs, f)));
    setState(() {
      _copyFormat = f.id;
      _status = jobs.length == 1
          ? 'Скопировано: ${f.label.toLowerCase()}'
          : 'Скопировано записей: ${jobs.length} · ${f.label.toLowerCase()}';
    });
    _persist();
  }

  Future<void> _write(Job job, String path, ExportFormat f) async =>
      File(path).writeAsString(_render(job, f));

  Future<void> _saveAs([ExportFormat? format]) async {
    final f = format ?? formatById(_saveFormat);
    final jobs = _readyTargets;
    if (jobs.isEmpty) return;
    setState(() => _saveFormat = f.id);
    _persist();

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
    final path = _ext(loc.path) == f.ext ? loc.path : '${loc.path}${f.ext}';
    await _write(job, path, f);
    setState(() => _status = 'Сохранено: «${path.split('/').last}»');
  }

  Future<void> _exportAll() async {
    final jobs = _readyTargets.isNotEmpty
        ? _readyTargets
        : _jobs.where((j) => j.done).toList();
    if (jobs.isEmpty) return;
    await _exportInto(jobs, _libraryFormats.map(formatById).toList());
  }

  Future<void> _exportInto(List<Job> jobs, List<ExportFormat> formats) async {
    if (formats.isEmpty) return;
    final dir = await getDirectoryPath(confirmButtonText: 'Экспортировать');
    if (dir == null) return;
    var written = 0;
    for (final job in jobs) {
      final stem = formats.length == 1
          ? freeStem(dir, _stem(job.name), formats.first.suffix)
          : _stem(job.name);
      for (final f in formats) {
        await _write(job, '$dir/${f.fileName(stem)}', f);
        written++;
      }
    }
    setState(() => _status = 'Экспортировано: ${filesLabel(written)}');
  }

  Future<void> _import([String? path]) async {
    var target = path;
    if (target == null) {
      final f = await openFile(acceptedTypeGroups: [
        XTypeGroup(
          label: 'Расшифровки',
          extensions: transcriptExt.map((e) => e.substring(1)).toList(),
        ),
      ]);
      if (f == null) return;
      target = f.path;
    }
    if (_jobs.any((j) => j.file.path == target)) {
      setState(() => _status = 'Эта расшифровка уже открыта');
      return;
    }

    final job = Job(File(target), imported: true);
    final text = await File(target).readAsString();
    // JSON, субтитры и наш «текст с таймкодами» разбираются в сегменты —
    // такую расшифровку можно пересохранить в любой другой формат.
    if (target.endsWith('.json')) {
      try {
        job.transcript = parseWhisperJson(text);
      } catch (_) {
        job.raw = text;
      }
    } else {
      job.transcript = parseSubtitles(text);
      if (job.transcript == null) job.raw = text;
    }
    job.state = JobState.done;
    job.detail = job.transcript != null
        ? 'Открыто · ${segmentsLabel(job.transcript!.segments.length)}'
        : 'Открыто · текст';
    _remember(target);
    setState(() => _jobs.add(job));
    _select(job);
  }

  Future<void> _pickModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML', extensions: ['bin'])]);
    if (f == null) return;
    setState(() {
      if (!_models.contains(f.path)) _models = [..._models, f.path];
    });
    _edit((o) => o.copyWith(model: f.path));
  }

  Future<void> _pickLibrary() async {
    final dir = await getDirectoryPath(
      confirmButtonText: 'Выбрать',
      initialDirectory:
          Directory(_libraryPath).existsSync() ? _libraryPath : '$home/Documents',
    );
    if (dir == null) return;
    setState(() {
      _libraryPath = dir;
      _status = 'Библиотека: $dir';
    });
    _persist();
  }

  Future<void> _pickVadModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML VAD', extensions: ['bin'])]);
    if (f == null) {
      _edit((o) => o.copyWith(vad: false));
      return;
    }
    _edit((o) => o.copyWith(vadModel: f.path, vad: true));
  }

  // ── диалоги ───────────────────────────────────────────────────────────────

  void _alert(String title, String message) => showMacosAlertDialog<void>(
        context: context,
        builder: (dialogContext) => MacosAlertDialog(
          appIcon: const MacosIcon(CupertinoIcons.waveform, size: 56),
          title: Text(title, style: Type.emptyTitle),
          message: Text(message, textAlign: TextAlign.center, style: Type.control),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Понятно'),
          ),
        ),
      );

  Future<bool> _confirm(String title, String message) async {
    var result = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.waveform_circle, size: 56),
        title: Text(title, style: Type.emptyTitle),
        message: Text(message, textAlign: TextAlign.center, style: Type.control),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            result = true;
            Navigator.pop(dialogContext);
          },
          child: const Text('Продолжить'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
      ),
    );
    return result;
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

  // ── меню в строке меню ────────────────────────────────────────────────────

  static const _cmd = SingleActivator(LogicalKeyboardKey.keyO, meta: true);

  String? _menuSignature;
  List<PlatformMenuItem> _menuCache = const [];

  /// PlatformMenuItem сравнивается по ссылке, поэтому Flutter пересобирает
  /// NSMenu на каждый setState — а во время распознавания их десятки в секунду.
  /// Пересобираем меню только когда меняется то, что в нём видно.
  List<PlatformMenuItem> _menus() {
    final signature = [
      _readyTargets.isNotEmpty,
      _targets.isNotEmpty,
      _targets.any((j) => !j.imported),
      _running,
      _hasPending,
      _jobs.any((j) => j.done),
      _jobs.isEmpty,
      _sel.isEmpty,
      _job == null,
      _timestamps,
      _yieldBusyModel,
      _lead?.file.path,
      _recent.join(' '),
    ].join('');
    if (signature == _menuSignature) return _menuCache;
    _menuSignature = signature;
    return _menuCache = _buildMenus();
  }

  List<PlatformMenuItem> _buildMenus() {
    final ready = _readyTargets.isNotEmpty;
    final selected = _targets.isNotEmpty;
    return [
      PlatformMenu(
        label: appName,
        menus: [
          PlatformMenuItem(label: 'О программе $appName', onSelected: _about),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Файл',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Добавить аудио…', shortcut: _cmd, onSelected: _pickFiles),
            PlatformMenuItem(
              label: 'Открыть расшифровку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
              onSelected: () => _import(),
            ),
            PlatformMenu(
              label: 'Открыть недавние',
              menus: [
                for (final p in _recent)
                  PlatformMenuItem(
                    label: p.split('/').last,
                    onSelected: () => audioExt.contains(_ext(p))
                        ? _addPaths([p])
                        : _import(p),
                  ),
                if (_recent.isNotEmpty)
                  PlatformMenuItemGroup(members: [
                    PlatformMenuItem(
                      label: 'Очистить список',
                      onSelected: () {
                        setState(() => _recent = const []);
                        _persist();
                      },
                    ),
                  ]),
              ],
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Сохранить как…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
              onSelected: ready ? () => _saveAs() : null,
            ),
            PlatformMenuItem(
              label: 'Экспортировать в папку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true),
              onSelected: _jobs.any((j) => j.done) ? _exportAll : null,
            ),
            PlatformMenuItem(
              label: 'Показать библиотеку в Finder',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true),
              onSelected: () => revealInFinder(_libraryPath),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Показать исходный файл в Finder',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
              onSelected: _lead == null ? null : () => revealInFinder(_lead!.file.path),
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Правка',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Скопировать текст',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true),
              onSelected: ready ? () => _copy(formatPlainText) : null,
            ),
            PlatformMenuItem(
              label: 'Скопировать с таймкодами',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC,
                  meta: true, shift: true, alt: true),
              onSelected: ready ? () => _copy(formatTimedText) : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Выбрать все записи',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
              onSelected: _jobs.isEmpty ? null : _selectAll,
            ),
            PlatformMenuItem(
              label: 'Снять выделение',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true),
              onSelected: _sel.isEmpty ? null : _deselect,
            ),
            PlatformMenuItem(
              label: 'Убрать из очереди',
              shortcut: const SingleActivator(LogicalKeyboardKey.backspace, meta: true),
              onSelected: selected ? _removeSelected : null,
            ),
            PlatformMenuItem(
              label: 'Убрать все готовые',
              onSelected: _jobs.any((j) => j.done) ? _clearFinished : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Найти в расшифровке…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
              onSelected: _job == null ? null : _openFind,
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Распознавание',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Распознать очередь',
              shortcut: const SingleActivator(LogicalKeyboardKey.enter, meta: true),
              onSelected: _running || !_hasPending ? null : _start,
            ),
            PlatformMenuItem(
              label: 'Распознать заново',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true),
              onSelected:
                  _running || !_targets.any((j) => !j.imported) ? null : _retry,
            ),
            PlatformMenuItem(
              label: 'Остановить',
              shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
              onSelected: _running ? _stop : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: _yieldBusyModel
                  ? 'Не ждать занятую модель'
                  : 'Ждать, если модель занята',
              onSelected: () {
                setState(() => _yieldBusyModel = !_yieldBusyModel);
                _persist();
              },
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Вид',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: _timestamps ? 'Скрыть метки времени' : 'Показать метки времени',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, alt: true),
              onSelected: () {
                setState(() => _timestamps = !_timestamps);
                _persist();
              },
            ),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
          ]),
        ],
      ),
      const PlatformMenu(
        label: 'Окно',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Справка',
        menus: [
          PlatformMenuItem(
            label: 'Где лежат расшифровки',
            onSelected: () => revealInFinder(_libraryPath),
          ),
          PlatformMenuItem(label: 'О программе $appName', onSelected: _about),
        ],
      ),
    ];
  }

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
    if (job == null) {
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
            _pickVadModel();
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

class _ToolbarTitle extends StatelessWidget {
  const _ToolbarTitle({this.subtitle});
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(appName, style: Type.navTitle),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
        ],
      );
}

/// Шапка инспектора: к чему относится то, что ниже. Без неё правка настроек
/// при выбранной записи выглядела бы как правка общих.
class _ScopeBanner extends StatelessWidget {
  const _ScopeBanner({
    required this.selection,
    required this.name,
    required this.changed,
    required this.onReset,
    required this.onMakeDefault,
  });

  final int selection;
  final String? name;
  final List<String> changed;
  final VoidCallback? onReset, onMakeDefault;

  @override
  Widget build(BuildContext context) {
    final (title, hint) = switch (selection) {
      0 => ('Настройки по умолчанию', 'Применяются ко всем новым записям.'),
      1 => (
          name ?? 'Запись',
          changed.isEmpty
              ? 'Настройки как по умолчанию. Изменения здесь коснутся только этой записи.'
              : 'Своё: ${changed.join(', ')}.'
        ),
      _ => (
          'Выбрано: ${recordsLabel(selection)}',
          'Изменения применятся ко всем выбранным записям.'
        ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: Surface.hover(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MacosIcon(
                selection == 0 ? CupertinoIcons.slider_horizontal_3 : CupertinoIcons.doc_text,
                size: 13,
                color: Surface.secondaryText(context),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.fileName),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: Type.caption.copyWith(
              color: Surface.secondaryText(context),
              height: 1.35,
            ),
          ),
          if (onReset != null) ...[
            const SizedBox(height: 9),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onReset,
                  child: const Text('Вернуть общие'),
                ),
                const SizedBox(width: 6),
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: onMakeDefault,
                  child: const Text('Сделать общими'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    required this.job,
    required this.selected,
    required this.lead,
    required this.customised,
    required this.onTap,
  });
  final Job job;
  final bool selected, lead, customised;
  final VoidCallback onTap;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final accent = MacosTheme.of(context).primaryColor;
    // Выделено несколько — ведущая запись (её показывает инспектор) плотнее.
    final bg = widget.selected
        ? (widget.lead ? accent : accent.withValues(alpha: 0.75))
        : _down
            ? Surface.pressed(context)
            : _hover
                ? Surface.hover(context)
                : MacosColors.transparent;
    final fg = widget.selected ? MacosColors.white : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Подсветка на нажатии, не на отпускании.
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StateGlyph(job: job, tint: fg),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.fileName.copyWith(color: fg),
                    ),
                  ),
                  // Отметка «у этой записи свои настройки» — иначе о них
                  // узнаёшь только открыв инспектор.
                  if (widget.customised)
                    MacosTooltip(
                      message: 'Свои настройки распознавания',
                      child: MacosIcon(
                        CupertinoIcons.slider_horizontal_3,
                        size: 12,
                        color: fg ?? Surface.secondaryText(context),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 1),
                child: Text(
                  job.detail ?? job.state.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.caption.copyWith(
                    color: fg?.withValues(alpha: 0.75) ?? Surface.secondaryText(context),
                  ),
                ),
              ),
              // Прогресс живёт рядом со своим файлом, а не в общей строке снизу.
              if (job.active)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 6, right: 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: (fg ?? accent).withValues(alpha: 0.22),
                            ),
                          ),
                          AnimatedFractionallySizedBox(
                            duration: Motion.dur(context, Motion.settle),
                            curve: Motion.curve(context, Motion.settleCurve),
                            widthFactor: job.progress.clamp(0.02, 1),
                            child: ColoredBox(color: fg ?? accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.job, this.tint});
  final Job job;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (job.state) {
      JobState.done => (CupertinoIcons.checkmark_circle_fill, MacosColors.systemGreenColor),
      JobState.failed => (
          CupertinoIcons.exclamationmark_circle_fill,
          MacosColors.systemRedColor
        ),
      JobState.cancelled => (CupertinoIcons.minus_circle, Surface.secondaryText(context)),
      JobState.waiting => (CupertinoIcons.clock, MacosColors.systemOrangeColor),
      JobState.converting || JobState.transcribing => (
          CupertinoIcons.waveform_circle_fill,
          MacosTheme.of(context).primaryColor
        ),
      JobState.queued => (CupertinoIcons.circle, Surface.secondaryText(context)),
    };
    return AnimatedSwitcher(
      duration: Motion.dur(context, Motion.quick),
      switchInCurve: Motion.curve(context, Motion.quickCurve),
      child: MacosIcon(icon, key: ValueKey(icon.codePoint), size: 15, color: tint ?? color),
    );
  }
}

/// Фрагмент: появляется снизу вверх — оттуда же, откуда его выдаёт модель.
class _SegmentRow extends StatefulWidget {
  const _SegmentRow({
    super.key,
    required this.segment,
    required this.showTimestamp,
    required this.onCopied,
    this.highlight = '',
  });
  final Segment segment;
  final bool showTimestamp;
  final VoidCallback onCopied;
  final String highlight;

  @override
  State<_SegmentRow> createState() => _SegmentRowState();
}

class _SegmentRowState extends State<_SegmentRow> with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Motion.settle,
  )..forward();
  bool _hover = false, _copied = false;
  Timer? _resetCopied;

  @override
  void dispose() {
    _resetCopied?.cancel();
    _enter.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.segment.text));
    setState(() => _copied = true);
    widget.onCopied();
    _resetCopied?.cancel();
    _resetCopied = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Найденное подсвечивается прямо в тексте — искать глазами по строке,
  /// которую только что нашёл поиск, было бы издевательством.
  TextSpan _spans(BuildContext context) {
    final text = widget.segment.text;
    final needle = widget.highlight;
    if (needle.isEmpty) return TextSpan(text: text, style: Type.body);

    final accent = MacosTheme.of(context).primaryColor;
    final spans = <TextSpan>[];
    final lower = text.toLowerCase(), q = needle.toLowerCase();
    var at = 0;
    while (true) {
      final hit = lower.indexOf(q, at);
      if (hit < 0) break;
      if (hit > at) spans.add(TextSpan(text: text.substring(at, hit)));
      spans.add(TextSpan(
        text: text.substring(hit, hit + q.length),
        style: TextStyle(backgroundColor: accent.withValues(alpha: 0.28)),
      ));
      at = hit + q.length;
    }
    spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: Type.body, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Motion.curve(context, Motion.settleCurve),
    );
    final slide = Motion.slide(context, 10);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Opacity(
          opacity: curve.value.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, slide * (1 - curve.value)),
            child: child,
          ),
        ),
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.quick),
          curve: Motion.curve(context, Motion.quickCurve),
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
          decoration: BoxDecoration(
            color: _copied
                ? MacosTheme.of(context).primaryColor.withValues(alpha: 0.14)
                : _hover
                    ? Surface.hover(context)
                    : MacosColors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showTimestamp)
                Padding(
                  padding: const EdgeInsets.only(right: 14, top: 2),
                  child: Text(
                    fmtTs(widget.segment.from).substring(0, 8),
                    style: Type.timestamp.copyWith(color: Surface.secondaryText(context)),
                  ),
                ),
              Expanded(child: SelectableText.rich(_spans(context))),
              SizedBox(
                width: 26,
                height: 22,
                child: AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  opacity: _hover || _copied ? 1 : 0,
                  child: MacosIconButton(
                    icon: MacosIcon(
                      _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
                      size: 13,
                      color: _copied ? MacosTheme.of(context).primaryColor : null,
                    ),
                    onPressed: _hover || _copied ? _copy : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Полог при перетаскивании: материал приходит с лёгким перелётом —
/// жест уже нёс импульс.
class _DropVeil extends StatelessWidget {
  const _DropVeil({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: Motion.dur(context, Motion.toss),
        curve: Motion.curve(context, Motion.tossCurve),
        opacity: active ? 1 : 0,
        child: AnimatedScale(
          duration: Motion.dur(context, Motion.toss),
          curve: Motion.curve(context, Motion.tossCurve),
          scale: active ? 1 : 0.97,
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 14, 14, 54),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.5),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Кот тянется навстречу файлу. Тыкать в него сейчас нельзя —
                  // вуаль и так перехватывает всё под собой.
                  const Mascot(
                    mood: Mood.surprised,
                    height: 116,
                    interactive: false,
                  ),
                  const SizedBox(height: 8),
                  Text('Отпустите — добавим в очередь',
                      style: Type.emptyTitle.copyWith(color: accent)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelChip extends StatefulWidget {
  const _ModelChip({
    required this.info,
    required this.yielding,
    required this.waiting,
    required this.onTap,
  });
  final ModelUse info;
  final bool yielding;

  /// Наша очередь прямо сейчас стоит из-за этого.
  final bool waiting;
  final VoidCallback onTap;

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.info.state) {
      ModelState.busy => MacosColors.systemOrangeColor,
      ModelState.loading => MacosColors.systemYellowColor,
      ModelState.free => MacosColors.systemGreenColor,
    };
    return MacosTooltip(
      message: '${widget.info.detail}\n'
          '${widget.yielding ? 'Очередь ждёт, пока модель освободится. Нажмите, чтобы не ждать.' : 'Работаем, даже если модель занята. Нажмите, чтобы уступать.'}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.dur(context, Motion.quick),
            curve: Motion.curve(context, Motion.quickCurve),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: _hover ? Surface.hover(context) : MacosColors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Пока мы стоим из-за соседа, точка пульсирует: состояние
                // временное, а не сломанное.
                _Dot(color: color, pulsing: widget.waiting),
                const SizedBox(width: 7),
                Text(
                  widget.info.label,
                  style: Type.caption.copyWith(
                    color: Surface.secondaryText(context),
                    decoration: widget.yielding ? null : TextDecoration.lineThrough,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing == old.pulsing) return;
    widget.pulsing ? _pulse.repeat(reverse: true) : _pulse.animateTo(0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => AnimatedContainer(
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: widget.color.withValues(
            alpha: reduced ? 1 : 1 - _pulse.value * 0.65,
          ),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(icon, size: 40, color: Surface.secondaryText(context)),
            const SizedBox(height: 14),
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
          ],
        ),
      );
}

/// Путь как объект, а не как строка настройки: по нему можно щёлкнуть
/// и попасть в саму папку.
class _LibraryPath extends StatefulWidget {
  const _LibraryPath({
    required this.path,
    required this.onReveal,
    required this.onChange,
  });
  final String path;
  final VoidCallback onReveal, onChange;

  @override
  State<_LibraryPath> createState() => _LibraryPathState();
}

class _LibraryPathState extends State<_LibraryPath> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final short = widget.path.replaceFirst(home, '~');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MacosTooltip(
          message: 'Показать в Finder',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onReveal,
              child: AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                curve: Motion.curve(context, Motion.quickCurve),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: _hover ? Surface.hover(context) : MacosColors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Surface.hairline(context)),
                ),
                child: Row(
                  children: [
                    MacosIcon(CupertinoIcons.folder,
                        size: 14, color: Surface.secondaryText(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        short,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.control,
                      ),
                    ),
                    AnimatedOpacity(
                      duration: Motion.dur(context, Motion.quick),
                      opacity: _hover ? 1 : 0,
                      child: MacosIcon(CupertinoIcons.arrow_up_right_square,
                          size: 13, color: Surface.secondaryText(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        PushButton(
          controlSize: ControlSize.small,
          secondary: true,
          onPressed: widget.onChange,
          child: const Text('Выбрать другую папку…'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 7),
        child: Text(
          text.toUpperCase(),
          style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          text,
          style: Type.caption.copyWith(
            color: Surface.secondaryText(context),
            height: 1.4,
          ),
        ),
      );
}

class _Check extends StatefulWidget {
  const _Check(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_Check> createState() => _CheckState();
}

class _CheckState extends State<_Check> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onChanged(!widget.value),
          child: AnimatedContainer(
            duration: Motion.dur(context, Motion.press),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: _hover ? Surface.hover(context) : MacosColors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MacosCheckbox(value: widget.value, onChanged: widget.onChanged),
                const SizedBox(width: 9),
                Expanded(child: Text(widget.label, style: Type.control)),
              ],
            ),
          ),
        ),
      );
}
