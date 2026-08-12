part of 'main.dart';

/// Всё, что уносит расшифровку наружу: буфер обмена, «Сохранить как…»,
/// экспорт папкой — и обратный путь, открытие готовой расшифровки.
extension _Export on _HomePageState {
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
    _set(() {
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
    _set(() => _saveFormat = f.id);
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
    _set(() => _status = 'Сохранено: «${path.split('/').last}»');
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
    _set(() => _status = 'Экспортировано: ${filesLabel(written)}');
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
      _set(() => _status = 'Эта расшифровка уже открыта');
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
    _set(() => _jobs.add(job));
    _select(job);
  }

  Future<void> _pickModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML', extensions: ['bin'])]);
    if (f == null) return;
    _set(() {
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
    _set(() {
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
}
