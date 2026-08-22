part of 'home_page.dart';

/// Меню в строке меню. Собирается заново только когда меняется то, что
/// в нём видно, — иначе Flutter пересобирал бы NSMenu на каждое состояние.
extension _Menus on _HomeViewState {
  /// PlatformMenuItem сравнивается по ссылке, поэтому Flutter пересобирает
  /// NSMenu на каждый setState — а во время распознавания их десятки в секунду.
  /// Пересобираем меню только когда меняется то, что в нём видно.
  List<PlatformMenuItem> _menus(QueueState s) {
    // Список значений, а не склеенная строка. Склейка работала верно:
    // разделителями стояли управляющие символы \x00 и \x01, которых
    // в путях не бывает. Но стояли они в исходнике сырыми байтами — файл
    // после этого двоичный для git (никакого diff по нему) и неразличимый
    // на глаз в любом редакторе. Сравнение списков даёт ту же гарантию
    // и остаётся читаемым.
    final signature = <Object?>[
      s.readyTargets.isNotEmpty,
      s.targets.isNotEmpty,
      s.targets.any((j) => !j.imported),
      s.running,
      s.hasPending,
      s.jobs.any((j) => j.done),
      s.jobs.isEmpty,
      s.selected.isEmpty,
      s.lead == null,
      s.timestamps,
      s.yieldBusyModel,
      s.lead?.file.path,
      ...s.recent,
    ];
    if (listEquals(signature, _menuSignature)) return _menuCache;
    _menuSignature = signature;
    return _menuCache = _buildMenus(s);
  }

  List<PlatformMenuItem> _buildMenus(QueueState s) {
    final ready = s.readyTargets.isNotEmpty;
    final selected = s.targets.isNotEmpty;
    return [
      PlatformMenu(
        label: appName,
        menus: [
          PlatformMenuItem(label: 'О программе $appName', onSelected: _about),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Настройки…',
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              onSelected: () => _openSettings(),
            ),
          ]),
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
            PlatformMenuItem(label: 'Добавить аудио…', shortcut: _HomeViewState._cmd, onSelected: _pickFiles),
            PlatformMenuItem(
              label: 'Открыть расшифровку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
              onSelected: _openTranscript,
            ),
            PlatformMenu(
              label: 'Открыть недавние',
              menus: [
                for (final p in s.recent)
                  PlatformMenuItem(
                    label: os.basename(p),
                    onSelected: () => _send(audioExt.contains(_ext(p))
                        ? FilesAdded([p])
                        : TranscriptOpened(p)),
                  ),
                if (s.recent.isNotEmpty)
                  PlatformMenuItemGroup(members: [
                    PlatformMenuItem(
                      label: 'Очистить список',
                      onSelected: () => _send(const RecentCleared()),
                    ),
                  ]),
              ],
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Сохранить как…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
              onSelected: ready ? () => _saveAs(s) : null,
            ),
            PlatformMenuItem(
              label: 'Экспортировать в папку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true),
              onSelected: s.jobs.any((j) => j.done) ? () => _exportAll(s) : null,
            ),
            PlatformMenuItem(
              label: 'Показать библиотеку в ${os.fileManagerName}',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true),
              onSelected: () => revealInFinder(s.libraryPath),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Показать исходный файл в Finder',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
              onSelected: s.lead == null ? null : () => revealInFinder(s.lead!.file.path),
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
              onSelected: s.jobs.isEmpty ? null : _sendAll,
            ),
            PlatformMenuItem(
              label: 'Снять выделение',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true),
              onSelected: s.selected.isEmpty ? null : _sendDeselect,
            ),
            PlatformMenuItem(
              label: 'Убрать из очереди',
              shortcut: const SingleActivator(LogicalKeyboardKey.backspace, meta: true),
              onSelected: selected ? _sendRemove : null,
            ),
            PlatformMenuItem(
              label: 'Убрать все готовые',
              onSelected: s.jobs.any((j) => j.done) ? _sendClearFinished : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Найти в расшифровке…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
              onSelected: s.lead == null ? null : _openFind,
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
              onSelected: s.running || !s.hasPending ? null : _sendStart,
            ),
            PlatformMenuItem(
              label: 'Распознать заново',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true),
              onSelected: s.running || !s.canRetry ? null : _sendRetry,
            ),
            PlatformMenuItem(
              label: 'Остановить',
              shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
              onSelected: s.running ? _sendStop : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: s.yieldBusyModel
                  ? 'Не ждать занятую модель'
                  : 'Ждать, если модель занята',
              onSelected: () => _send(const YieldToggled()),
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Вид',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: s.timestamps ? 'Скрыть метки времени' : 'Показать метки времени',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, alt: true),
              onSelected: () => _send(const TimestampsToggled()),
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
            onSelected: () => revealInFinder(s.libraryPath),
          ),
          PlatformMenuItem(label: 'О программе $appName', onSelected: _about),
        ],
      ),
    ];
  }
}
