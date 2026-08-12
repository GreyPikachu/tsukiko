part of 'main.dart';

/// Очередь и выделение: что в списке и что из него выбрано.
/// Ни одна из этих операций не запускает распознавание — они только
/// решают, к чему оно потом применится.
extension _Queue on _HomePageState {
  // ── выделение ─────────────────────────────────────────────────────────────

  Job? get _job => _lead;

  /// Что попадёт под команду: выбранное, а если не выбрано ничего —
  /// ведущая запись. Так меню и кнопки одинаково понимают «применить к».
  List<Job> get _targets =>
      _sel.isNotEmpty ? _jobs.where(_sel.contains).toList() : [?_lead];

  List<Job> get _readyTargets => _targets.where((j) => j.done).toList();

  void _select(Job job) {
    _set(() {
      _sel
        ..clear()
        ..add(job);
      _lead = job;
    });
    _syncPromptField();
  }

  void _toggleSelect(Job job) {
    _set(() {
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
    _set(() {
      _sel.addAll(_jobs.sublist(a < b ? a : b, (a < b ? b : a) + 1));
      _lead = job;
    });
    _syncPromptField();
  }

  void _selectAll() {
    if (_jobs.isEmpty) return;
    _set(() {
      _sel
        ..clear()
        ..addAll(_jobs);
      _lead ??= _jobs.first;
    });
    _syncPromptField();
  }

  void _deselect() {
    _set(() {
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
    _set(() => _recent = [path, ..._recent.where((p) => p != path)].take(10).toList());
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
    _set(() {
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
    _set(() {
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
    _set(() {
      _jobs.removeWhere(doomed.contains);
      _sel.removeAll(doomed);
      if (doomed.contains(_lead)) _lead = _jobs.isEmpty ? null : _jobs.first;
      _status = 'Готовые записи убраны';
    });
    _syncPromptField();
  }
}
