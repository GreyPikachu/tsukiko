import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/features/queue/job.dart';
import 'package:tsukiko/features/queue/queue_bloc.dart';
import 'package:tsukiko/features/queue/queue_event.dart';
import 'package:tsukiko/features/queue/queue_state.dart';
import 'package:tsukiko/features/dictation/dictation_repository.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

/// Очередь распознавания. До выноса из виджета проверять её было нечем:
/// ни одну из этих веток нельзя было пройти без `pumpWidget`.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _FakeNative native;

  // Очередь читает настройки при создании и пишет их при правке.
  // Без подмены папок это был бы настоящий файл пользователя.
  useTempSupportDir('tsukiko-queue-app');

  setUp(() {
    // Строки идут через currentL10n(), который читает системный локаль.
    // Тестовый движок отдаёт en_US — здесь же тексты сверены с русским,
    // поэтому закрепляем его явно.
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    tmp = Directory.systemTemp.createTempSync('tsukiko-queue');
    native = _FakeNative()..install();
    NativeBridge.debugReset();
  });

  tearDown(() {
    native.remove();
    tmp.deleteSync(recursive: true);
  });

  QueueBloc make() => QueueBloc(NativeBridge());

  /// Диктовка живёт в другом изоляте, и в тестах её нет вовсе. Репозиторий
  /// затем и заведён, чтобы очередь спрашивала не канал, а его.
  QueueBloc makeWith(DictationStatus status) =>
      QueueBloc(NativeBridge(), dictation: _FakeDictation(status));

  /// Файл нужного расширения — очередь смотрит только на него и на то,
  /// существует ли путь.
  String file(String name) {
    final f = File('${tmp.path}/$name')..writeAsStringSync('звук');
    return f.path;
  }

  Job job(String name) => Job(File('${tmp.path}/$name'));

  group('очередь', () {
    blocTest<QueueBloc, QueueState>(
      'аудио попадает в очередь и сразу становится выбранным',
      build: make,
      act: (b) => b.add(FilesAdded([file('раз.m4a')])),
      verify: (b) {
        expect(b.state.jobs.length, 1);
        expect(b.state.jobs.single.name, 'раз.m4a');
        expect(b.state.lead, b.state.jobs.single);
        expect(b.state.status, 'Файл добавлен');
      },
    );

    blocTest<QueueBloc, QueueState>(
      'тот же файл второй раз не добавляется, и об этом говорят',
      build: make,
      act: (b) async {
        final p = file('раз.m4a');
        b.add(FilesAdded([p]));
        await Future<void>.delayed(Duration.zero);
        b.add(FilesAdded([p]));
      },
      wait: const Duration(milliseconds: 50),
      verify: (b) {
        expect(b.state.jobs.length, 1);
        // Молчаливый отказ — худший вид отказа: файл не появился,
        // и непонятно, почему.
        expect(b.state.status, 'Этот файл уже в очереди');
      },
    );

    blocTest<QueueBloc, QueueState>(
      'чужое расширение не берём, но объясняем',
      build: make,
      act: (b) => b.add(FilesAdded([file('таблица.xlsx')])),
      verify: (b) {
        expect(b.state.jobs, isEmpty);
        expect(b.state.status, 'Такие файлы не поддерживаются');
      },
    );

    blocTest<QueueBloc, QueueState>(
      'папка разворачивается в аудио внутри неё',
      build: make,
      act: (b) {
        final dir = Directory('${tmp.path}/записи')..createSync();
        File('${dir.path}/б.m4a').writeAsStringSync('звук');
        File('${dir.path}/а.mp3').writeAsStringSync('звук');
        File('${dir.path}/заметка.pdf').writeAsStringSync('не звук');
        b.add(FilesAdded([dir.path]));
      },
      verify: (b) {
        expect(b.state.jobs.map((j) => j.name), ['а.mp3', 'б.m4a']);
      },
    );

    blocTest<QueueBloc, QueueState>(
      'готовые субтитры открываются расшифровкой, а не заданием',
      build: make,
      act: (b) {
        final p = '${tmp.path}/речь.srt';
        File(p).writeAsStringSync(
            '1\n00:00:00,000 --> 00:00:01,500\nраз\n\n'
            '2\n00:00:01,500 --> 00:00:03,000\nдва\n');
        b.add(TranscriptOpened(p));
      },
      wait: const Duration(milliseconds: 50),
      verify: (b) {
        final j = b.state.jobs.single;
        expect(j.imported, isTrue, reason: 'распознавать в ней нечего');
        expect(j.state, JobState.done);
        expect(j.transcript?.segments.length, 2);
        expect(b.state.hasPending, isFalse);
      },
    );

    blocTest<QueueBloc, QueueState>(
      'двоичный файл под видом расшифровки не роняет очередь',
      build: make,
      act: (b) {
        final p = '${tmp.path}/битый.json';
        File(p).writeAsBytesSync([0xFF, 0xFE, 0x00, 0x01]);
        b.add(TranscriptOpened(p));
      },
      wait: const Duration(milliseconds: 50),
      verify: (b) {
        expect(b.state.jobs, isEmpty);
        expect(b.state.status, contains('не текстовый файл'));
      },
    );
  });

  group('выделение', () {
    late QueueBloc bloc;
    late List<Job> three;

    setUp(() async {
      bloc = make();
      bloc.add(FilesAdded([file('а.m4a'), file('б.m4a'), file('в.m4a')]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      three = bloc.state.jobs;
    });

    tearDown(() => bloc.close());

    test('щелчок выбирает одну и делает её ведущей', () async {
      bloc.add(JobSelected(three[1]));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selected, {three[1]});
      expect(bloc.state.lead, three[1]);
    });

    test('⌘-щелчок добавляет и убирает из выделения', () async {
      bloc.add(JobSelected(three[0]));
      bloc.add(JobToggled(three[2]));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selected.length, 2);

      bloc.add(JobToggled(three[2]));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selected, {three[0]});
    });

    test('⇧-щелчок берёт всё между ведущей и указанной', () async {
      bloc.add(JobSelected(three[0]));
      bloc.add(SelectionExtended(three[2]));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selected.length, 3);
      expect(bloc.state.lead, three[2]);
    });

    test('стрелки не уходят за края списка', () async {
      bloc.add(JobSelected(three[0]));
      bloc.add(const SelectionStepped(-1));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.lead, three[0]);

      bloc.add(JobSelected(three[2]));
      bloc.add(const SelectionStepped(1));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.lead, three[2]);
    });

    test('убрать выбранное: ведущей становится соседка, а не пустота',
        () async {
      bloc.add(JobSelected(three[1]));
      bloc.add(const SelectedRemoved());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.jobs.length, 2);
      expect(bloc.state.lead, isNotNull);
      expect(bloc.state.selected, {bloc.state.lead});
    });

    test('без выделения команда применяется к ведущей', () async {
      bloc.add(JobSelected(three[1]));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const SelectionCleared());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selected, isEmpty);
      expect(bloc.state.targets, isEmpty, reason: 'ведущей тоже нет');
    });
  });

  group('настройки распознавания', () {
    late QueueBloc bloc;

    setUp(() => bloc = make());
    tearDown(() => bloc.close());

    test('без выделения правка уходит в общие настройки', () async {
      bloc.add(OptionsEdited((o) => o.copyWith(lang: 'ru')));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.defaults.lang, 'ru');
    });

    test('с выделением правка уходит в записи, не трогая общих', () async {
      bloc.add(FilesAdded([file('а.m4a'), file('б.m4a')]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bloc.add(const AllSelected());
      await Future<void>.delayed(Duration.zero);

      bloc.add(OptionsEdited((o) => o.copyWith(lang: 'be')));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.jobs.every((j) => j.overrides?.lang == 'be'), isTrue);
      expect(bloc.state.defaults.lang, 'auto', reason: 'общие не тронуты');
    });

    test('«вернуть общие» стирает свои настройки записи', () async {
      bloc.add(FilesAdded([file('а.m4a')]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bloc.add(OptionsEdited((o) => o.copyWith(lang: 'ru')));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.jobs.single.overrides, isNotNull);

      bloc.add(const OverridesReset());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.jobs.single.overrides, isNull);
      expect(bloc.state.status, 'Настройки записи сброшены');
    });
  });

  group('запуск', () {
    blocTest<QueueBloc, QueueState>(
      'без whisper-cli очередь не идёт, а объясняет почему',
      build: make,
      seed: () => QueueState(
        jobs: [job('а.m4a')],
        whisperFound: false,
      ),
      act: (b) => b.add(const RunRequested()),
      verify: (b) {
        expect(b.state.running, isFalse);
        expect(b.state.ask?.title, 'Не найден whisper-cli');
      },
    );

    blocTest<QueueBloc, QueueState>(
      'без единой модели ведём в загрузчик, а не просим «выбрать»',
      build: make,
      seed: () => QueueState(
        jobs: [job('а.m4a')],
        whisperFound: true,
        models: const [],
      ),
      act: (b) => b.add(const RunRequested()),
      verify: (b) => expect(b.state.ask?.title, 'Нужна модель'),
    );

    blocTest<QueueBloc, QueueState>(
      'модель в памяти у молчащей диктовки — спрашиваем, а не забираем молча',
      build: () => makeWith(DictationStatus.resting),
      seed: () => QueueState(
        jobs: [job('а.m4a')],
        whisperFound: true,
        defaults: const RunOptions(model: '/m.bin', lang: 'auto', threads: 4),
      ),
      act: (b) => b.add(const RunRequested()),
      verify: (b) {
        expect(b.state.ask?.confirm, isTrue);
        expect(b.state.running, isFalse);
      },
    );

    blocTest<QueueBloc, QueueState>(
      'идущая диктовка молча пропускается вперёд: вопроса нет, очередь ждёт',
      build: () => makeWith(DictationStatus.busy),
      seed: () => QueueState(
        jobs: [job('а.m4a')],
        whisperFound: true,
        defaults: const RunOptions(model: '/m.bin', lang: 'auto', threads: 4),
      ),
      act: (b) => b.add(const RunRequested()),
      // Спрашивать нечего: прервать фразу нельзя, её можно только дождаться.
      verify: (b) => expect(b.state.ask, isNull),
    );

    blocTest<QueueBloc, QueueState>(
      'отказ на вопрос очередь не запускает',
      build: make,
      seed: () => const QueueState(
        ask: Ask('Модель уже занята', 'вопрос', confirm: true),
      ),
      act: (b) => b.add(const RunConfirmed(false)),
      verify: (b) {
        expect(b.state.ask, isNull);
        expect(b.state.running, isFalse);
      },
    );

    blocTest<QueueBloc, QueueState>(
      'пустая очередь не запускается и вопросов не задаёт',
      build: make,
      seed: () => const QueueState(whisperFound: true),
      act: (b) => b.add(const RunRequested()),
      verify: (b) {
        expect(b.state.running, isFalse);
        expect(b.state.ask, isNull);
      },
    );
  });

  group('состояние', () {
    test('«к чему применить»: выделение важнее ведущей', () {
      final a = job('а.m4a'), b = job('б.m4a');
      final s = QueueState(jobs: [a, b], selected: {b}, lead: a);
      expect(s.targets, [b]);

      final noSel = QueueState(jobs: [a, b], lead: a);
      expect(noSel.targets, [a]);
    });

    test('готовыми считаются только записи с текстом', () {
      final done = job('а.m4a').copyWith(
          transcript: const Transcript('ru', [Segment(0, 1, 'раз')]));
      final s = QueueState(jobs: [done, job('б.m4a')], selected: {done});
      expect(s.readyTargets, [done]);
    });

    test('импортированная расшифровка не считается ждущей распознавания', () {
      final imported = Job(File('${tmp.path}/речь.srt'),
          imported: true, raw: 'текст', state: JobState.done);
      expect(QueueState(jobs: [imported]).hasPending, isFalse);
      expect(QueueState(jobs: [job('а.m4a')]).hasPending, isTrue);
    });

    test('инспектор показывает общие настройки, пока ничего не выбрано', () {
      const mine = RunOptions(model: '/m.bin', lang: 'ru', threads: 8);
      final own = job('а.m4a').copyWith(overrides: mine);
      final s = QueueState(jobs: [own], lead: own);
      expect(s.shown.lang, 'auto', reason: 'выделения нет — общие');
      expect(QueueState(jobs: [own], selected: {own}, lead: own).shown, mine);
    });
  });

  group('запись очереди', () {
    test('фрагменты добавляются, не переписывая прежние', () {
      var j = job('а.m4a');
      j = j.withSegment(const Segment(0, 1000, 'раз'));
      j = j.withSegment(const Segment(1000, 2000, 'два'));
      expect(j.live.map((s) => s.text), ['раз', 'два']);
    });

    test('перестановка меняет очерёдность, а не состав', () async {
      final b = make();
      b.add(FilesAdded([file('а.m4a'), file('б.m4a'), file('в.m4a')]));
      await pumpEventQueue();
      b.add(const JobsReordered(2, 0));
      await pumpEventQueue();
      expect(b.state.jobs.map((j) => j.name), ['в.m4a', 'а.m4a', 'б.m4a']);
      await b.close();
    });

    test('«распознать заново» забывает и место остановки', () {
      final half = job('а.m4a').copyWith(
        state: JobState.paused,
        resumeFrom: 600000,
        live: const [Segment(0, 1000, 'раз')],
      );
      expect(half.paused, isTrue);
      expect(half.reset.resumeFrom, 0);
      expect(half.reset.live, isEmpty);
    });

    test('«распознать заново» забывает результат, но помнит свои настройки',
        () {
      const mine = RunOptions(model: '/m.bin', lang: 'ru', threads: 8);
      final done = job('а.m4a').copyWith(
        overrides: mine,
        state: JobState.done,
        transcript: const Transcript('ru', [Segment(0, 1, 'раз')]),
        progress: 1,
      );
      final again = done.reset;
      expect(again.transcript, isNull);
      expect(again.state, JobState.queued);
      expect(again.progress, 0);
      expect(again.overrides, mine, reason: 'настройки записи переживают сброс');
    });

    test('текст ошибки живёт отдельно от подписи и не переживает сброс', () {
      // Ошибка движка бывает в несколько строк, а в подпись под именем
      // записи влезает начало одной. Поэтому она хранится целиком
      // отдельным полем — его показывают подсказкой, кладут в инспектор
      // и отдают в буфер обмена. Но переживать «распознать заново» она
      // не должна: иначе удавшийся заход остался бы с чужой жалобой.
      final failed = job('а.m4a').copyWith(
        state: JobState.failed,
        detail: 'whisper-cli не справился · error',
        error: 'error: failed to load model\nfrom /m.bin',
      );
      expect(failed.error, contains('\n'), reason: 'храним весь вывод');
      expect(failed.reset.error, isNull);
      expect(failed.copyWith(clearDetail: true).error, isNull);
      expect(failed == failed.copyWith(error: 'другое'), isFalse,
          reason: 'перемена ошибки обязана дойти до перерисовки');
    });

    test('равные записи не заставляют очередь перерисовываться', () {
      final a = job('а.m4a');
      expect(a, a.copyWith());
      expect(a == a.copyWith(progress: 0.5), isFalse);
      // Длина живого списка входит в сравнение: новый фрагмент виден.
      expect(a == a.withSegment(const Segment(0, 1, 'раз')), isFalse);
    });
  });

  group('настройки приложения', () {
    test('форматы перечитываются после правки в окне настроек', () async {
      final bloc = make();
      await Settings.save({'copyFormat': 'json', 'saveFormat': 'vtt'});
      bloc.add(const SettingsReloaded());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.copyFormat, 'json');
      expect(bloc.state.saveFormat, 'vtt');
      await bloc.close();
    });

    blocTest<QueueBloc, QueueState>(
      'метки времени переключаются и переживают перечитывание',
      build: make,
      seed: () => const QueueState(timestamps: true),
      act: (b) => b.add(const TimestampsToggled()),
      verify: (b) => expect(b.state.timestamps, isFalse),
    );

    blocTest<QueueBloc, QueueState>(
      'список недавних чистится',
      build: make,
      seed: () => const QueueState(recent: ['/a.m4a', '/b.m4a']),
      act: (b) => b.add(const RecentCleared()),
      verify: (b) => expect(b.state.recent, isEmpty),
    );
  });

  group('запись вместе с расшифровкой', () {
    test('открытая из обзора запись приходит с готовым текстом', () async {
      final audio = file('вчера.m4a');
      final transcript = '${tmp.path}/вчера.txt';
      File(transcript).writeAsStringSync(
          '[00:00:00.000 --> 00:00:02.000]  Сказанное вслух\n');

      final bloc = make();
      bloc.add(SourceOpened(audio, transcript));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final job = bloc.state.jobs.single;
      expect(job.path, audio, reason: 'в очереди сама запись, а не текст');
      expect(job.done, isTrue, reason: 'расшифровка уже есть, и она видна');
      expect(job.segments.single.text, 'Сказанное вслух');
      // Не «открыта из файла»: считать её заново никто не мешает.
      expect(job.imported, isFalse);
      expect(bloc.state.canRetry, isTrue);
      await bloc.close();
    });
  });

  group('запись настроек на диск', () {
    test('очередь пишет своё и не трогает чужие ключи', () async {
      await Settings.save({'libraryPath': '/чужое/значение'});

      final bloc = make();
      bloc.add(OptionsEdited((o) => o.copyWith(lang: 'kk')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await bloc.flushSettings();
      await bloc.close();

      final after = Settings.load();
      expect(after['lang'], 'kk');
      // Библиотеку правит окно настроек — очередь обязана оставить её как есть.
      expect(after['libraryPath'], '/чужое/значение');
    });

    test('подсказка ложится рядом с расшифровками и возвращается оттуда',
        () async {
      // Установщик Windows стирает настройки при удалении намеренно, и
      // вместе с ними уносил собранный вручную список слов. Запасная копия
      // живёт в библиотеке — её установщик не трогает.
      await Settings.save({'libraryPath': '${tmp.path}/библиотека'});

      final bloc = make();
      bloc.add(OptionsEdited((o) => o.copyWith(prompt: 'Рында, Микша, Лаба')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await bloc.flushSettings();
      await bloc.close();

      expect(Prompts.read(Prompts.transcriber), 'Рында, Микша, Лаба');
      expect(File('${tmp.path}/библиотека/prompts.json').existsSync(), isTrue);
    });
  });

}

/// Подставная родная сторона: очередь спрашивает у неё разрешение забрать
/// модель и слушает «настройки перечитать».
class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');
  final calls = <String>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'requestModel' => true,
        'permissions' => true,
        _ => null,
      };
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Диктовка, которая всегда в одном и том же состоянии.
class _FakeDictation implements DictationRepository {
  _FakeDictation(this._status);
  final DictationStatus _status;
  var released = false;

  @override
  Future<DictationStatus> status() async => _status;

  @override
  Future<void> release() async => released = true;
}
