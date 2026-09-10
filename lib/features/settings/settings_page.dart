import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/app_locale.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/recognition.dart';
import '../../core/skill_install.dart';
import '../../core/text_commands.dart';
import '../../core/transcript.dart';
import '../../core/whisper_server.dart' show Hotkey;
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'settings_cubit.dart';
import 'widgets/model_row.dart';
import 'settings_state.dart';
import '../../core/labels.dart';

/// Окно настроек: своё окно с вкладками, как у всех приложений системы.
///
/// Живёт на третьем движке Flutter — том, что создаётся при первом
/// открытии окна. Иначе никак: движок отдаёт один вид одному окну,
/// а главное окно и панель у строки меню свои виды уже заняли. Настройки —
/// не главное окно расшифровщика: диктовка настраивается и тогда, когда
/// очереди нет вовсе, а без значка приложения главного окна может не быть
/// на экране.
///
/// Состоянием владеет [SettingsCubit]; здесь только то, что рисуется.
void runSettings() {
  refreshLocale();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SettingsApp());
}

/// Вкладки названы по потребителю, а не по виду настройки.
///
/// Раньше их было «Диктовка», «Модели», «Файлы», «Общие» — и на вопрос
/// «чьи это модели и чьи файлы» вкладка не отвечала: у приложения два
/// независимых потребителя моделей, расшифровщик и диктовка, и почти
/// у каждой настройки есть ровно один хозяин. Теперь первые две вкладки —
/// это и есть хозяева, «Модели» — общий склад файлов на двоих, а
/// «Приложение» — то, что не принадлежит ни одному из них.
List<({String id, String label, IconData icon})> _settingsTabs(
  AppLocalizations l10n,
) => [
  (
    id: 'transcriber',
    label: l10n.settingsTabTranscription,
    icon: CupertinoIcons.doc_text,
  ),
  (id: 'dictation', label: l10n.settingsTabDictation, icon: CupertinoIcons.mic),
  (id: 'models', label: l10n.settingsTabModels, icon: CupertinoIcons.cube_box),
  (id: 'app', label: l10n.settingsTabApp, icon: CupertinoIcons.gear),
];

class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SettingsCubit(NativeBridge()),
    child: ValueListenableBuilder<Locale?>(
      valueListenable: appLocale,
      builder: (context, locale, _) => MacosApp(
        locale: locale,
        // Локализованный заголовок окна недоступен здесь: builder ниже
        // ещё не построен, а MacosApp.title читается до первого кадра.
        // Заголовок панели инструментов настоящий, локализованный —
        // системная рамка окна этот берёт только для VoiceOver и Dock.
        title: currentL10n().settingsWindowTitle,
        theme: MacosThemeData.light(),
        darkTheme: MacosThemeData.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsBody(),
      ),
    ),
  );
}

class SettingsBody extends StatefulWidget {
  const SettingsBody({super.key});

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody>
    with WidgetsBindingObserver {
  /// Единственное, что остаётся окну: поле ввода подсказки.
  final _promptCtrl = TextEditingController();
  final _modelsScroll = ScrollController();
  String _promptShown = '';

  /// Ключ API только что скопировали. Живёт до следующей перерисовки
  /// настроек и в кубите ему делать нечего: это не настройка, а ответ
  /// на нажатие кнопки.
  bool _keyCopied = false;

  SettingsCubit get _cubit => context.read<SettingsCubit>();
  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Первое состояние приходит мимо listener'а: BlocConsumer зовёт его
    // только на переменах. Без этой строки поле подсказки в только что
    // открытом окне стояло пустым, хотя подсказка была на месте.
    _syncPromptField(_cubit.state.prompt);
    // Первый вопрос о разрешении задаём сразу: окно только что открыли.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisibility());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisibility();

  void _syncVisibility() => _cubit.setVisible(
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptCtrl.dispose();
    _modelsScroll.dispose();
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

  /// Каталог моделей длиннее окна, а ход загрузки стоит над ним. После
  /// нажатия «Скачать» возле нижней модели кнопки блокировались на месте,
  /// и начавшаяся выше загрузка оставалась за краем экрана. Дожидаемся,
  /// пока список переложится, и мягко возвращаем его к верхнему блоку,
  /// где индикатор уже виден. Искать сам виджет по ключу нельзя: ленивый
  /// список не строит его, пока пользователь далеко внизу. [Motion]
  /// учитывает системное «уменьшение движения».
  void _revealModelDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_modelsScroll.hasClients) return;
      _modelsScroll.animateTo(
        _modelsScroll.position.minScrollExtent,
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
      );
    });
  }

  Future<void> _pickModel() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'GGML / GGUF', extensions: ['bin', 'gguf']),
      ],
    );
    if (f != null) _cubit.pickModel(f.path);
  }

  Future<void> _pickLibrary(SettingsState s) async {
    final dir = await getDirectoryPath(
      confirmButtonText: l10n.buttonChoose,
      initialDirectory: Directory(s.libraryPath).existsSync()
          ? s.libraryPath
          : os.documentsDir,
    );
    if (dir != null) _cubit.setLibraryPath(dir);
  }

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<SettingsCubit, SettingsState>(
        listenWhen: (was, now) =>
            was.prompt != now.prompt || (!was.downloading && now.downloading),
        listener: (context, s) {
          _syncPromptField(s.prompt);
          if (s.downloading) _revealModelDownload();
        },
        builder: (context, s) => Container(
          color: MacosTheme.of(context).canvasColor,
          child: Column(
            children: [
              _tabs(context, s),
              Expanded(
                child: ListView(
                  controller: s.tab == 'models' ? _modelsScroll : null,
                  // У каждой вкладки своё место прокрутки. Без ключа Flutter
                  // переносил позицию из длинного каталога моделей в другую
                  // вкладку, и она открывалась посередине или в пустоте.
                  key: ValueKey(s.tab),
                  // Поля слева и справа одинаковые и одни на все вкладки.
                  padding: const EdgeInsets.fromLTRB(
                    Gap.edge,
                    Gap.inner,
                    Gap.edge,
                    Gap.section,
                  ),
                  children: [
                    // Жалоба стоит над вкладкой, а не внутри неё: назначить
                    // занятое сочетание можно на «Диктовке», выбрать не тот
                    // файл — там же, а показывалось это всё на «Моделях»,
                    // то есть не показывалось никому.
                    if (s.problem != null) _problem(s.problem!),
                    ...switch (s.tab) {
                      'dictation' => _dictationTab(s),
                      'models' => _modelsTab(s),
                      'app' => _appTab(s),
                      _ => _transcriberTab(s),
                    },
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// Что пошло не так с последним действием: занятое сочетание, чужой
  /// файл вместо модели, отказ Корзины.
  Widget _problem(String text) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.inner),
    child: Text(
      text,
      style: Type.caption.copyWith(
        color: MacosColors.systemOrangeColor,
        height: 1.4,
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
        for (final t in _settingsTabs(l10n))
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
    SectionTitle(l10n.sectionHotkeys),
    HotkeyRow(
      label: l10n.hotkeyHold,
      keys: s.hold.label,
      onTap: () => _reassignHotkey('hold'),
    ),
    HotkeyRow(
      label: l10n.hotkeyToggle,
      keys: s.toggle.label,
      onTap: () => _reassignHotkey('toggle'),
    ),
    // Третье действие — и единственное, которое можно не назначать
    // вовсе. «Остановить» и «передумал» это разные намерения, а у
    // клавиш второго не было: бросить начатое можно было только мышью,
    // по крестику на плавающей панели, которую человек мог и выключить.
    HotkeyRow(
      label: l10n.hotkeyCancel,
      keys: s.cancel.label,
      onTap: () => _reassignHotkey('cancel'),
      // Снимать нечего — и крестика нет: пустая строка не должна
      // выбиваться из столбика ради кнопки, которой не на что нажать.
      onClear: s.cancel.empty ? null : _cubit.clearCancelHotkey,
    ),
    // Пара, где одно сочетание входит в другое, ведёт себя непонятно,
    // а не ломается: запись начинается по дороге ко второму. Молчать
    // об этом нельзя — человеку неоткуда догадаться.
    if (s.shadowingHotkey case final early?)
      _problem(
        l10n.hotkeyShadowProblem(
          early.label,
          (s.shadowedHotkey ?? early).label,
        ),
      ),
    Hint(l10n.hintHotkeyCancel),
    Hint(l10n.hintHotkeyCapture),
    SectionTitle(l10n.sectionDictationRecognition),
    Hint(l10n.hintDictationOwnSettings),
    const SizedBox(height: Gap.item),
    _Field(
      l10n.fieldDictationModel,
      ModelField(
        installed: s.usable,
        value: s.dictationModel,
        fallback: l10n.fallbackSameAsTranscription,
        onChosen: (v) => _cubit.setDictationModel(v),
        onDownload: _cubit.downloadForDictation,
        downloadEnabled: !s.downloading,
      ),
    ),
    Hint(l10n.hintDictationModelFallback),
    const SizedBox(height: Gap.inner),
    // Кнопка стоит здесь, а не на вкладке «Модели»: она не пополняет
    // список, а выбирает модель диктовки — раньше из общего склада
    // это делалось молча, и понять, кому достался файл, было нельзя.
    PushButton(
      controlSize: ControlSize.regular,
      secondary: true,
      onPressed: _pickModel,
      child: Text(l10n.buttonPickModelFile),
    ),
    const SizedBox(height: Gap.item),
    _Field(
      l10n.fieldSpeed,
      MacosPopupButton<int>(
        value: s.threads,
        items: [
          for (final t in threadChoices(s.threads))
            MacosPopupMenuItem(value: t, child: Text(l10n.threadsCount(t))),
        ],
        onChanged: (v) => _cubit.setThreads(v ?? s.threads),
      ),
    ),
    Hint(l10n.hintThreads),
    const SizedBox(height: Gap.item),
    Check(l10n.checkPunctuate, s.punctuate, _cubit.setPunctuate),
    const SizedBox(height: Gap.item),
    // Подпись стоит над полем, а не под ним: под полем она читалась
    // как пояснение ко всему разделу.
    _Field(
      l10n.fieldModelPrompt,
      AppTextField(
        controller: _promptCtrl,
        placeholder: l10n.placeholderPromptExample,
        minLines: 3,
        maxLines: null,
        onChanged: (v) => _cubit.setPrompt(v),
      ),
    ),
    Hint(l10n.hintPromptHelps),
    ..._textCommands(
      s,
      enabled: s.dictationCommandsEnabled,
      onEnabled: _cubit.setDictationCommandsEnabled,
    ),
    SectionTitle(l10n.sectionModelInMemory),
    _Field(
      l10n.fieldKeepModel,
      MacosPopupButton<int>(
        value: s.idleSeconds,
        items: [
          MacosPopupMenuItem(value: 30, child: Text(l10n.duration30s)),
          MacosPopupMenuItem(value: 60, child: Text(l10n.duration1m)),
          MacosPopupMenuItem(value: 180, child: Text(l10n.duration3m)),
          MacosPopupMenuItem(value: 600, child: Text(l10n.duration10m)),
          MacosPopupMenuItem(value: 3600, child: Text(l10n.duration1h)),
        ],
        onChanged: (v) => _cubit.setIdleSeconds(v ?? 180),
      ),
    ),
    // Размер берём у той модели, которая выбрана, а не пишем числом
    // в тексте: раньше здесь стояло «полтора гигабайта» — верно ровно
    // для Large v3 Turbo и неправда для всех остальных.
    Hint('${l10n.hintMemoryCostPrefix} ${_memoryCost(s)}'),
    SectionTitle(l10n.sectionAfterDictation),
    Check(l10n.checkInsertText, s.insert, _cubit.setInsert),
    Hint(l10n.hintInsertOff, under: true),
    const SizedBox(height: Gap.item),
    Check(l10n.checkShowHud, s.hud, _cubit.setHud),
    Hint(l10n.hintHud, under: true),
  ];

  Future<void> _reassignHotkey(String id) =>
      _cubit.reassign(id, confirmExclusive: _confirmExclusiveHotkey);

  Future<bool> _confirmExclusiveHotkey(Hotkey hotkey) async {
    if (!mounted) return false;
    var accepted = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.keyboard, size: IconSize.hero),
        title: Text(
          l10n.singleHotkeyTitle(hotkey.label),
          style: Type.emptyTitle,
        ),
        message: Text(
          l10n.singleHotkeyBody,
          textAlign: TextAlign.center,
          style: Type.control,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            accepted = true;
            Navigator.pop(dialogContext);
          },
          child: Text(l10n.buttonAssign),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonCancel),
        ),
      ),
    );
    return accepted;
  }

  // ── модели ────────────────────────────────────────────────────────────────

  List<Widget> _modelsTab(SettingsState s) {
    return [
      SectionTitle(l10n.sectionActiveModels),
      Hint(l10n.hintModelsOwnership),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldTranscriptionModel,
        ModelField(
          installed: s.usable,
          value: s.transcriberModelSelection,
          fallback: l10n.fallbackSameAsDictation,
          onChosen: _cubit.setQueueModel,
          onDownload: _cubit.downloadForTranscription,
          downloadEnabled: !s.downloading,
        ),
      ),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldDictationModel,
        ModelField(
          installed: s.usable,
          value: s.dictationModel,
          fallback: l10n.fallbackSameAsTranscription,
          onChosen: _cubit.setDictationModel,
          onDownload: _cubit.downloadForDictation,
          downloadEnabled: !s.downloading,
        ),
      ),
      SectionTitle(l10n.sectionModelCatalog),
      Hint(l10n.hintModelCatalog),
      if (s.downloading) ...[
        const SizedBox(height: Gap.item),
        ModelDownload(
          title: s.downloadTitle ?? l10n.genericModelTitle,
          progress: s.downloadProgress!,
          percent: s.downloadPercent,
          onCancel: _cubit.cancelDownload,
        ),
      ],
      for (final engine in RecognitionEngine.values) ...[
        _modelEngineHeading(engine),
        for (final m in modelCatalog.where((m) => m.engine == engine))
          _modelOfferRow(m, installed: haveModel(s.usable, m)),
      ],
      SectionTitle(l10n.sectionInstalled),
      if (s.models.isEmpty)
        Hint(l10n.hintNoModels)
      else
        for (final m in s.models)
          ModelRow(
            name: modelLabel(m.path, [for (final x in s.models) x.path]),
            path: m.path.replaceFirst(home, '~'),
            size: m.sizeLabel,
            problem: m.problem,
            usedBy: s.userOf(m.path),
            onReveal: () => _cubit.revealModel(m.path),
            onDelete: () => _confirmDelete(s, m),
          ),
      // Модель тишины лежит в той же папке, и не сказать о ней — значит
      // оставить человека с файлом, которого нет ни в одном списке.
      if (s.vad != null) ...[
        SectionTitle(l10n.sectionAuxiliary),
        ModelRow(
          name: l10n.vadModelName,
          path: s.vad!.path.replaceFirst(home, '~'),
          size: s.vad!.sizeLabel,
          problem: s.vad!.problem,
          usedBy: null,
          onReveal: () => _cubit.revealModel(s.vad!.path),
          onDelete: () => _confirmDelete(s, s.vad!),
        ),
        Hint(l10n.hintVad),
      ],
      const SizedBox(height: Gap.section),
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.modelsFolderLabel(os.modelsDir.replaceFirst(home, '~')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
          const SizedBox(width: Gap.inner),
          PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: _cubit.revealModelsFolder,
            child: Text(l10n.buttonShowInFileManager(os.fileManagerName)),
          ),
        ],
      ),
    ];
  }

  /// Каталог делится по исполняющему движку: размер модели не объясняет,
  /// почему один файл `.bin`, другой `.gguf` и какие функции у них разные.
  Widget _modelEngineHeading(RecognitionEngine engine) => Padding(
    padding: const EdgeInsets.only(top: Gap.item, bottom: Gap.hint),
    child: Text(
      engineTechnicalName(engine).toUpperCase(),
      style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
    ),
  );

  Widget _modelOfferRow(ModelOffer model, {required bool installed}) {
    final muted = Surface.secondaryText(context);
    final capabilities = <({String label, bool warning})>[
      (
        label: switch (model.languages) {
          ModelLanguageScope.multilingual => l10n.modelCapabilityMultilingual,
          ModelLanguageScope.fortyPlus => l10n.modelCapabilityLanguages40Plus,
          ModelLanguageScope.european25 => l10n.modelCapabilityEuropean25,
        },
        warning: false,
      ),
      (
        label: switch (model.focus) {
          ModelFocus.compact => l10n.modelCapabilityCompact,
          ModelFocus.balanced => l10n.modelCapabilityBalanced,
          ModelFocus.fast => l10n.modelCapabilityFast,
          ModelFocus.accurate => l10n.modelCapabilityAccurate,
          ModelFocus.live => l10n.modelCapabilityLive,
        },
        warning: false,
      ),
      (
        label: model.supportsPrompt
            ? l10n.modelCapabilityPrompt
            : l10n.modelCapabilityNoPrompt,
        warning: !model.supportsPrompt,
      ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Gap.control),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Surface.hairline(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${model.title} · ${model.size}', style: Type.fileName),
                const SizedBox(height: Gap.hint),
                Text(
                  model.about,
                  style: Type.caption.copyWith(color: muted, height: 1.35),
                ),
                const SizedBox(height: Gap.inner),
                Wrap(
                  spacing: Gap.hint,
                  runSpacing: Gap.hint,
                  children: [
                    for (final capability in capabilities)
                      _modelCapability(
                        capability.label,
                        warning: capability.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.item),
          if (installed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.hint),
              child: Row(
                children: [
                  const MacosIcon(
                    CupertinoIcons.check_mark_circled_solid,
                    size: IconSize.inline,
                    color: MacosColors.systemGreenColor,
                  ),
                  const SizedBox(width: Gap.hint),
                  Text(l10n.modelAlreadyInstalled, style: Type.caption),
                ],
              ),
            )
          else
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _cubit.state.downloading
                  ? null
                  : () => _cubit.download(model),
              child: Text(l10n.buttonDownload),
            ),
        ],
      ),
    );
  }

  Widget _modelCapability(String label, {required bool warning}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: warning
          ? MacosColors.systemOrangeColor.withValues(alpha: 0.11)
          : Surface.hover(context),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: Type.caption.copyWith(
        fontSize: 10.5,
        color: warning
            ? MacosColors.systemOrangeColor
            : Surface.secondaryText(context),
      ),
    ),
  );

  /// Сколько памяти держит модель, которой работает диктовка. Пока она
  /// не выбрана или файла нет, числа не выдумываем.
  String _memoryCost(SettingsState s) {
    // Именно «в деле», а не «выбрана»: при пустом выборе диктовка держит
    // в памяти модель расшифровщика, и её размер здесь и надо назвать.
    final chosen = s.dictationModelInUse;
    if (chosen.isEmpty) {
      return l10n.memoryCostUnknown;
    }
    final size = s.models
        .where((m) => m.path == chosen)
        .map((m) => m.sizeLabel)
        .firstWhere((label) => label.isNotEmpty, orElse: () => '');
    return size.isEmpty ? l10n.memoryCostGeneric : l10n.memoryCostSized(size);
  }

  /// Удаление спрашивают, а не делают молча: полтора гигабайта, стёртые
  /// по промаху, качать заново. Файл при этом уходит в Корзину, поэтому
  /// вопрос один и без запугивания.
  Future<void> _confirmDelete(SettingsState s, InstalledModel m) async {
    final usedBy = s.userOf(m.path);
    final where = m.ours
        ? l10n.deleteModelToTrash
        : l10n.deleteModelSharedFolder(appName);
    var yes = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.trash, size: IconSize.hero),
        title: Text(l10n.deleteModelTitle(m.name), style: Type.emptyTitle),
        message: Text(
          [
            where,
            if (usedBy != null) l10n.deleteModelUsedBy(usedBy),
            if (m.sizeLabel.isNotEmpty) l10n.deleteModelFrees(m.sizeLabel),
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
          child: Text(l10n.buttonRemove),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonCancel),
        ),
      ),
    );
    if (yes) await _cubit.deleteModel(m.path);
  }

  // ── расшифровщик ──────────────────────────────────────────────────────────

  /// Вкладка отвечает на один вопрос: что расшифровщик делает с текстом,
  /// когда запись распознана. Поэтому каждая галка говорит и что делает,
  /// и что будет, если её выключить, — иначе выключать её страшно.
  ///
  /// Как именно распознавать, здесь не спрашивают: модель, язык, пунктуация,
  /// разбивка, скорость и подсказка меняются от записи к записи, и место
  /// им в инспекторе главного окна, рядом с самой очередью. Первый же
  /// раздел говорит об этом прямо — раньше человек искал их тут и не
  /// находил.
  List<Widget> _transcriberTab(SettingsState s) => [
    SectionTitle(l10n.sectionHowToRecognize),
    Hint(l10n.hintPerRecordingSettings),
    ..._textCommands(
      s,
      enabled: s.transcriberCommandsEnabled,
      onEnabled: _cubit.setTranscriberCommandsEnabled,
    ),
    SectionTitle(l10n.sectionAutoSave),
    Check(l10n.checkSaveToDisk, s.toLibrary, _cubit.setToLibrary),
    Hint(l10n.hintSaveToDisk(appName), under: true),
    SectionTitle(l10n.sectionWhereToSave),
    LibraryPath(
      path: s.libraryPath,
      onReveal: () => _cubit.revealLibrary(s.libraryPath),
      onChange: () => _pickLibrary(s),
      hint: l10n.libraryHint(
        appName,
        monthFolder(DateTime.now()),
        os.fileManagerName,
      ),
    ),
    if (s.toLibrary) ...[
      SectionTitle(l10n.sectionAutoSaveFormats),
      for (final f in exportFormats)
        // suffix у «текста с таймкодами» начинается с пробела: он
        // дописывается к имени файла. В подписи этот пробел — дыра.
        Check(
          '${f.label} · ${f.suffix.trim()}',
          s.libraryFormats.contains(f.id),
          (v) => _cubit.toggleFormat(f.id, v),
        ),
      Hint(
        s.libraryFormats.length > 1
            ? l10n.hintFormatsMulti
            : l10n.hintFormatsSingle,
        under: true,
      ),
    ],
    SectionTitle(l10n.labelCopyFormat),
    MacosPopupButton<String>(
      value: s.copyFormat,
      items: [
        for (final f in exportFormats)
          MacosPopupMenuItem(value: f.id, child: Text(f.label)),
      ],
      onChanged: (value) {
        if (value != null) _cubit.setCopyFormat(value);
      },
    ),
    Hint(l10n.hintCopyFormatSynced),
    SectionTitle(l10n.labelSaveFormat),
    MacosPopupButton<String>(
      value: s.saveFormat,
      items: [
        for (final f in exportFormats)
          MacosPopupMenuItem(value: f.id, child: Text(f.label)),
      ],
      onChanged: (value) {
        if (value != null) _cubit.setSaveFormat(value);
      },
    ),
    Hint(l10n.hintSaveFormatSynced),
    SectionTitle(l10n.sectionCopyBesideSource),
    Check(
      l10n.checkSaveBesideSource,
      s.saveNextToSource,
      _cubit.setSaveNextToSource,
    ),
    Hint(l10n.hintSaveBesideSource, under: true),
    // Метки времени переехали сюда из «Общих»: они рисуются в окне
    // расшифровщика и больше нигде — в диктовке текста с таймкодами
    // нет вовсе.
    SectionTitle(l10n.sectionInTranscriberWindow),
    Check(l10n.checkShowTimestamps, s.timestamps, _cubit.setTimestamps),
    Hint(l10n.hintShowTimestamps, under: true),
  ];

  /// Список один на диктовку и расшифровщик, а выключатели разные.
  /// Показываем редактор в обеих вкладках: человеку не приходится помнить,
  /// на какой стороне он когда-то завёл команду.
  List<Widget> _textCommands(
    SettingsState s, {
    required bool enabled,
    required ValueChanged<bool> onEnabled,
  }) => [
    SectionTitle(l10n.sectionVoiceCommands),
    Check(l10n.checkVoiceCommands, enabled, onEnabled),
    Hint(l10n.hintVoiceCommandsShared, under: true),
    if (enabled) ...[
      const SizedBox(height: Gap.item),
      for (final (index, command) in s.textCommands.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.item),
          child: _TextCommandRow(
            key: ValueKey(index),
            command: command,
            phraseHint: l10n.placeholderCommandPhrase,
            replacementHint: l10n.placeholderCommandReplacement,
            removeHint: l10n.tooltipRemoveCommand,
            onChanged: (next) => _cubit.updateTextCommand(index, next),
            onRemove: () => _cubit.removeTextCommand(index),
          ),
        ),
      PushButton(
        controlSize: ControlSize.small,
        secondary: true,
        onPressed: _cubit.addTextCommand,
        child: Text(l10n.buttonAddCommand),
      ),
    ],
  ];

  /// Местное API: та самая галка, которой открывают дверь наружу.
  ///
  /// Стоит на вкладке «Приложение», а не у расшифровщика: это не про то,
  /// как распознавать, а про то, кому позволено просить. Ключ показан
  /// целиком — прятать его за звёздочками бессмысленно, он нужен именно
  /// для того, чтобы его скопировать и отдать своей программе.
  List<Widget> _apiSection(SettingsState s) => [
    SectionTitle(l10n.sectionApi),
    Check(l10n.checkApiEnabled, s.apiEnabled, (v) {
      setState(() => _keyCopied = false);
      _cubit.setApiEnabled(v);
    }),
    Hint(
      s.apiEnabled ? l10n.hintApiEnabled('${s.apiPort}') : l10n.hintApiDisabled,
      under: true,
    ),
    if (s.apiEnabled) ...[
      if (s.apiError.isNotEmpty)
        _problem(l10n.apiFailed(s.apiError, '${s.apiPort}')),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldApiKey,
        Row(
          children: [
            Expanded(
              child: Text(
                s.apiKey,
                maxLines: 1,
                style: Type.control.copyWith(fontFamily: 'Menlo'),
              ),
            ),
            const SizedBox(width: Gap.control),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: s.apiKey));
                setState(() => _keyCopied = true);
              },
              child: Text(l10n.buttonCopyKey),
            ),
          ],
        ),
      ),
      Hint(_keyCopied ? l10n.apiKeyCopied : l10n.hintApiKey),
    ],
  ];

  /// Скилл для нейросетевых агентов.
  ///
  /// Раздел свёрнут по умолчанию, и это не кокетство: тому, кто
  /// нейросетевыми агентами не пользуется, он не должен мозолить глаза
  /// на каждом открытии настроек. Развернувшему видно две вещи — кому
  /// скилл уже поставлен и кому его можно поставить.
  ///
  /// Галку у ненайденного агента человек может поставить сам: он вправе
  /// собираться поставить агента следом за нами, и запрещать ему это
  /// значило бы решать за него. Папку тогда заводим мы — но только
  /// по его нажатию и только ту, что этому агенту и принадлежит.
  List<Widget> _skillSection(SettingsState s) {
    final installed = [
      for (final a in skillAgents)
        if (a.alreadyInstalled()) a,
    ];
    return [
      SectionTitle(l10n.sectionSkill),
      Hint(l10n.hintSkill, under: true),
      const SizedBox(height: Gap.inner),
      Disclosure(
        label: l10n.sectionSkill,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Gap.item),
            Text(l10n.skillInstalledFor, style: Type.control),
            const SizedBox(height: Gap.hint),
            Text(
              installed.isEmpty
                  ? l10n.skillNobodyYet
                  : installed.map((a) => a.name).join(', '),
              style: Type.caption.copyWith(
                color: installed.isEmpty
                    ? Surface.secondaryText(context)
                    : MacosColors.systemGreenColor,
              ),
            ),
            const SizedBox(height: Gap.section),
            Text(l10n.skillCanInstallFor, style: Type.control),
            const SizedBox(height: Gap.inner),
            for (final agent in skillAgents)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.tight),
                child: Check(
                  agent.configDir() == null
                      ? '${agent.name} — ${l10n.skillAgentMissing}'
                      : agent.name,
                  _skillPicked(agent),
                  (on) => setState(() => _skillPick[agent.id] = on),
                ),
              ),
            const SizedBox(height: Gap.item),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: () => _cubit.installSkillToAgents([
                    for (final a in skillAgents)
                      if (_skillPicked(a)) a,
                  ]),
                  child: Text(l10n.buttonInstallSkillChosen),
                ),
              ],
            ),
            for (final agent in skillAgents)
              if (s.skillResult[agent.id] != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.hint),
                  child: Text(
                    '${agent.name} — ${switch (s.skillResult[agent.id]!) {
                      SkillOutcome.installed => l10n.skillInstalled,
                      // Место занято чужим скиллом с тем же именем.
                      // Затирать чужую работу хуже, чем не поставить свою.
                      SkillOutcome.foreign => l10n.skillForeign,
                      SkillOutcome.failed => l10n.skillFailed,
                    }}',
                    style: Type.caption.copyWith(
                      color: s.skillResult[agent.id] == SkillOutcome.installed
                          ? MacosColors.systemGreenColor
                          : Surface.secondaryText(context),
                    ),
                  ),
                ),
          ],
        ),
      ),
    ];
  }

  /// Что человек решил про каждого агента. Пусто — решения не было, и
  /// тогда действует умолчание: найденный отмечен, ненайденный нет.
  final _skillPick = <String, bool>{};

  bool _skillPicked(AgentTarget a) =>
      _skillPick[a.id] ?? (a.configDir() != null);

  // ── приложение ────────────────────────────────────────────────────────────

  /// Здесь остаётся только то, что не принадлежит ни расшифровщику,
  /// ни диктовке: как приложение живёт в системе и что ему разрешено.
  /// Всё остальное разъехалось по хозяевам.
  List<Widget> _appTab(SettingsState s) => [
    SectionTitle(l10n.sectionLanguage),
    _Field(
      l10n.fieldLanguage,
      MacosPopupButton<String>(
        value: s.locale,
        items: [
          MacosPopupMenuItem(value: '', child: Text(l10n.languageSystem)),
          // Языки названы на себе самих: так их узнают и те, кто
          // случайно переключился на незнакомый.
          const MacosPopupMenuItem(value: 'ru', child: Text('Русский')),
          const MacosPopupMenuItem(value: 'en', child: Text('English')),
        ],
        onChanged: (v) => _cubit.setLocale(v ?? ''),
      ),
    ),
    Hint(l10n.hintLanguage),
    SectionTitle(l10n.sectionInSystem),
    Check(l10n.checkLoginItem, s.loginItem, _cubit.setLoginItem),
    Hint(l10n.hintLoginItem(os.menuBarName), under: true),
    const SizedBox(height: Gap.item),
    Check(
      l10n.checkShowDockIcon(os.appIconAreaName),
      s.dockIcon,
      _cubit.setDockIcon,
    ),
    Hint(
      l10n.hintDockIcon(appName, os.appIconAreaName, os.menuBarName),
      under: true,
    ),
    ..._apiSection(s),
    ..._skillSection(s),
    // Разрешение системы — вещь macOS: там без «Универсального доступа»
    // не перехватить клавишу и не вставить текст. На Windows такого
    // разрешения нет вовсе, и раздел о нём обещал бы работу, которой
    // не существует. Микрофон — другое дело, но его спрашивает сама
    // система при первой записи.
    if (os.needsAccessibilityPermission) ...[
      SectionTitle(l10n.sectionPermissions),
      Row(
        children: [
          Expanded(
            child: Text(
              s.allowed
                  ? l10n.permissionGranted(os.accessibilityName)
                  : l10n.permissionMissing(os.accessibilityName, appName),
              style: Type.control.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
      Hint(l10n.hintPermissionWhy),
      const SizedBox(height: Gap.item),
      if (!s.allowed)
        Row(
          children: [
            PushButton(
              controlSize: ControlSize.regular,
              onPressed: _cubit.requestPermission,
              child: Text(l10n.buttonRequestPermission),
            ),
            const SizedBox(width: Gap.control),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _cubit.openPermissionSettings,
              child: Text(l10n.buttonOpenSystemSettings),
            ),
          ],
        )
      else
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: _cubit.openPermissionSettings,
          child: Text(l10n.buttonOpenSystemSettings),
        ),
    ],
  ];
}

/// Одна команда редактируется на месте. Контроллеры принадлежат строке,
/// иначе новая буква возвращала бы курсор в конец при каждом состоянии
/// кубита, а удаление соседней строки оставляло бы в поле чужой текст.
class _TextCommandRow extends StatefulWidget {
  const _TextCommandRow({
    super.key,
    required this.command,
    required this.phraseHint,
    required this.replacementHint,
    required this.removeHint,
    required this.onChanged,
    required this.onRemove,
  });

  final TextCommand command;
  final String phraseHint, replacementHint, removeHint;
  final ValueChanged<TextCommand> onChanged;
  final VoidCallback onRemove;

  @override
  State<_TextCommandRow> createState() => _TextCommandRowState();
}

class _TextCommandRowState extends State<_TextCommandRow> {
  late final _phrase = TextEditingController(text: widget.command.phrase);
  late final _replacement = TextEditingController(
    text: widget.command.replacement,
  );

  @override
  void didUpdateWidget(covariant _TextCommandRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_phrase.text != widget.command.phrase) {
      _phrase.text = widget.command.phrase;
    }
    if (_replacement.text != widget.command.replacement) {
      _replacement.text = widget.command.replacement;
    }
  }

  @override
  void dispose() {
    _phrase.dispose();
    _replacement.dispose();
    super.dispose();
  }

  void _changed() =>
      widget.onChanged(TextCommand(_phrase.text, _replacement.text));

  bool _removeHovered = false;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Gap.item),
    decoration: BoxDecoration(
      color: Surface.hover(context),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _commandField(label: widget.phraseHint, controller: _phrase),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.control, 28, Gap.control, 0),
          child: MacosIcon(
            CupertinoIcons.arrow_right,
            size: IconSize.toolbar,
            color: Surface.secondaryText(context),
          ),
        ),
        Expanded(
          child: _commandField(
            label: widget.replacementHint,
            controller: _replacement,
          ),
        ),
        const SizedBox(width: Gap.control),
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: MouseRegion(
            onEnter: (_) => setState(() => _removeHovered = true),
            onExit: (_) => setState(() => _removeHovered = false),
            child: MacosTooltip(
              message: widget.removeHint,
              child: MacosIconButton(
                icon: MacosIcon(
                  CupertinoIcons.trash,
                  size: IconSize.toolbar,
                  color: _removeHovered
                      ? MacosColors.systemRedColor
                      : Surface.secondaryText(context),
                ),
                boxConstraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: widget.onRemove,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _commandField({
    required String label,
    required TextEditingController controller,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Type.caption),
      const SizedBox(height: Gap.inner),
      AppTextField(controller: controller, onChanged: (_) => _changed()),
    ],
  );
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
      Text(
        label,
        style: Type.caption.copyWith(color: Surface.secondaryText(context)),
      ),
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
          // Ширины хватает самой длинной подписи («Расшифровщик»):
          // ужатая до многоточия вкладка не называет ничего.
          width: 96,
          margin: const EdgeInsets.symmetric(horizontal: Gap.hint),
          padding: const EdgeInsets.symmetric(vertical: Gap.inner),
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
              // Ступень панели инструментов: вкладка стоит в той же
              // полосе, что и панель в других окнах, и значок в ней
              // держится сам, без текста рядом.
              MacosIcon(widget.icon, size: IconSize.toolbar, color: color),
              const SizedBox(height: Gap.hint),
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
