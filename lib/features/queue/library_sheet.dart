import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/library.dart';
import '../../core/text.dart';
import '../../core/labels.dart';
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/os.dart';
import 'widgets/chrome.dart';

/// Прошлые расшифровки: что библиотека накопила за всё время.
///
/// Не окно и не движок, а лист поверх главного окна. Отдельный движок здесь
/// был бы платой без выгоды: каждое окно на обеих системах — это своя точка
/// входа, своё родное окно на Swift и на C++ и свой канал (см.
/// `docs/архитектура.md`), а весь смысл этого списка в двух действиях,
/// которые принадлежат главному окну: перенести расшифровку в очередь и
/// показать файл в проводнике. Лист здесь уже применён — тем же способом
/// показан список сочетаний.
///
/// Источник — сама папка библиотеки, а не наш файл состояния. Она и есть
/// хранилище готовых расшифровок: переживает перезапуск, переустановку и
/// правится человеком напрямую. Второй список рядом с ней разошёлся бы
/// с делом в тот же день, когда человек переложит папку.
///
/// Очередь при этом остаётся чистой при каждом запуске — и это то же самое
/// решение, с другой стороны: список заводят под задачу, вчерашние два
/// десятка строк стоят поперёк новой работы, а вернуться к прошлому можно
/// отсюда, по одной записи и осознанно.
class LibrarySheet extends StatefulWidget {
  const LibrarySheet({
    super.key,
    required this.root,
    required this.onOpenInQueue,
    required this.onOpenSource,
    required this.onPointAtSource,
    required this.onReveal,
    required this.onTrash,
    required this.onStatus,
  });

  /// Корень библиотеки. Его правит окно настроек, поэтому приходит снаружи.
  final String root;

  /// Перенести расшифровку в очередь. Дальше с ней работают как с любой
  /// другой записью: пересохранить в другом формате, поискать по тексту,
  /// скопировать фрагмент.
  final ValueChanged<String> onOpenInQueue;

  /// Положить в очередь саму запись — тот звук, из которого расшифровка
  /// вышла. Отсюда её можно посчитать другой моделью или нарезать
  /// субтитры заново, чего с одним текстом уже не сделать.
  final ValueChanged<String> onOpenSource;

  /// Спросить, где запись лежит теперь, и связать её с расшифровкой.
  /// Возвращает путь, если человек его назвал.
  final Future<String?> Function(String transcriptPath) onPointAtSource;

  final ValueChanged<String> onReveal;

  /// Убрать выбранные файлы в Корзину. Не стереть: промах по кнопке после
  /// получаса разбора иначе стоил бы этого получаса, а из Корзины файл
  /// возвращается средствами самой системы. Возвращает то, что убрать
  /// не вышло.
  final Future<List<String>> Function(List<String> paths) onTrash;

  /// Сказать что-нибудь в строке состояния главного окна: своей у листа
  /// нет, а молчаливое копирование выглядит как ничего не случилось.
  final ValueChanged<String> onStatus;

  @override
  State<LibrarySheet> createState() => _LibrarySheetState();
}

class _LibrarySheetState extends State<LibrarySheet> {
  late List<LibraryEntry> _entries = scanLibrary(widget.root);
  LibraryEntry? _shown;

  /// Режим выбора: строки обзавелись галками, а низ окна — уборкой.
  ///
  /// Отдельным режимом, а не постоянными галками: обзор для того и открыт,
  /// чтобы читать, и галка у каждой строки всё время предлагала бы
  /// удалять там, где человек пришёл смотреть. Кнопка «Выбрать» — то же
  /// самое, что в «Фото» и «Файлах»: пока её не нажали, список остаётся
  /// списком.
  bool _selecting = false;
  final _chosen = <String>{};

  /// Прочитанное содержимое выбранной строки. Читаем по одному файлу и
  /// только по щелчку: библиотека за год это тысячи файлов, и читать их
  /// все ради списка было бы тратой на пустом месте.
  String _text = '';

  /// Где лежит запись выбранной расшифровки, если она вообще жива.
  /// null и при «связи нет», и при «запись пропала» — их различает
  /// [_link].
  String? _source;
  SourceLink? _link;

  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    if (_entries.isNotEmpty) _show(_entries.first);
  }

  /// Синхронно, и это не оплошность. Расшифровка — текстовый файл в
  /// десятки килобайт; чтение такого не успевает пропустить кадр, а
  /// асинхронное чтение стоило бы состояния «читаю», крутилки на его
  /// месте и проверок, что строку не сменили, пока файл ехал.
  ///
  /// Показываем файл как он есть, а не пересобранным в простой текст.
  /// Раньше он разбирался на фрагменты и рисовался заново без таймкодов —
  /// то есть субтитры, «текст с таймкодами» и markdown выглядели тут
  /// одинаково, и понять, что за файл открыт, было нельзя. А формат
  /// человек выбирал сам, и увидеть он хочет именно его.
  void _show(LibraryEntry entry) {
    String text;
    try {
      text = File(entry.path).readAsStringSync();
    } catch (_) {
      // Двоичный файл, чужая кодировка, исчез из-под рук.
      text = '';
    }
    final link = Sources.of(widget.root, entry.path);
    setState(() {
      _shown = entry;
      _text = text;
      _link = link;
      _source = link == null
          ? null
          : Sources.locate(widget.root, link, entry.path);
    });
  }

  /// Строка о записи под текстом: связана ли расшифровка с записью и
  /// на месте ли та. Единственный вопрос, ради которого это заведено.
  Widget _sourceLine() {
    final link = _link;
    final source = _source;
    final says = source != null
        ? l10n.librarySourceHere(os.basename(source))
        : link != null
        ? l10n.librarySourceGone(os.basename(link.path))
        : l10n.librarySourceUnknown;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      child: Row(
        children: [
          MacosIcon(
            source != null
                ? CupertinoIcons.waveform
                : CupertinoIcons.waveform_path,
            size: 13,
            color: Surface.secondaryText(context),
          ),
          const SizedBox(width: 7, height: 10),
          Expanded(
            child: Text(
              says,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pointAtSource() async {
    final shown = _shown;
    if (shown == null) return;
    final path = await widget.onPointAtSource(shown.path);
    if (path == null || !mounted) return;
    final link = Sources.of(widget.root, shown.path);
    setState(() {
      _link = link;
      _source = path;
    });
    widget.onStatus(l10n.statusSourceLinked(os.basename(path)));
  }

  void _copy() {
    if (_text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: _text)));
    widget.onStatus(l10n.statusLibraryTextCopied);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    // Esc закрывает — как любое временное окно в системе. Щелчок мимо
    // листа делает то же самое, и это уже забота showMacosSheet
    // (barrierDismissible), но клавишу он на себя не берёт.
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).maybePop(),
    },
    child: Focus(autofocus: true, child: _sheet(context)),
  );

  Widget _sheet(BuildContext context) => MacosSheet(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 16, 4),
          child: Row(
            children: [
              // Заголовок посередине, кнопка справа — как в списках
              // системы. Ширина под кнопку отведена и слева, иначе
              // заголовок стоял бы не по центру окна.
              const SizedBox(width: 96),
              Expanded(
                child: Text(
                  l10n.sheetLibraryTitle,
                  textAlign: TextAlign.center,
                  style: Type.emptyTitle,
                ),
              ),
              SizedBox(
                width: 96,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _entries.isEmpty
                      ? null
                      : PushButton(
                          controlSize: ControlSize.regular,
                          secondary: !_selecting,
                          onPressed: _toggleSelecting,
                          child: Text(
                            _selecting
                                ? l10n.buttonSelectDone
                                : l10n.buttonSelect,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            _entries.isEmpty
                ? l10n.sheetLibraryEmpty
                : _selecting
                ? l10n.sheetLibrarySelectHint
                : l10n.sheetLibrarySubtitle(filesLabel(_entries.length)),
            textAlign: TextAlign.center,
            style: Type.caption.copyWith(color: Surface.secondaryText(context)),
          ),
        ),
        Expanded(child: _entries.isEmpty ? _empty() : _split()),
        _buttons(),
      ],
    ),
  );

  /// Пустая библиотека — не беда и не ошибка: расшифровок ещё не было,
  /// или их складывание выключено на вкладке расшифровщика. Говорим прямо,
  /// а не показываем пустой список.
  Widget _empty() => Center(
    child: EmptyNotice(
      icon: CupertinoIcons.tray,
      title: l10n.sheetLibraryEmptyTitle,
      subtitle: l10n.sheetLibraryEmptyBody(widget.root),
    ),
  );

  Widget _split() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(width: 300, child: _list()),
      Container(width: 1, color: Surface.hairline(context)),
      Expanded(child: _preview()),
    ],
  );

  Widget _list() => ListView.builder(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
    itemCount: _entries.length,
    itemBuilder: (context, i) => _EntryRow(
      entry: _entries[i],
      folder: _entries[i].folderIn(widget.root),
      selected: !_selecting && _entries[i] == _shown,
      choosing: _selecting,
      chosen: _chosen.contains(_entries[i].path),
      // В режиме выбора щелчок по строке её отмечает, а не открывает:
      // два смысла у одного жеста означали бы, что промах стоит
      // не того, чего ждали.
      onTap: () => _selecting ? _toggleChosen(_entries[i]) : _show(_entries[i]),
    ),
  );

  void _toggleSelecting() => setState(() {
    _selecting = !_selecting;
    _chosen.clear();
  });

  void _toggleChosen(LibraryEntry entry) => setState(() {
    if (!_chosen.remove(entry.path)) _chosen.add(entry.path);
  });

  /// Убрать выбранное в Корзину.
  ///
  /// Без вопроса «вы уверены?»: действие обратимо средствами системы, а
  /// подтверждение на каждое обратимое действие приучает нажимать «да»
  /// не глядя — и перестаёт работать там, где оно и правда нужно.
  Future<void> _trashChosen() async {
    final doomed = _chosen.toList();
    if (doomed.isEmpty) return;
    final left = await widget.onTrash(doomed);
    if (!mounted) return;
    final gone = doomed.where((p) => !left.contains(p)).toSet();
    setState(() {
      _entries = [
        for (final e in _entries)
          if (!gone.contains(e.path)) e,
      ];
      _chosen
        ..clear()
        ..addAll(left);
      if (gone.contains(_shown?.path)) _shown = null;
      if (_shown == null && _entries.isNotEmpty) _show(_entries.first);
      if (_entries.isEmpty) _selecting = false;
    });
    widget.onStatus(
      left.isEmpty
          ? l10n.statusLibraryTrashed(filesLabel(gone.length))
          : l10n.statusLibraryTrashFailed(filesLabel(left.length)),
    );
  }

  Widget _previewText() {
    if (_text.trim().isEmpty) {
      return Center(
        child: Text(
          l10n.sheetLibraryUnreadable,
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
      child: SelectableText(_text, style: Type.body),
    );
  }

  Widget _preview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: _previewText()),
      if (_shown != null) _sourceLine(),
    ],
  );

  Widget _buttons() => _selecting ? _selectionButtons() : _readingButtons();

  Widget _selectionButtons() {
    final all = _chosen.length == _entries.length;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: () => setState(() {
              _chosen.clear();
              if (!all) _chosen.addAll(_entries.map((e) => e.path));
            }),
            child: Text(all ? l10n.buttonSelectNone : l10n.buttonSelectAll),
          ),
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: _toggleSelecting,
            child: Text(l10n.buttonSelectDone),
          ),
          // Единственная кнопка, за которой пропадают файлы, — и она
          // названа тем, что делает: не «Удалить», а «Убрать в Корзину».
          PushButton(
            controlSize: ControlSize.large,
            onPressed: _chosen.isEmpty ? null : _trashChosen,
            child: Text(l10n.buttonDeleteChosen(_chosen.length)),
          ),
        ],
      ),
    );
  }

  Widget _readingButtons() {
    final shown = _shown;
    // Wrap, а не Row: четыре кнопки с русскими подписями в узком листе
    // в строку не помещаются, а Row на нехватку места отвечает полосатой
    // лентой поверх интерфейса. Здесь они просто переносятся.
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: shown == null ? null : () => widget.onReveal(shown.path),
            child: Text(l10n.buttonShowInFileManager(os.fileManagerName)),
          ),
          // Запись на месте — её можно взять в работу. Записи нет или
          // связи нет — на том же месте кнопка «Указать запись…»:
          // человек знает, куда он её переложил, а мы нет.
          if (_source case final source?)
            PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: () {
                Navigator.pop(context);
                widget.onOpenSource(source);
              },
              child: Text(l10n.buttonOpenSourceInQueue),
            )
          else if (shown != null)
            PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: _pointAtSource,
              child: Text(l10n.buttonPointAtSource),
            ),
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: _text.isEmpty ? null : _copy,
            child: Text(l10n.buttonCopyText),
          ),
          PushButton(
            controlSize: ControlSize.large,
            secondary: true,
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.buttonClose),
          ),
          // Главное действие — вернуть расшифровку в приложение: дальше
          // с ней работают как с любой другой записью очереди.
          PushButton(
            controlSize: ControlSize.large,
            onPressed: shown == null
                ? null
                : () {
                    Navigator.pop(context);
                    widget.onOpenInQueue(shown.path);
                  },
            child: Text(l10n.buttonOpenInQueue),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.entry,
    required this.folder,
    required this.selected,
    required this.choosing,
    required this.chosen,
    required this.onTap,
  });

  final LibraryEntry entry;
  final String folder;

  /// Строка, чей текст показан справа.
  final bool selected;

  /// Идёт выбор — у строк появились галки.
  final bool choosing;

  /// Эта строка отмечена галкой.
  final bool chosen;

  final VoidCallback onTap;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? accent
                : _hover
                ? Surface.hover(context)
                : MacosColors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              // Галка приезжает слева и раздвигает строку, а не ложится
              // поверх имени: имя тут — то, по чему запись и узнают.
              AnimatedSize(
                duration: Motion.dur(context, Motion.settle),
                curve: Motion.curve(context, Motion.settleCurve),
                child: widget.choosing
                    ? Padding(
                        padding: const EdgeInsets.only(right: 9),
                        child: MacosCheckbox(
                          value: widget.chosen,
                          onChanged: (_) => widget.onTap(),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Expanded(child: _lines(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lines(BuildContext context) {
    final e = widget.entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          e.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Type.fileName.copyWith(
            color: widget.selected ? MacosColors.white : null,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          // Папка, формат и дата: по ним запись и узнают через
          // полгода. Формат назван словом, а не расширением: «.srt»
          // говорит меньше, чем «Субтитры SRT».
          [
            widget.folder,
            ?formatOfFile(e.path)?.label,
            _when(e.at),
          ].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Type.caption.copyWith(
            color: widget.selected
                ? MacosColors.white.withValues(alpha: 0.8)
                : Surface.secondaryText(context),
          ),
        ),
      ],
    );
  }

  /// Дата словами той же длины, что и всё в этом окне: день и время.
  /// Ни года, ни секунд: год виден по папке, а секунда ничего не решает.
  String _when(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
