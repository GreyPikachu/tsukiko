part of 'home_page.dart';

/// Меню в строке меню. Собирается заново только когда меняется то, что
/// в нём видно, — иначе Flutter пересобирал бы NSMenu на каждый setState.
extension _Menus on _HomePageState {
  /// PlatformMenuItem сравнивается по ссылке, поэтому Flutter пересобирает
  /// NSMenu на каждый setState — а во время распознавания их десятки в секунду.
  /// Пересобираем меню только когда меняется то, что в нём видно.
  List<PlatformMenuItem> _menus() {
    // Список значений, а не склеенная строка. Склейка работала верно:
    // разделителями стояли управляющие символы \x00 и \x01, которых
    // в путях не бывает. Но стояли они в исходнике сырыми байтами — файл
    // после этого двоичный для git (никакого diff по нему) и неразличимый
    // на глаз в любом редакторе. Сравнение списков даёт ту же гарантию
    // и остаётся читаемым.
    final signature = <Object?>[
      _readyTargets.isNotEmpty,
      _targets.isNotEmpty,
      _targets.any((j) => !j.imported),
      _running,
      _hasPending,
      _jobs.any((j) => j.done),
      _jobs.isEmpty,
      _sel.isEmpty,
      _job == null,
      _timestamps,
      _yieldBusyModel,
      _lead?.file.path,
      ..._recent,
    ];
    if (listEquals(signature, _menuSignature)) return _menuCache;
    _menuSignature = signature;
    return _menuCache = _buildMenus();
  }

  List<PlatformMenuItem> _buildMenus() {
    final ready = _readyTargets.isNotEmpty;
    final selected = _targets.isNotEmpty;
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
            PlatformMenuItem(label: 'Добавить аудио…', shortcut: _HomePageState._cmd, onSelected: _pickFiles),
            PlatformMenuItem(
              label: 'Открыть расшифровку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
              onSelected: () => _import(),
            ),
            PlatformMenu(
              label: 'Открыть недавние',
              menus: [
                for (final p in _recent)
                  PlatformMenuItem(
                    label: os.basename(p),
                    onSelected: () => audioExt.contains(_ext(p))
                        ? _addPaths([p])
                        : _import(p),
                  ),
                if (_recent.isNotEmpty)
                  PlatformMenuItemGroup(members: [
                    PlatformMenuItem(
                      label: 'Очистить список',
                      onSelected: () {
                        _set(() => _recent = const []);
                        _persist();
                      },
                    ),
                  ]),
              ],
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Сохранить как…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
              onSelected: ready ? () => _saveAs() : null,
            ),
            PlatformMenuItem(
              label: 'Экспортировать в папку…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true),
              onSelected: _jobs.any((j) => j.done) ? _exportAll : null,
            ),
            PlatformMenuItem(
              label: 'Показать библиотеку в ${os.fileManagerName}',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true),
              onSelected: () => revealInFinder(_libraryPath),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Показать исходный файл в Finder',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
              onSelected: _lead == null ? null : () => revealInFinder(_lead!.file.path),
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
              onSelected: _jobs.isEmpty ? null : _selectAll,
            ),
            PlatformMenuItem(
              label: 'Снять выделение',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true),
              onSelected: _sel.isEmpty ? null : _deselect,
            ),
            PlatformMenuItem(
              label: 'Убрать из очереди',
              shortcut: const SingleActivator(LogicalKeyboardKey.backspace, meta: true),
              onSelected: selected ? _removeSelected : null,
            ),
            PlatformMenuItem(
              label: 'Убрать все готовые',
              onSelected: _jobs.any((j) => j.done) ? _clearFinished : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: 'Найти в расшифровке…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
              onSelected: _job == null ? null : _openFind,
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
              onSelected: _running || !_hasPending ? null : _start,
            ),
            PlatformMenuItem(
              label: 'Распознать заново',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true),
              onSelected:
                  _running || !_targets.any((j) => !j.imported) ? null : _retry,
            ),
            PlatformMenuItem(
              label: 'Остановить',
              shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
              onSelected: _running ? _stop : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: _yieldBusyModel
                  ? 'Не ждать занятую модель'
                  : 'Ждать, если модель занята',
              onSelected: () {
                _set(() => _yieldBusyModel = !_yieldBusyModel);
                _persist();
              },
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: 'Вид',
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: _timestamps ? 'Скрыть метки времени' : 'Показать метки времени',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, alt: true),
              onSelected: () {
                _set(() => _timestamps = !_timestamps);
                _persist();
              },
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
            onSelected: () => revealInFinder(_libraryPath),
          ),
          PlatformMenuItem(label: 'О программе $appName', onSelected: _about),
        ],
      ),
    ];
  }
}
