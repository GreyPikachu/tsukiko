part of 'main.dart';

/// Запуск распознавания: очередь по одной записи, уступка занятой
/// модели, разбор вывода whisper-cli и раскладка результата по
/// библиотеке.
extension _Transcribe on _HomePageState {
  // ── распознавание ─────────────────────────────────────────────────────────

  bool get _hasPending => _jobs.any((j) => !j.done && !j.imported);

  /// Очередь запущена, но стоит и уступает чужому распознаванию.
  bool get _waitingForModel =>
      _running && _jobs.any((j) => j.state == JobState.waiting);

  Future<void> _retry() async {
    final again = _targets.where((j) => !j.imported).toList();
    if (again.isEmpty || _running) return;
    _set(() {
      for (final job in again) {
        job.reset();
      }
      _status = again.length == 1
          ? 'Распознаём заново'
          : 'Распознаём заново: ${recordsLabel(again.length)}';
    });
    await _start();
  }

  /// Модель держит наш же сервер диктовки — уступать себе бессмысленно.
  /// Гасим его и работаем: на следующей диктовке он поднимется заново
  /// за 0,6 с. Чужого соседа это не касается — ему по-прежнему уступаем.
  void _freeOwnServer() {
    if (!_modelUse.busy) return;
    final ours = ourServerPid();
    if (ours == null || ours != _modelUse.pid) return;
    try {
      Process.killPid(ours, ProcessSignal.sigterm);
    } catch (_) {
      return;
    }
    // Занятость опрашивается раз в 700 мс, а состояние уже известно: без
    // этого очередь стояла бы, ожидая процесс, которого больше нет.
    _set(() {
      _modelUse = const ModelUse(ModelState.free);
      _status = 'Освободили модель от диктовки';
    });
  }

  /// Пока модель занята кем-то другим — стоим и не поднимаем свою.
  /// Состояние берём у общего опросчика: он и так обновляется каждые 700 мс,
  /// второй такой же опрос рядом только жёг бы процессор.
  /// Возвращает false, если ожидание прервали кнопкой «Остановить».
  Future<bool> _yieldWhileBusy(Job job) async {
    _freeOwnServer();
    var waited = false;
    while (_yieldBusyModel && !_stopRequested && _modelUse.busy) {
      if (!waited || job.state != JobState.waiting) {
        _set(() {
          job.state = JobState.waiting;
          _status = 'Уступаем: ${_modelUse.by} распознаёт речь';
        });
      }
      waited = true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (waited && !_stopRequested) {
      _set(() => _status = 'Модель освободилась — продолжаем');
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
      // Моделей нет вовсе — говорить «выберите модель» некорректно: выбирать
      // не из чего, человека надо вести в загрузчик.
      _alert(
        _models.isEmpty ? 'Нужна модель' : 'Не выбрана модель',
        _models.isEmpty
            ? 'Нажмите «Загрузить модель…» в панели справа.\n'
                'Tiny — 74 МБ, чтобы попробовать.'
            : 'Укажите файл ggml-*.bin в настройках справа.',
      );
      return;
    }
    if (!_hasPending) return;

    _freeOwnServer();
    if (!_yieldBusyModel && _modelUse.busy) {
      final go = await _confirm(
        'Модель уже занята',
        '${_modelUse.detail}\n'
        'Одновременная работа замедлит обе стороны. Продолжить?',
      );
      if (!go) return;
    }

    _set(() {
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
        _set(() {
          job.state = JobState.failed;
          job.detail = 'Не выбрана модель';
        });
        continue;
      }

      if (!await _yieldWhileBusy(job)) break;

      _set(() {
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

      _set(() {
        job.state = JobState.transcribing;
        _status = job.name;
      });
      final proc = await Process.start(whisper, buildArgs(opts, wav, base));
      _proc = proc;

      void onLine(String line) {
        if (!mounted) return;
        final seg = parseSegmentLine(line);
        if (seg != null) {
          _set(() => job.live.add(seg));
          _followTail();
          return;
        }
        final p = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
        if (p != null) {
          _set(() => job.progress = double.parse(p.group(1)!) / 100);
        }
        final l = RegExp(r'auto-detected language:\s*(\w+)').firstMatch(line);
        if (l != null) {
          _set(() => _status = '${job.name} · ${languageName(l.group(1)!)}');
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
        _set(() => job.state = JobState.cancelled);
        break;
      }

      final jsonFile = File('$base.json');
      if (code != 0 || !jsonFile.existsSync()) {
        _set(() {
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

      _set(() {
        job.progress = 1;
        job.state = JobState.done;
        job.took = job.startedAt == null
            ? null
            : DateTime.now().difference(job.startedAt!);
        job.detail = '${languageName(t.lang)} · ${segmentsLabel(t.segments.length)}';
        if (placed != null) _status = placed;
      });
    }

    _set(() {
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
    _set(() => _status = 'Останавливаем…');
  }
}
