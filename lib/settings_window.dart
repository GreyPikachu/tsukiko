import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:macos_ui/macos_ui.dart';

import 'design.dart';
import 'dictation.dart';
import 'engine.dart';
import 'platform_mac.dart';

/// Окно настроек: своё окно с вкладками, как у всех приложений macOS.
///
/// Живёт на третьем движке Flutter — том, что создаётся при первом ⌘,.
/// Иначе никак: движок отдаёт один вид одному окну, а главное окно и
/// панель у строки меню свои виды уже заняли. Настройки — не главное
/// окно расшифровщика: диктовка настраивается и тогда, когда очереди
/// нет вовсе, а без значка в Dock главного окна может не быть на экране.
///
/// Общие настройки приложения лежат в том же settings.json, что правит
/// главное окно. Ключи не пересекаются, Settings.save дописывает, а не
/// переписывает, и после каждой правки оба соседних изолята получают
/// «reload» — значит копии не расходятся.
void runSettings() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SettingsApp(MacPlatform()));
}

const settingsTabs = [
  (id: 'dictation', label: 'Диктовка', icon: CupertinoIcons.mic),
  (id: 'models', label: 'Модели', icon: CupertinoIcons.cube_box),
  (id: 'library', label: 'Библиотека', icon: CupertinoIcons.folder),
  (id: 'general', label: 'Общие', icon: CupertinoIcons.gear),
];

class SettingsApp extends StatelessWidget {
  const SettingsApp(this.platform, {super.key});
  final MacPlatform platform;

  @override
  Widget build(BuildContext context) => MacosApp(
        title: 'Настройки',
        theme: MacosThemeData.light(),
        darkTheme: MacosThemeData.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        home: SettingsBody(platform),
      );
}

class SettingsBody extends StatefulWidget {
  const SettingsBody(this.platform, {super.key});
  final MacPlatform platform;

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody> {
  MacPlatform get _mac => widget.platform;

  final _dictation = DictationSettings.load();
  final _promptCtrl = TextEditingController();

  String _tab = 'dictation';
  List<String> _models = findModels();
  Download? _download;

  /// Почему выбранный файл не годится в модель. Пусто — всё хорошо.
  String? _problem;
  bool _allowed = true;
  int _denied = 0;
  Timer? _timer;

  // Настройки приложения: правит их это окно, пользуется ими главное.
  bool _toLibrary = true, _saveNextToSource = false, _timestamps = true;
  bool _yieldBusyModel = true, _dockIcon = true;
  String _libraryPath = defaultLibraryPath;
  List<String> _libraryFormats = const ['txt'];

  @override
  void initState() {
    super.initState();
    _promptCtrl.text = _dictation.prompt;
    _readApp();
    _mac.settingsReloaded.listen((_) => setState(_readApp));
    _mac.settingsTab.listen((t) => setState(() => _tab = t));
    unawaited(_mac.initialTab().then((t) {
      if (mounted) setState(() => _tab = t);
    }));
    unawaited(_checkPermission());
    // Разрешение выдают в другом приложении и возвращаются к этому окну:
    // спрашивать надо самим, уведомления об этом нет.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _checkPermission());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _readApp() {
    final s = Settings.load();
    _toLibrary = (s['toLibrary'] as bool?) ?? true;
    _saveNextToSource = (s['saveNextToSource'] as bool?) ?? false;
    _timestamps = (s['timestamps'] as bool?) ?? true;
    _yieldBusyModel = (s['yieldBusyModel'] as bool?) ?? true;
    _dockIcon = (s['dockIcon'] as bool?) ?? true;
    _libraryPath = (s['libraryPath'] as String?) ?? defaultLibraryPath;
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    if (formats != null && formats.isNotEmpty) _libraryFormats = formats;
  }

  /// Тот же счёт отказов, что и в панели: сразу после запуска система
  /// отвечает «нет» и тем, у кого разрешение выдано, — верить одному
  /// ответу нельзя, иначе предупреждение мигает на ровном месте.
  Future<void> _checkPermission() async {
    final now = await _mac.permission();
    if (!mounted) return;
    if (now) {
      _denied = 0;
      if (!_allowed) setState(() => _allowed = true);
      return;
    }
    if (++_denied < 3 || !_allowed) return;
    setState(() => _allowed = false);
  }

  /// Одно место, где настройки уходят на диск: пишем и говорим соседним
  /// изолятам перечитать. Без второго половина правок доходила бы только
  /// до следующего запуска.
  void _saveApp(Map<String, dynamic> data) {
    Settings.save(data);
    _mac.settingsChanged();
  }

  void _saveDictation(VoidCallback change) {
    setState(change);
    _dictation.save();
    _mac.settingsChanged();
  }

  // ── вкладки ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Container(
        color: MacosTheme.of(context).canvasColor,
        child: Column(
          children: [
            _tabs(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
                children: switch (_tab) {
                  'models' => _modelsTab(),
                  'library' => _libraryTab(),
                  'general' => _generalTab(),
                  _ => _dictationTab(),
                },
              ),
            ),
          ],
        ),
      );

  /// Вкладки стоят в полосе на месте панели инструментов. Полоса высокая
  /// и вкладки в ней по центру: слева живут кнопки окна, и наезжать на них
  /// нельзя.
  Widget _tabs(BuildContext context) => Container(
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Surface.hairline(context))),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in settingsTabs)
              _TabButton(
                label: t.label,
                icon: t.icon,
                selected: _tab == t.id,
                onTap: () => setState(() => _tab = t.id),
              ),
          ],
        ),
      );

  // ── диктовка ──────────────────────────────────────────────────────────────

  List<Widget> _dictationTab() => [
        const SectionTitle('Сочетания клавиш'),
        HotkeyRow(
          label: 'Держать и говорить',
          keys: _dictation.hold.label,
          onTap: () => _reassign('hold'),
        ),
        HotkeyRow(
          label: 'Нажать · ещё раз стоп',
          keys: _dictation.toggle.label,
          onTap: () => _reassign('toggle'),
        ),
        const Hint('Нажмите на сочетание и наберите новое. Из одних '
            'модификаторов — отпустите их вместе.'),
        const SectionTitle('Распознавание диктовки'),
        const Hint('Свои значения, не общие с очередью: диктуют не то же, '
            'что расшифровывают. Язык диктовка определяет сама.'),
        const SizedBox(height: 10),
        _Field(
          'Модель',
          ModelField(
            installed: _models,
            value: _dictation.model,
            hint: 'Как у расшифровщика',
            onChosen: (v) => _saveDictation(() => _dictation.model = v),
            onDownload: _fetch,
          ),
        ),
        const SizedBox(height: 10),
        _Field(
          'Потоки',
          MacosPopupButton<int>(
            value: _dictation.threads,
            items: [
              for (var t = 2; t <= Platform.numberOfProcessors; t += 2)
                MacosPopupMenuItem(
                    value: t,
                    child: Text('$t ${plural(t, 'поток', 'потока', 'потоков')}')),
            ],
            onChanged: (v) =>
                _saveDictation(() => _dictation.threads = v ?? _dictation.threads),
          ),
        ),
        const SizedBox(height: 10),
        Check('Ставить знаки препинания', _dictation.punctuate,
            (v) => _saveDictation(() => _dictation.punctuate = v)),
        const SizedBox(height: 10),
        AppTextField(
          controller: _promptCtrl,
          placeholder: 'Имена, термины, названия',
          maxLines: 2,
          onChanged: (v) => _saveDictation(() => _dictation.prompt = v),
        ),
        const Hint('Подсказка модели: слова из неё она пишет правильнее.'),
        const SectionTitle('Модель в памяти'),
        _Field(
          'Держать модель',
          MacosPopupButton<int>(
            value: _dictation.idleSeconds,
            items: const [
              MacosPopupMenuItem(value: 30, child: Text('30 секунд')),
              MacosPopupMenuItem(value: 60, child: Text('1 минуту')),
              MacosPopupMenuItem(value: 180, child: Text('3 минуты')),
              MacosPopupMenuItem(value: 600, child: Text('10 минут')),
              MacosPopupMenuItem(value: 3600, child: Text('1 час')),
            ],
            onChanged: (v) => _saveDictation(() => _dictation.idleSeconds = v ?? 180),
          ),
        ),
        const Hint('Пока модель в памяти, фраза распознаётся за доли секунды. '
            'Она занимает полтора гигабайта.'),
        const SectionTitle('Готовый текст'),
        Check('Вставлять текст в активное окно', _dictation.insert,
            (v) => _saveDictation(() => _dictation.insert = v)),
        const Hint('Без этого готовый текст только ложится в буфер обмена.'),
        Check('Показывать панель записи', _dictation.hud,
            (v) => _saveDictation(() => _dictation.hud = v)),
        const Hint('Плавающая полоска поверх окон: видно, что вас слушают, '
            'и есть чем остановить мышью.'),
      ];

  /// Назначение сочетания: следующая нажатая комбинация становится новой.
  Future<void> _reassign(String id) async {
    final hk = await _mac.capture();
    if (hk == null) return;
    _saveDictation(() => id == 'hold' ? _dictation.hold = hk : _dictation.toggle = hk);
  }

  // ── модели ────────────────────────────────────────────────────────────────

  List<Widget> _modelsTab() {
    final d = _download;
    return [
      const SectionTitle('Установлены'),
      if (_models.isEmpty)
        const Hint('Ни одной модели не найдено. Возьмите любую из списка ниже: '
            'Tiny — просто проверить, что всё работает, Large v3 Turbo — точность.')
      else
        for (final m in _models)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(modelDisplayName(m), style: Type.fileName),
                      Text(
                        m.replaceFirst(home, '~'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.caption
                            .copyWith(color: Surface.secondaryText(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(modelSizeLabel(m),
                    style:
                        Type.caption.copyWith(color: Surface.secondaryText(context))),
              ],
            ),
          ),
      const SectionTitle('Можно загрузить'),
      if (d != null)
        ModelDownload(active: d, onCancel: () => setState(() => d.cancel()))
      else
        for (final m in modelCatalog)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${m.title} · ${m.size}', style: Type.fileName),
                      Text(m.about,
                          style: Type.caption
                              .copyWith(color: Surface.secondaryText(context))),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (m.present)
                  Text('Загружена',
                      style:
                          Type.caption.copyWith(color: Surface.secondaryText(context)))
                else
                  PushButton(
                    controlSize: ControlSize.regular,
                    secondary: true,
                    onPressed: () => _fetch(m),
                    child: const Text('Загрузить'),
                  ),
              ],
            ),
          ),
      const SizedBox(height: 16),
      PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: _pickModel,
        child: const Text('Выбрать другой файл…'),
      ),
      if (_problem != null) ...[
        const SizedBox(height: 8),
        Text(_problem!,
            style: Type.caption.copyWith(
                color: MacosColors.systemOrangeColor, height: 1.4)),
      ],
      const SizedBox(height: 20),
      Text(
        'Модели лежат в ${modelPathFor('').replaceFirst(home, '~')}',
        style: Type.caption.copyWith(color: Surface.secondaryText(context)),
      ),
    ];
  }

  /// Выбранный руками файл проверяем: «.bin» бывает чем угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры.
  Future<void> _pickModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML', extensions: ['bin'])]);
    if (f == null) return;
    final problem = modelFileProblem(f.path);
    setState(() {
      _problem = problem;
      if (problem == null && !_models.contains(f.path)) {
        _models = [..._models, f.path];
      }
    });
    if (problem == null) _saveDictation(() => _dictation.model = f.path);
  }

  Future<void> _fetch(ModelOffer m) async {
    if (_download != null) return;
    final d = Download(m.url, m.path, title: m.title);
    setState(() => _download = d);
    final path = await d.run(onProgress: () {
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    setState(() {
      _download = null;
      if (path != null) _models = findModels();
    });
    // Список моделей стал другим — соседним окнам надо его перечитать.
    if (path != null) _mac.settingsChanged();
  }

  // ── библиотека ────────────────────────────────────────────────────────────

  List<Widget> _libraryTab() => [
        const SectionTitle('Папка'),
        LibraryPath(
          path: _libraryPath,
          onReveal: () => revealInFinder(_libraryPath),
          onChange: _pickLibrary,
        ),
        const SizedBox(height: 10),
        Check('Складывать расшифровки сюда', _toLibrary, (v) {
          setState(() => _toLibrary = v);
          _saveApp({'toLibrary': v});
        }),
        if (_toLibrary) ...[
          const SectionTitle('Форматы'),
          for (final f in exportFormats)
            Check('${f.label} · ${f.suffix}', _libraryFormats.contains(f.id), (v) {
              setState(() {
                final next = [..._libraryFormats];
                v ? next.add(f.id) : next.remove(f.id);
                // Пустой набор при включённой библиотеке означал бы тишину.
                _libraryFormats = next.isEmpty ? [f.id] : next;
              });
              _saveApp({'libraryFormats': _libraryFormats});
            }),
          Hint(_libraryFormats.length > 1
              ? 'Файлы раскладываются по месяцам, и у каждой записи своя папка — '
                  'форматов больше одного.'
              : 'Файлы раскладываются по месяцам: $appName/'
                  '${monthFolder(DateTime.now())}/'),
        ],
        const SectionTitle('Рядом с исходником'),
        Check('Класть текст рядом с исходником', _saveNextToSource, (v) {
          setState(() => _saveNextToSource = v);
          _saveApp({'saveNextToSource': v});
        }),
        const Hint('Чистый текст без таймкодов, имя как у аудиофайла.'),
      ];

  Future<void> _pickLibrary() async {
    final dir = await getDirectoryPath(
      confirmButtonText: 'Выбрать',
      initialDirectory:
          Directory(_libraryPath).existsSync() ? _libraryPath : '$home/Documents',
    );
    if (dir == null) return;
    setState(() => _libraryPath = dir);
    _saveApp({'libraryPath': dir});
  }

  // ── общие ─────────────────────────────────────────────────────────────────

  List<Widget> _generalTab() => [
        const SectionTitle('Приложение'),
        Check('Показывать значок в Dock', _dockIcon, (v) {
          setState(() => _dockIcon = v);
          _saveApp({'dockIcon': v});
          _mac.setDockIcon(v);
        }),
        const Hint('Без значка tsukiko исчезает из Dock и из ⌘Tab и живёт '
            'только в строке меню. Окно и настройки открываются оттуда же.'),
        Check('Ждать, если модель занята', _yieldBusyModel, (v) {
          setState(() => _yieldBusyModel = v);
          _saveApp({'yieldBusyModel': v});
        }),
        const Hint('Пока модель держит другая программа, очередь стоит и '
            'не отбирает у неё память и GPU. Своей диктовке очередь уступает '
            'всегда: одна фраза короче одной записи.'),
        Check('Показывать метки времени', _timestamps, (v) {
          setState(() => _timestamps = v);
          _saveApp({'timestamps': v});
        }),
        const Hint('Только на экране. Что попадёт в файл, решает выбранный '
            'формат, а не эта галка.'),
        const SectionTitle('Разрешения'),
        Row(
          children: [
            Expanded(
              child: Text(
                _allowed
                    ? 'Универсальный доступ выдан.'
                    : 'Без «Универсального доступа» tsukiko не перехватывает '
                        'клавиши и не вставляет текст в активное окно.',
                style: Type.control.copyWith(height: 1.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!_allowed)
          Row(
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                onPressed: _mac.requestPermission,
                child: const Text('Запросить'),
              ),
              const SizedBox(width: 8),
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: _mac.openPermissionSettings,
                child: const Text('Открыть настройки системы'),
              ),
            ],
          )
        else
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: _mac.openPermissionSettings,
            child: const Text('Открыть настройки системы'),
          ),
      ];
}

/// Подпись над полем, а не слева от него: выпадающий список в macOS
/// шириной со своё самое длинное имя, и в узкой колонке он вылезал
/// за край окна.
class _Field extends StatelessWidget {
  const _Field(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Type.caption.copyWith(color: Surface.secondaryText(context))),
            const SizedBox(height: 5),
            child,
          ],
        ),
      );
}

/// Вкладка в полосе: значок над подписью — как в панели инструментов
/// системных приложений.
class _TabButton extends StatefulWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final color = widget.selected ? accent : Surface.secondaryText(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          curve: Curves.easeOut,
          width: 84,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? Surface.pressed(context)
                : _hover
                    ? Surface.hover(context)
                    : MacosColors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MacosIcon(widget.icon, size: 18, color: color),
              const SizedBox(height: 3),
              Text(
                widget.label,
                maxLines: 1,
                style: Type.caption.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
