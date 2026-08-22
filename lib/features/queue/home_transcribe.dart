part of 'home_page.dart';

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

  /// Занята ли модель нашей же диктовкой. Своего от чужого отличаем по
  /// pid, который сами и записали: рядом может работать чужой
  /// whisper-server, по имени процесса они неразличимы.
  ///
  /// Значение готовое, из опроса. Раньше здесь запускался `ps` — и не
  /// только на каждый кадр, но и на каждом витке ожидания в 300 мс, пока
  /// очередь уступала диктовке.
  bool get _busyByDictation =>
      _modelUse.busy && _modelUse.pid != 0 && _modelUse.pid == _serverPid;

  /// Диктовка главнее очереди: одновременно две копии модели в память
  /// не помещаются, а фраза длится секунды и прерванная пропадает совсем.
  /// Поэтому очередь спрашивает разрешения у диктовки и ждёт, пока та
  /// говорит; простаивающий сервер она отдаёт сразу.
  ///
  /// Текущий файл при этом дорабатывается до конца: спрашиваем перед
  /// запуском следующего, а не посреди распознавания.
  Future<bool> _yieldToDictation(Job job) async {
    var paused = false;
    while (!_stopRequested && !await _mac.requestModel()) {
      if (!paused) {
        _set(() {
          job.state = JobState.waiting;
          _status = 'Пауза — идёт диктовка';
        });
        paused = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (paused && !_stopRequested) {
      _set(() => _status = 'Диктовка закончилась — продолжаем');
    }
    return !_stopRequested;
  }

  /// Пока модель занята кем-то другим — стоим и не поднимаем свою.
  /// Состояние берём у общего опросчика: он и так обновляется каждые 700 мс,
  /// второй такой же опрос рядом только жёг бы процессор.
  /// Возвращает false, если ожидание прервали кнопкой «Остановить».
  Future<bool> _yieldWhileBusy(Job job) async {
    if (!await _yieldToDictation(job)) return false;
    var waited = false;
    // Свою диктовку из этого счёта исключаем: с ней договорились выше,
    // а опрос отстаёт на 700 мс и показывал бы уже погашенный сервер.
    while (_yieldBusyModel &&
        !_stopRequested &&
        _modelUse.busy &&
        !_busyByDictation) {
      if (!waited || job.state != JobState.waiting) {
        _set(() {
          job.state = JobState.waiting;
          _status = 'Уступаем: $_modelUseBy распознаёт речь';
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
          'Программа не нашлась ни в PATH, ни в обычных местах.\n'
          '${os.whisperInstallHint}');
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

    if (!_yieldBusyModel && _modelUse.busy && !_busyByDictation) {
      final go = await _confirm(
        'Модель уже занята',
        '$_modelUseDetail\n'
        'Одновременная работа замедлит обе стороны. Продолжить?',
      );
      if (!go) return;
    }

    _set(() {
      _running = true;
      _stopRequested = false;
    });
    // Пока идёт очередь, опрос занятости нужен даже со свёрнутым окном:
    // на него смотрит уступка занятой модели.
    _syncPolling();

    // Что бы ни случилось внутри — разбор битого JSON, полный диск,
    // исчезнувший файл, — очередь обязана вернуться в состояние покоя.
    // Без этого одно исключение оставляло «идёт распознавание» навсегда:
    // кнопка «Распознать» серая, «Остановить» ничего не останавливает,
    // и помогал только перезапуск.
    try {
      _tmp ??= await Directory.systemTemp.createTemp(appName);
      // Очередь берётся по одной записи за раз, а не обходом по индексу:
      // пока идёт распознавание, файлы и добавляют, и убирают, а обход
      // по номеру на такой правке перескакивает через соседа. Список
      // взятого нужен, чтобы неудачная запись не попалась второй раз:
      // «не получилось» — это не «готово», и без него цикл был бы вечным.
      final attempted = <Job>{};
      while (!_stopRequested) {
        Job? next;
        for (final job in _jobs) {
          if (!job.done && !job.imported && !attempted.contains(job)) {
            next = job;
            break;
          }
        }
        if (next == null) break;
        attempted.add(next);
        if (!await _runOne(next, whisper)) break;
      }
    } finally {
      _proc = null;
      _set(() {
        _running = false;
        _status = _stopRequested ? 'Остановлено' : 'Готово';
      });
      _syncPolling();
      _releaseTemp();
      _writeSettings();
    }
  }

  /// Отдать временную папку, когда очередь отработала.
  ///
  /// Раньше она удалялась только в dispose, мимо которого проходит ⌘Q, —
  /// и подготовленный звук (час записи это больше сотни мегабайт) оставался
  /// во временной папке навсегда. Файлы каждой записи убираются сразу после
  /// неё, здесь остаётся снять пустую папку.
  void _releaseTemp() {
    final dir = _tmp;
    if (dir == null) return;
    _tmp = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Одна запись от начала до конца. Возвращает false, если очередь надо
  /// остановить целиком (нажали «Остановить»); неудача самой записи —
  /// это true: соседние файлы к ней отношения не имеют.
  Future<bool> _runOne(Job job, String whisper) async {
    final opts = _optionsFor(job);
    if (opts.model.isEmpty) {
      _set(() {
        job.state = JobState.failed;
        job.detail = 'Не выбрана модель';
      });
      return true;
    }

    if (!await _yieldWhileBusy(job)) return false;

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

    // Имя во временной папке своё у каждого запуска, а не по месту записи
    // в очереди. С индексом получалось так: очередь поправили, номер достался
    // другому файлу, whisper вышел без ошибки, но json не записал — и
    // проверка «файл на месте» проходила на json от прошлого прогона.
    // В запись попадала чужая расшифровка.
    final base = os.join(_tmp!.path, '${_runSeq++}');
    final jsonFile = File('$base.json');
    try {
      final wav = await toWav(job.file.path, '$base.wav');

      // Подготовка звука занимает секунды — за это время сосед мог начать
      // распознавать заново. Проверяем ещё раз вплотную к запуску.
      if (!await _yieldWhileBusy(job)) return false;

      _set(() {
        job.state = JobState.transcribing;
        _status = job.name;
      });

      final code = await _runWhisper(job, whisper, buildArgs(opts, wav, base));
      if (_stopRequested) {
        _set(() => job.state = JobState.cancelled);
        return false;
      }
      if (code != 0 || !jsonFile.existsSync()) {
        _set(() {
          job.state = JobState.failed;
          job.detail = 'whisper-cli не справился с этим файлом';
          _status = 'Не удалось распознать «${job.name}»';
        });
        return true;
      }

      final t = parseWhisperJson(await jsonFile.readAsString());
      job.transcript = t;

      final beside = _saveNextToSource ? await _saveBesideSource(job, t) : null;
      final placed = _toLibrary ? await _fileToLibrary(job) : null;

      _set(() {
        job.progress = 1;
        job.state = JobState.done;
        job.took = job.startedAt == null
            ? null
            : DateTime.now().difference(job.startedAt!);
        job.detail = '${languageName(t.lang)} · ${segmentsLabel(t.segments.length)}';
        // Про неудачу записи говорим громче, чем про удачу: текст есть
        // на экране, но человек думает, что он уже на диске.
        _status = beside ?? placed ?? _status;
      });
      return true;
    } catch (e) {
      // Сюда попадает всё непредвиденное: битый JSON от whisper, файл,
      // исчезнувший из-под рук, нехватка места. Запись помечается неудачной,
      // очередь идёт дальше.
      _set(() {
        job.state = JobState.failed;
        job.detail = 'Не удалось разобрать ответ модели';
        _status = 'Не удалось распознать «${job.name}»';
      });
      stderr.writeln('tsukiko: «${job.name}» не распозналась — $e');
      return true;
    } finally {
      // Временные файлы этого запуска больше не нужны ни нам, ни соседу:
      // часовая запись оставляет после себя гигабайтный wav.
      _discardTemp(base);
    }
  }

  /// Запуск whisper-cli с разбором его вывода на лету. Подписки снимаются
  /// в любом случае — оборванный процесс не должен оставлять их висеть.
  Future<int> _runWhisper(Job job, String whisper, List<String> args) async {
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

    final proc = await Process.start(whisper, args);
    _proc = proc;
    final outSub =
        proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    final errSub =
        proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
    try {
      return await proc.exitCode;
    } finally {
      await outSub.cancel();
      await errSub.cancel();
      _proc = null;
    }
  }

  void _discardTemp(String base) {
    for (final ext in const ['.wav', '.json']) {
      try {
        final f = File('$base$ext');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// Копия текста рядом с исходной записью. Возвращает строку для статуса,
  /// если что-то пошло не так, иначе null.
  ///
  /// Имя выбирается один раз и запоминается за записью: повторное
  /// распознавание обновляет свой же файл, а чужой `запись.txt`, лежавший
  /// рядом до нас, не трогает — раньше он затирался молча.
  Future<String?> _saveBesideSource(Job job, Transcript t) async {
    try {
      // Раньше здесь стояло `path.substring(0, path.lastIndexOf('.'))`:
      // у файла без расширения lastIndexOf возвращал −1, и всё падало
      // в пустой catch.
      final dir = job.file.parent.path;
      job.besideSource ??=
          os.join(dir, '${freeStem(dir, _stem(job.name), '.txt')}.txt');
      await File(job.besideSource!).writeAsString(renderPlain(t.segments, false));
      return null;
    } catch (e) {
      stderr.writeln('tsukiko: копия рядом с записью не легла — $e');
      return 'Не удалось положить текст рядом с записью';
    }
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
        await _write(job, os.join(plan.dir, f.fileName(stem)), f);
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
