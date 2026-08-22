import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/text.dart';
import '../../core/transcript.dart';
import '../../design/design.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'settings_cubit.dart';
import 'widgets/model_row.dart';
import 'settings_state.dart';

/// Окно настроек: своё окно с вкладками, как у всех приложений macOS.
///
/// Живёт на третьем движке Flutter — том, что создаётся при первом ⌘,.
/// Иначе никак: движок отдаёт один вид одному окну, а главное окно и
/// панель у строки меню свои виды уже заняли. Настройки — не главное
/// окно расшифровщика: диктовка настраивается и тогда, когда очереди
/// нет вовсе, а без значка в Dock главного окна может не быть на экране.
///
/// Состоянием владеет [SettingsCubit]; здесь только то, что рисуется.
void runSettings() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SettingsApp());
}

const settingsTabs = [
  (id: 'dictation', label: 'Диктовка', icon: CupertinoIcons.mic),
  (id: 'models', label: 'Модели', icon: CupertinoIcons.cube_box),
  (id: 'library', label: 'Файлы', icon: CupertinoIcons.folder),
  (id: 'general', label: 'Общие', icon: CupertinoIcons.gear),
];

class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
        create: (_) => SettingsCubit(NativeBridge()),
        child: MacosApp(
          title: 'Настройки',
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: ThemeMode.system,
          debugShowCheckedModeBanner: false,
          home: const SettingsBody(),
        ),
      );
}

class SettingsBody extends StatefulWidget {
  const SettingsBody({super.key});

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody> with WidgetsBindingObserver {
  /// Единственное, что остаётся окну: поле ввода подсказки.
  final _promptCtrl = TextEditingController();
  String _promptShown = '';

  SettingsCubit get _cubit => context.read<SettingsCubit>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Первый вопрос о разрешении задаём сразу: окно только что открыли.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisibility());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisibility();

  void _syncVisibility() => _cubit.setVisible(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptCtrl.dispose();
    super.dispose();
  }

  /// Поле подсказки следует за настройкой, но не мешает набору.
  void _syncPromptField(String text) {
    if (text == _promptShown) return;
    _promptShown = text;
    if (_promptCtrl.text == text) return;
    _promptCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _pickModel() async {
    final f = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'GGML', extensions: ['bin'])]);
    if (f != null) _cubit.pickModel(f.path);
  }

  Future<void> _pickLibrary(SettingsState s) async {
    final dir = await getDirectoryPath(
      confirmButtonText: 'Выбрать',
      initialDirectory:
          Directory(s.libraryPath).existsSync() ? s.libraryPath : os.documentsDir,
    );
    if (dir != null) _cubit.setLibraryPath(dir);
  }

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<SettingsCubit, SettingsState>(
        listenWhen: (was, now) => was.prompt != now.prompt,
        listener: (context, s) => _syncPromptField(s.prompt),
        builder: (context, s) => Container(
          color: MacosTheme.of(context).canvasColor,
          child: Column(
            children: [
              _tabs(context, s),
              Expanded(
                child: ListView(
                  // Поля слева и справа одинаковые и одни на все вкладки.
                  padding: const EdgeInsets.fromLTRB(
                      Gap.edge, Gap.inner, Gap.edge, Gap.section),
                  children: switch (s.tab) {
                    'models' => _modelsTab(s),
                    'library' => _libraryTab(s),
                    'general' => _generalTab(s),
                    _ => _dictationTab(s),
                  },
                ),
              ),
            ],
          ),
        ),
      );

  // ── вкладки ───────────────────────────────────────────────────────────────

  /// Вкладки стоят в полосе на месте панели инструментов. Полоса высокая
  /// и вкладки в ней по центру: слева живут кнопки окна, и наезжать на них
  /// нельзя.
  Widget _tabs(BuildContext context, SettingsState s) => Container(
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
                selected: s.tab == t.id,
                onTap: () => _cubit.setTab(t.id),
              ),
          ],
        ),
      );

  // ── диктовка ──────────────────────────────────────────────────────────────

  List<Widget> _dictationTab(SettingsState s) => [
        const SectionTitle('Сочетания клавиш'),
        HotkeyRow(
          label: 'Держать и говорить',
          keys: s.hold.label,
          onTap: () => _cubit.reassign('hold'),
        ),
        HotkeyRow(
          label: 'Нажать, ещё раз — остановить',
          keys: s.toggle.label,
          onTap: () => _cubit.reassign('toggle'),
        ),
        const Hint('Нажмите на сочетание и наберите новое. Из одних '
            'модификаторов — отпустите их вместе.'),
        const SectionTitle('Распознавание диктовки'),
        const Hint('Свои значения, не общие с очередью: диктуют не то же, '
            'что расшифровывают. Язык диктовка определяет сама.'),
        const SizedBox(height: Gap.item),
        _Field(
          'Модель',
          ModelField(
            installed: s.usable,
            value: s.dictationModel,
            fallback: 'Как у расшифровщика',
            onChosen: (v) => _cubit.setDictationModel(v),
            onDownload: _cubit.download,
          ),
        ),
        const Hint('«Как у расшифровщика» — брать ту же модель, что выбрана '
            'в главном окне: меняете её там, меняется и здесь.'),
        const SizedBox(height: Gap.item),
        _Field(
          'Потоки',
          MacosPopupButton<int>(
            value: s.threads,
            items: [
              for (var t = 2; t <= Platform.numberOfProcessors; t += 2)
                MacosPopupMenuItem(
                    value: t,
                    child: Text('$t ${plural(t, 'поток', 'потока', 'потоков')}')),
            ],
            onChanged: (v) =>
                _cubit.setThreads(v ?? s.threads),
          ),
        ),
        const SizedBox(height: Gap.item),
        Check('Ставить знаки препинания', s.punctuate,
            _cubit.setPunctuate),
        const SizedBox(height: Gap.item),
        // Подпись стоит над полем, а не под ним: под полем она читалась
        // как пояснение ко всему разделу.
        _Field(
          'Подсказка модели',
          AppTextField(
            controller: _promptCtrl,
            placeholder: 'Имена, термины, названия',
            maxLines: 2,
            onChanged: (v) => _cubit.setPrompt(v),
          ),
        ),
        const Hint('Слова из подсказки модель пишет правильнее.'),
        const SectionTitle('Модель в памяти'),
        _Field(
          'Держать модель',
          MacosPopupButton<int>(
            value: s.idleSeconds,
            items: const [
              MacosPopupMenuItem(value: 30, child: Text('30 секунд')),
              MacosPopupMenuItem(value: 60, child: Text('1 минуту')),
              MacosPopupMenuItem(value: 180, child: Text('3 минуты')),
              MacosPopupMenuItem(value: 600, child: Text('10 минут')),
              MacosPopupMenuItem(value: 3600, child: Text('1 час')),
            ],
            onChanged: (v) => _cubit.setIdleSeconds(v ?? 180),
          ),
        ),
        const Hint('Пока модель в памяти, фраза распознаётся за доли секунды. '
            'Она занимает полтора гигабайта.'),
        const SectionTitle('Готовый текст'),
        Check('Вставлять текст в активное окно', s.insert,
            _cubit.setInsert),
        const Hint('Без этого готовый текст только ложится в буфер обмена.',
            under: true),
        const SizedBox(height: Gap.item),
        Check('Показывать панель записи', s.hud,
            _cubit.setHud),
        const Hint('Плавающая полоска поверх окон: видно, что вас слушают, '
            'и есть чем остановить мышью.', under: true),
      ];

  // ── модели ────────────────────────────────────────────────────────────────

  List<Widget> _modelsTab(SettingsState s) {
    // Предлагать к загрузке то, что уже лежит на диске, — обещать человеку
    // полтора гигабайта работы впустую. Есть всё — раздела нет вовсе.
    final offers = modelOffers(s.usable);
    return [
      const SectionTitle('Установлены'),
      if (s.models.isEmpty)
        const Hint('Ни одной модели не найдено. Возьмите любую из списка ниже: '
            'Tiny — просто проверить, что всё работает, Large v3 Turbo — точность.')
      else
        for (final m in s.models)
          ModelRow(
            name: modelLabel(m.path, [for (final x in s.models) x.path]),
            path: m.path.replaceFirst(home, '~'),
            size: m.sizeLabel,
            problem: m.problem,
            chosen: m.path == s.dictationModel,
            onReveal: () => _cubit.reveal(m.path),
            onDelete: () => _confirmDelete(s, m),
          ),
      if (s.downloading) ...[
        const SectionTitle('Можно загрузить'),
        ModelDownload(
          title: s.downloadTitle ?? 'модель',
          progress: s.downloadProgress!,
          percent: s.downloadPercent,
          onCancel: _cubit.cancelDownload,
        ),
      ] else if (offers.isNotEmpty) ...[
        const SectionTitle('Можно загрузить'),
        for (final m in offers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
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
                const SizedBox(width: Gap.item),
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: () => _cubit.download(m),
                  child: const Text('Загрузить'),
                ),
              ],
            ),
          ),
      ],
      const SizedBox(height: Gap.section),
      PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: _pickModel,
        child: const Text('Выбрать другой файл…'),
      ),
      if (s.problem != null) ...[
        const SizedBox(height: Gap.inner),
        Text(s.problem!,
            style: Type.caption.copyWith(
                color: MacosColors.systemOrangeColor, height: 1.4)),
      ],
      const SizedBox(height: Gap.section),
      Row(
        children: [
          Expanded(
            child: Text(
              'Модели лежат в ${os.modelsDir.replaceFirst(home, '~')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
          ),
          const SizedBox(width: Gap.inner),
          PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: _cubit.revealModelsFolder,
            child: Text('Показать в ${os.fileManagerName}'),
          ),
        ],
      ),
    ];
  }

  /// Удаление спрашивают, а не делают молча: полтора гигабайта, стёртые
  /// по промаху, качать заново. Файл при этом уходит в Корзину, поэтому
  /// вопрос один и без запугивания.
  Future<void> _confirmDelete(SettingsState s, InstalledModel m) async {
    final chosen = m.path == s.dictationModel;
    final where = m.ours
        ? 'Файл уйдёт в Корзину.'
        : 'Файл лежит не в папке $appName, а в общем каталоге — им могут '
            'пользоваться другие программы. Он уйдёт в Корзину.';
    var yes = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.trash, size: 56),
        title: Text('Убрать ${m.name}?', style: Type.emptyTitle),
        message: Text(
          [
            where,
            if (chosen) 'Сейчас эта модель выбрана для диктовки.',
            if (m.sizeLabel.isNotEmpty) 'Освободится ${m.sizeLabel}.',
          ].join('\n'),
          textAlign: TextAlign.center,
          style: Type.control,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            yes = true;
            Navigator.pop(dialogContext);
          },
          child: const Text('Убрать'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
      ),
    );
    if (yes) await _cubit.deleteModel(m.path);
  }

  // ── библиотека ────────────────────────────────────────────────────────────

  /// Вкладка отвечает на один вопрос: что происходит с текстом, когда
  /// запись распознана. Поэтому каждая галка говорит и что делает, и что
  /// будет, если её выключить, — иначе выключать её страшно.
  List<Widget> _libraryTab(SettingsState s) => [
        const SectionTitle('Сохранять расшифровки автоматически'),
        Check('Сохранять готовый текст на диск', s.toLibrary,
            _cubit.setToLibrary),
        const Hint('Как только запись распознана, текст сам ложится файлом '
            'в папку ниже. Выключено — текст остаётся только в окне tsukiko, '
            'и сохранять его придётся вручную: «Сохранить как…» или ⌘C.',
            under: true),
        const SectionTitle('Куда сохранять'),
        LibraryPath(
          path: s.libraryPath,
          onReveal: () => _cubit.reveal(s.libraryPath),
          onChange: () => _pickLibrary(s),
          hint: 'Внутри папка на каждый месяц: $appName/'
              '${monthFolder(DateTime.now())}/. Щёлкните по пути, чтобы '
              'открыть папку в ${os.fileManagerName}.',
        ),
        if (s.toLibrary) ...[
          const SectionTitle('В каком виде сохранять'),
          for (final f in exportFormats)
            // suffix у «текста с таймкодами» начинается с пробела: он
            // дописывается к имени файла. В подписи этот пробел — дыра.
            Check('${f.label} · ${f.suffix.trim()}',
                s.libraryFormats.contains(f.id),
                (v) => _cubit.toggleFormat(f.id, v)),
          Hint(
              s.libraryFormats.length > 1
                  ? 'На каждую запись сохраняется столько файлов, сколько '
                      'форматов отмечено, и у записи появляется своя папка. '
                      'Совсем без форматов сохранять было бы нечего, поэтому '
                      'последний снять нельзя.'
                  : 'Один отмеченный формат — один файл на запись. Отметьте '
                      'больше, и рядом лягут те же слова в другом виде.',
              under: true),
        ],
        const SectionTitle('Копия рядом с аудиофайлом'),
        Check('Класть текст рядом с исходной записью', s.saveNextToSource,
            _cubit.setSaveNextToSource),
        const Hint('Кроме папки выше: в ту же папку, где лежит сама запись, '
            'ляжет .txt с её именем — чистый текст без таймкодов. '
            'Выключено — рядом с записью ничего не появляется.',
            under: true),
      ];

  // ── общие ─────────────────────────────────────────────────────────────────

  List<Widget> _generalTab(SettingsState s) => [
        const SectionTitle('Приложение'),
        Check('Запускать при входе в систему', s.loginItem,
            _cubit.setLoginItem),
        const Hint('Диктовка поднимется сама и будет ждать в строке меню. '
            'Окно расшифровщика при этом не открывается — оно всегда '
            'доступно по значку в Dock.',
            under: true),
        const SizedBox(height: Gap.item),
        Check('Показывать значок в Dock', s.dockIcon, _cubit.setDockIcon),
        const Hint('Без значка tsukiko исчезает из Dock и из ⌘Tab и живёт '
            'только в строке меню. Окно и настройки открываются оттуда же.',
            under: true),
        const SizedBox(height: Gap.item),
        Check('Ждать, если модель занята', s.yieldBusyModel,
            _cubit.setYieldBusyModel),
        const Hint('Пока модель держит другая программа, очередь стоит и '
            'не отбирает у неё память и GPU. Своей диктовке очередь уступает '
            'всегда: одна фраза короче одной записи.', under: true),
        const SizedBox(height: Gap.item),
        Check('Показывать метки времени', s.timestamps, _cubit.setTimestamps),
        const Hint('Только на экране. Что попадёт в файл, решает выбранный '
            'формат, а не эта галка.', under: true),
        const SectionTitle('Разрешения'),
        Row(
          children: [
            Expanded(
              child: Text(
                s.allowed
                    ? 'Универсальный доступ выдан.'
                    : 'Без «Универсального доступа» tsukiko не перехватывает '
                        'клавиши и не вставляет текст в активное окно.',
                style: Type.control.copyWith(height: 1.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.item),
        if (!s.allowed)
          Row(
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                onPressed: _cubit.requestPermission,
                child: const Text('Запросить'),
              ),
              const SizedBox(width: 8),
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: _cubit.openPermissionSettings,
                child: const Text('Открыть настройки системы'),
              ),
            ],
          )
        else
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: _cubit.openPermissionSettings,
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
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Type.caption.copyWith(color: Surface.secondaryText(context))),
          // Подпись прижата к своему полю, а расстояние до следующей
          // настройки задаётся снаружи и всегда больше.
          const SizedBox(height: Gap.hint),
          child,
        ],
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
