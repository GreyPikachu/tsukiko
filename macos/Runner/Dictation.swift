import AVFoundation
import Cocoa
import FlutterMacOS
import ServiceManagement

/// Прослойка диктовки: перехват клавиш, запись с микрофона, вставка текста
/// и панель у строки меню.
///
/// Всё это живёт на отдельном движке Flutter — том, что рисует панель.
/// Он работает и когда панель спрятана, поэтому диктовка не зависит от
/// того, открыто ли главное окно.

// ── сочетания клавиш ────────────────────────────────────────────────────────

private let modifierFlags: [(String, CGEventFlags)] = [
  ("fn", .maskSecondaryFn),
  ("ctrl", .maskControl),
  ("opt", .maskAlternate),
  ("shift", .maskShift),
  ("cmd", .maskCommand),
]

private func modNames(_ flags: CGEventFlags) -> Set<String> {
  var out = Set<String>()
  for (name, mask) in modifierFlags where flags.contains(mask) { out.insert(name) }
  return out
}

private let keyCodes: [String: CGKeyCode] = [
  "space": 49, "return": 36, "tab": 48, "escape": 53, "delete": 51,
  "forwarddelete": 117, "enter": 76,
  "left": 123, "right": 124, "down": 125, "up": 126,
  "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
  ",": 43, ".": 47, "/": 44, "`": 50,
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
  "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
  "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
  "m": 46,
  "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
  "9": 25, "0": 29,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
  "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
  "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
  "f20": 90,
]

private let keyNames: [CGKeyCode: String] = {
  var out = [CGKeyCode: String]()
  for (name, code) in keyCodes { out[code] = name }
  return out
}()

/// Имя клавиши для передачи в Dart и обратно. Незнакомую называем её
/// кодом — тогда назначить можно действительно любую, а не только ту,
/// что мы заранее перечислили.
/// За сколько должен уложиться второй стук. Столько же ждёт система
/// от своего «двойного fn»: короче — не успеть, длиннее — начнёт ловить
/// два независимых нажатия как одно двойное.
private let doubleTapWindow: TimeInterval = 0.4

/// Дольше этого держат, а не стукают. Затянувшееся нажатие двойным
/// не считается — иначе «держать и говорить» ловилось бы как стук.
private let tapMaxHold: TimeInterval = 0.25

private func keyName(_ code: CGKeyCode) -> String {
  keyNames[code] ?? "#\(code)"
}

private func keyCode(_ name: String) -> CGKeyCode? {
  if let known = keyCodes[name] { return known }
  guard name.hasPrefix("#"), let raw = UInt16(name.dropFirst()) else { return nil }
  return CGKeyCode(raw)
}

/// Назначенное сочетание: набор модификаторов и набор обычных клавиш.
///
/// Именно набор, а не одна клавиша. Раньше сочетание было либо
/// «модификаторы плюс одна клавиша», либо «одни модификаторы», а обычную
/// клавишу в одиночку взять было нельзя вовсе — назначить «Y» или «X+Y»
/// не получалось. Теперь правило одно на все случаи.
private struct HotkeySpec {
  var mods = Set<String>()
  var keys = Set<CGKeyCode>()

  /// Сколько раз стукнуть. Двойное нажатие — это когда сочетание нажали
  /// и отпустили дважды подряд быстрее, чем за [doubleTapWindow].
  var taps = 1

  var isEmpty: Bool { mods.isEmpty && keys.isEmpty }
  var isDouble: Bool { taps >= 2 }

  init() {}

  init(mods: Set<String>, keys: Set<CGKeyCode>, taps: Int = 1) {
    self.mods = mods
    self.keys = keys
    self.taps = taps
  }

  init(_ raw: [String: Any]?) {
    guard let raw else { return }
    mods = Set((raw["mods"] as? [String]) ?? [])
    taps = (raw["taps"] as? Int) ?? 1
    if let names = raw["keys"] as? [String] {
      keys = Set(names.compactMap(keyCode))
    } else if let name = raw["key"] as? String, let code = keyCode(name) {
      // Настройки прежних сборок: там клавиша была одна.
      keys = [code]
    }
  }

  /// Сочетание зажато целиком.
  ///
  /// Совпадение строгое: fn+ctrl не должно срабатывать на fn+ctrl+cmd,
  /// иначе диктовка вклинивалась бы в чужие сочетания.
  func pressed(_ mods: Set<String>, _ held: Set<CGKeyCode>) -> Bool {
    !isEmpty && mods == self.mods && held == keys
  }

  /// Эта клавиша принадлежит сочетанию, и модификаторы сейчас те самые.
  /// По этому признаку событие поглощается, чтобы буква не попала в чужое
  /// поле ввода.
  func claims(_ code: CGKeyCode, _ mods: Set<String>) -> Bool {
    !isEmpty && keys.contains(code) && mods == self.mods
  }
}

/// Что происходит с одним сочетанием.
///
/// Нужна память о нажатии: без неё каждое событие flagsChanged, где набор
/// модификаторов снова совпал, считалось бы новым нажатием — и у toggle
/// это стоило записи (нажали и отпустили лишний модификатор поверх, набор
/// вернулся к назначенному, запись остановилась сама).
///
/// Двойное нажатие живёт здесь же: первый короткий стук ничего не включает,
/// он только взводит; включает второе нажатие, если оно пришло вовремя.
/// Для «держать и говорить» это привычный жест «стук, стук-и-держать».
private struct TapState {
  private(set) var active = false
  private var pressedAt: Date?
  private var armedAt: Date?

  /// Отдаёт true, когда «сочетание работает» изменилось на этом событии.
  mutating func update(raw: Bool, double: Bool, now: Date = Date()) -> Bool {
    guard raw != (pressedAt != nil) else { return false }

    if raw {
      pressedAt = now
      let armed = armedAt.map { now.timeIntervalSince($0) < doubleTapWindow } ?? false
      let on = double ? armed : true
      guard on != active else { return false }
      active = on
      return true
    }

    let held = now.timeIntervalSince(pressedAt ?? now)
    pressedAt = nil
    // Короткое нажатие, которое ничего не включило, — это первый стук.
    // Затянувшееся или уже сработавшее взводит не больше, чем один раз.
    armedAt = (!active && held < tapMaxHold) ? now : nil
    guard active else { return false }
    active = false
    return true
  }
}

// ── мост ────────────────────────────────────────────────────────────────────

final class DictationBridge: NSObject {
  static let shared = DictationBridge()

  /// Автозапуск — отдельный launch-агент, а не SMAppService.mainApp: агент
  /// запускает тот же бинарник, но с флагом --login-item в argv, и по нему
  /// AppDelegate узнаёт о входе в систему, не трогая Apple Event.
  private static let loginAgent = SMAppService.agent(
    plistName: "app.yuko.tsukiko.login-item.plist")

  /// Старая регистрация через SMAppService.mainApp (до перехода на
  /// launch-агента) указывает на путь внутри build/, который сносит
  /// flutter clean. Снимаем её один раз при обычном запуске, чтобы
  /// в системе не осталось мёртвой записи.
  static func retireStaleMainAppRegistration() {
    guard SMAppService.mainApp.status != .notRegistered else { return }
    DispatchQueue.global(qos: .utility).async {
      try? SMAppService.mainApp.unregister()
    }
  }

  private var channel: FlutterMethodChannel?
  private var engine: FlutterEngine?

  /// Тот же канал на движке главного окна. Обработчик один на приложение,
  /// но инспектор живёт в другом изоляте и до движка панели не достаёт.
  private var mainChannel: FlutterMethodChannel?

  private lazy var settings = SettingsWindow()

  /// Все живые каналы: настройки правит одно окно, а знать о правке
  /// должны все — у каждого своя копия в своём изоляте.
  private var channels: [FlutterMethodChannel] {
    [channel, mainChannel, settings.channel].compactMap { $0 }
  }

  private var hold = HotkeySpec()
  private var toggle = HotkeySpec()

  /// Состояние каждого сочетания: нажато ли оно и ждёт ли второго стука.
  private var holdState = TapState()
  private var toggleState = TapState()

  private var tap: CFMachPort?
  private var tapSource: CFRunLoopSource?

  /// Что зажато прямо сейчас и что мы поглотили как своё.
  private var heldKeys = Set<CGKeyCode>()
  private var swallowed = Set<CGKeyCode>()

  private var capturing = false

  /// Набранное за нынешний подход: пиковый набор модификаторов и все
  /// клавиши, которых коснулись, не отпуская остального.
  private var captureMods = Set<String>()
  private var captureKeys = Set<CGKeyCode>()
  private weak var captureChannel: FlutterMethodChannel?

  /// Когда начался нынешний подход и что набрано прошлым: короткий стук
  /// не отдаём сразу, а ждём, не повторят ли его, — иначе двойное
  /// нажатие назначить было бы нечем.
  private var captureStartedAt: Date?
  private var pendingCapture: (mods: Set<String>, keys: [String])?
  private var pendingTicket = 0

  private var recorder: AVAudioRecorder?
  private var recordURL: URL?

  /// Индикатор уровня: оценка фона комнаты, сглаженный уровень и время
  /// прошлого замера — сглаживание считается по нему, а не по вызовам.
  private var noiseFloorDb: Double?
  private var meterLevel: Double = 0
  private var meterAt: Date?

  private lazy var panel = PanelController()

  /// Плавающая панель записи. Отмена и остановка мышью — это те же
  /// два действия, что и с клавиатуры, поэтому уходят они в тот же Dart.
  private lazy var hud: RecordingHUD = {
    let hud = RecordingHUD(
      onCancel: { [weak self] in self?.channel?.invokeMethod("hud", arguments: "cancel") },
      onStop: { [weak self] in self?.channel?.invokeMethod("hud", arguments: "stop") },
      onAbort: { [weak self] in self?.channel?.invokeMethod("hud", arguments: "abort") })
    hud.levelSource = { [weak self] in self?.currentLevel() ?? 0 }
    return hud
  }()

  // MARK: запуск

  /// Позвать можно откуда угодно и сколько угодно раз: зовут из двух мест,
  /// потому что одно из них может не сработать (см. MainFlutterWindow).
  func start() {
    guard engine == nil else { return }
    let engine = FlutterEngine(
      name: "tsukiko-panel", project: nil, allowHeadlessExecution: true)
    engine.run(withEntrypoint: "panelMain")
    // macos_ui спрашивает у системы цвет выделения через свой плагин —
    // на незарегистрированном движке панель падала бы на первом кадре.
    RegisterGeneratedPlugins(registry: engine)
    self.engine = engine

    let channel = FlutterMethodChannel(
      name: "tsukiko/dictation", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, reply in
      self?.handle(call, reply, from: channel)
    }
    self.channel = channel

    panel.build(
      engine: engine,
      onShown: { [weak self] in
        self?.channel?.invokeMethod("panelShown", arguments: nil)
      },
      onHidden: { [weak self] in
        self?.channel?.invokeMethod("panelHidden", arguments: nil)
      })
    installTap()

    // Полтора гигабайта в памяти нельзя оставлять сиротой, а до
    // переопределений делегата приложения здесь не достучаться.
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      DictationBridge.killWhisperServer()
    }
  }

  /// Подключить тот же обработчик к движку главного окна: инспектор просит
  /// убрать значок из Dock, а его изолят движка панели не видит.
  func attach(messenger: FlutterBinaryMessenger) {
    let extra = FlutterMethodChannel(name: "tsukiko/dictation", binaryMessenger: messenger)
    extra.setMethodCallHandler { [weak self] call, reply in
      self?.handle(call, reply, from: extra)
    }
    mainChannel = extra
  }

  private func handle(
    _ call: FlutterMethodCall, _ reply: @escaping FlutterResult,
    from source: FlutterMethodChannel
  ) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "bind":
      hold = HotkeySpec(args?["hold"] as? [String: Any])
      toggle = HotkeySpec(args?["toggle"] as? [String: Any])
      // Защёлки относятся к прежним сочетаниям: с новыми они соврут
      // о том, что клавиша уже нажата.
      holdState = TapState()
      toggleState = TapState()
      swallowed = []
      reply(nil)
    case "capture":
      // Назначенное сочетание ждёт то окно, которое его попросило:
      // инспектор и панель живут на разных движках.
      captureChannel = source
      capturing = true
      captureMods = []
      captureKeys = []
      captureStartedAt = nil
      pendingCapture = nil
      pendingTicket += 1
      reply(nil)
    case "cancelCapture":
      capturing = false
      reply(nil)
    case "settingsChanged":
      // Настройки правит одно окно, а живут они в трёх изолятах: каждому
      // надо перечитать файл. Себе не шлём — правка пришла оттуда.
      for other in channels where other !== source {
        other.invokeMethod("reload", arguments: nil)
      }
      reply(nil)
    case "requestModel":
      // Спрашивает очередь, отвечает диктовка: только её изолят знает,
      // говорит ли человек прямо сейчас. Без панели отказывать некому.
      guard let panel = channel else {
        reply(true)
        return
      }
      panel.invokeMethod("yieldModel", arguments: nil, result: { answer in
        reply((answer as? Bool) ?? true)
      })
    case "openSettings":
      showSettings(tab: (args?["tab"] as? String) ?? "dictation")
      reply(nil)
    case "initialTab":
      reply(settings.tab)
    case "permissions":
      // Разрешение одно: «Универсальный доступ». Наш tap поглощает события
      // (fn+пробел не должен вставить пробел в чужое поле), а такому tap'у
      // «Мониторинга ввода» мало — macOS сводит ListenEvent к
      // Accessibility. Проверено: с одним «Универсальным доступом» tap
      // создаётся, без него — нет.
      ensureTap()
      reply(AXIsProcessTrusted())
    case "requestPermission":
      requestPermission()
      reply(nil)
    case "openPermissionSettings":
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        NSWorkspace.shared.open(url)
      }
      reply(nil)
    case "serverMarks":
      // Признаки «наш whisper-server» приходят из Dart: там они и живут
      // (ourServerMarks в lib/dictation.dart). Держать вторую копию здесь
      // значило бы разойтись с ней при первой же правке.
      if let marks = args?["marks"] as? [String], !marks.isEmpty {
        DictationBridge.serverMarks = marks
      }
      reply(nil)
    case "trash":
      // В Корзину, а не `unlink`: удаление записи должно оставаться
      // обратимым средствами самой системы.
      guard let path = args?["path"] as? String else {
        reply(false)
        return
      }
      NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
        if let error {
          NSLog("tsukiko: не удалось убрать в Корзину — \(error.localizedDescription)")
        }
        // Строго с главного потока: completion у recycle приходит с той
        // очереди, с какой ему удобно, а FlutterResult оттуда звать нельзя —
        // канал после этого перестаёт доставлять сообщения вовсе, и окно
        // молча каменеет.
        DispatchQueue.main.async { reply(error == nil) }
      }
    case "quit":
      NSApp.terminate(nil)
      reply(nil)
    case "record":
      startRecording(reply)
    case "stopRecord":
      reply(stopRecording())
    case "level":
      reply(currentLevel())
    case "paste":
      // Отвечаем настоящим результатом. Раньше здесь стояло `reply(true)`
      // всегда, и панель показывала «Готово» даже когда вставлять было
      // нечем и некуда: надиктованный текст пропадал вместе с буфером,
      // который через 0,4 с возвращался к прежнему содержимому.
      reply(paste((args?["text"] as? String) ?? ""))
    case "hud":
      switch (args?["state"] as? String) ?? "" {
      case "recording": hud.show()
      case "transcribing": hud.transcribing()
      case "done": hud.finish()
      case "failed": hud.failed()
      case "copied": hud.copied()
      case "cancelled": hud.cancelled()
      default: hud.hide()
      }
      reply(nil)
    case "openMainWindow":
      panel.hide()
      DictationBridge.showMainWindow()
      reply(nil)
    case "panelHeight":
      panel.setHeight(CGFloat((args?["height"] as? Double) ?? 0))
      reply(nil)
    case "dockIcon":
      NSApp.setActivationPolicy(
        (args?["visible"] as? Bool) ?? true ? .regular : .accessory)
      reply(nil)
    case "loginItem":
      // Состояние держит система, а не наш settings.json: автозапуск можно
      // выключить и в Системных настройках, и галка обязана это показывать.
      // Поэтому и на запись, и на чтение отвечает SMAppService.
      if let on = args?["enabled"] as? Bool {
        do {
          try on ? DictationBridge.loginAgent.register() : DictationBridge.loginAgent.unregister()
        } catch {
          NSLog("tsukiko: автозапуск не переключился — \(error.localizedDescription)")
        }
      }
      reply(DictationBridge.loginAgent.status == .enabled)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  /// Настройки из строки меню: ⌘, в меню приложения. Кроме этого пути
  /// туда ведут кнопка в инспекторе и пункт поповера — все три приходят
  /// в одно место.
  static func openSettings(tab: String) {
    shared.showSettings(tab: tab)
  }

  private func showSettings(tab: String) {
    settings.show(tab: tab) { [weak self] call, reply in
      guard let self, let channel = self.settings.channel else {
        reply(nil)
        return
      }
      self.handle(call, reply, from: channel)
    }
  }

  // MARK: разрешения

  /// Запрос и открытие настроек — разные действия, и делать их одним
  /// движением нельзя: системный диалог асинхронный, а Настройки, выйдя
  /// вперёд, хоронят его под собой. Пользователь ничего не отвечает,
  /// macOS не заводит запись — и приложения нет в списке, включать нечего.
  /// Поэтому диалог показываем сам по себе; в списке приложение появляется
  /// выключенным, а «Открыть настройки» — отдельная кнопка рядом.
  ///
  /// Показывается диалог один раз за жизнь записи TCC: если запись уже
  /// есть, остаётся только кнопка в настройки.
  private func requestPermission() {
    guard !AXIsProcessTrusted() else { return }
    AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
  }

  // MARK: перехват клавиш

  /// Без разрешения tap не создаётся вовсе. Раньше это значило «перезапустите
  /// приложение»: пробовали ровно один раз, на старте. Пробуем снова каждый
  /// раз, когда о разрешениях спрашивают, — а спрашивают, пока их нет.
  private func ensureTap() {
    guard tap == nil else { return }
    installTap()
  }

  private func installTap() {
    let mask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let me = Unmanaged<DictationBridge>.fromOpaque(refcon).takeUnretainedValue()
      return me.onEvent(type: type, event: event)
    }

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      NSLog("tsukiko: нет «Универсального доступа» — перехват клавиш не создан")
      // Диалог отсюда не показываем. На старте tapCreate не удаётся и при
      // выданном разрешении — процесс ещё не осел в системе, — а диалог
      // тогда всплывал каждый запуск у тех, кто всё давно разрешил.
      // В списке «Универсального доступа» приложение появляется от самого
      // обращения к нему, без всякого окна; спрашивать вслух будем только
      // по кнопке «Запросить».
      _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
      return
    }
    self.tap = tap
    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func onEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // Система отключает tap, если он однажды задумался дольше положенного.
    // Не включить его заново — значит потерять хоткей до перезапуска
    // приложения; именно этим и болеют соседние диктовки.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let mods = modNames(flags)
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

    // Что зажато прямо сейчас. Без этого «сочетание» ограничивалось одной
    // клавишей: набор X+Y отследить по одному событию нельзя.
    switch type {
    case .keyDown: heldKeys.insert(code)
    case .keyUp: heldKeys.remove(code)
    default: break
    }

    if capturing {
      return capture(type: type, mods: mods, code: code)
    }

    // Одно правило на все случаи: сочетание сработало, когда зажаты ровно
    // его модификаторы и ровно его клавиши. Раньше «модификаторы плюс
    // клавиша» и «одни модификаторы» разбирались двумя разными ветками.
    if holdState.update(raw: hold.pressed(mods, heldKeys), double: hold.isDouble) {
      send("hold", down: holdState.active)
    }

    // Отпускание само по себе ничего не переключает — оно лишь
    // разрешает следующему нажатию сработать.
    if toggleState.update(raw: toggle.pressed(mods, heldKeys), double: toggle.isDouble),
      toggleState.active
    {
      send("toggle", down: true)
    }

    // Свою клавишу поглощаем, чтобы буква не попала в чужое поле ввода.
    // Отпускание поглощаем по памяти: к этому моменту модификаторы могли
    // уже отпустить, и признак «наша» перестал бы совпадать.
    switch type {
    case .keyDown:
      if hold.claims(code, mods) || toggle.claims(code, mods) {
        swallowed.insert(code)
        return nil
      }
    case .keyUp:
      if swallowed.remove(code) != nil { return nil }
    default:
      break
    }

    // Модификаторы всегда пропускаем дальше: ⌃ и ⌘ нужны всей системе.
    return Unmanaged.passUnretained(event)
  }

  /// Назначение сочетания.
  ///
  /// Правило простое: пока клавиши держат, набор копится; отпустили всё —
  /// набранное и есть сочетание. Годится любая клавиша и любое их число,
  /// хоть «Y», хоть «X+Y», хоть «fn+O».
  ///
  /// Единственное ограничение — сочетание из одних модификаторов должно
  /// состоять хотя бы из двух: одна ⇧ или ⌘ срабатывала бы непрерывно
  /// и отняла бы модификатор у всей системы.
  ///
  /// Двойное нажатие назначается тем же стуком: набрали, отпустили быстро —
  /// ждём [doubleTapWindow], и если то же самое пришло второй раз, значит
  /// человек назначает двойное. Отдельной галочки для этого нет.
  private func capture(
    type: CGEventType, mods: Set<String>, code: CGKeyCode
  ) -> Unmanaged<CGEvent>? {
    if captureStartedAt == nil, !mods.isEmpty || type == .keyDown {
      captureStartedAt = Date()
    }

    switch type {
    case .keyDown:
      captureKeys.insert(code)
      captureMods.formUnion(mods)
      // Поглощаем: набираемая буква не должна попасть в чужое поле.
      return nil
    case .flagsChanged:
      captureMods.formUnion(mods)
    default:
      break
    }

    // Всё отпущено — сочетание набрано.
    guard heldKeys.isEmpty, mods.isEmpty, !captureKeys.isEmpty || captureMods.count >= 2
    else { return nil }

    let quick = Date().timeIntervalSince(captureStartedAt ?? Date()) < tapMaxHold
    let combo = (mods: captureMods, keys: captureKeys.map(keyName).sorted())
    captureKeys = []
    captureMods = []
    captureStartedAt = nil

    if let pending = pendingCapture, pending.mods == combo.mods, pending.keys == combo.keys {
      // Тот же набор во второй раз и вовремя — это двойное нажатие.
      finishCapture(combo.mods, combo.keys, taps: 2)
      return nil
    }

    guard quick else {
      finishCapture(combo.mods, combo.keys, taps: 1)
      return nil
    }

    // Короткий стук: ждём второго. Не дождались — назначаем одинарное.
    pendingCapture = combo
    pendingTicket += 1
    let ticket = pendingTicket
    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow) { [weak self] in
      guard let self, self.pendingTicket == ticket, let pending = self.pendingCapture
      else { return }
      self.finishCapture(pending.mods, pending.keys, taps: 1)
    }
    return nil
  }

  private func finishCapture(_ mods: Set<String>, _ keys: [String], taps: Int) {
    capturing = false
    pendingCapture = nil
    pendingTicket += 1
    sendCaptured(mods: mods, keys: keys, taps: taps)
  }

  private func send(_ id: String, down: Bool) {
    DispatchQueue.main.async {
      self.channel?.invokeMethod("hotkey", arguments: ["id": id, "down": down])
    }
  }

  private func sendCaptured(mods: Set<String>, keys: [String], taps: Int) {
    let target = captureChannel ?? channel
    DispatchQueue.main.async {
      target?.invokeMethod(
        "captured", arguments: ["mods": Array(mods), "keys": keys, "taps": taps])
    }
  }

  // MARK: запись

  private func startRecording(_ reply: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        guard granted else {
          reply(nil)
          return
        }
        reply(self.beginRecording())
      }
    }
  }

  /// Пишем сразу в 16 кГц моно 16 бит — ровно то, что читает whisper.
  /// Ни afconvert, ни ffmpeg на пути диктовки не нужны.
  private func beginRecording() -> String? {
    stopRecorder()
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tsukiko-\(UInt64(Date().timeIntervalSince1970 * 1000)).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
      return nil
    }
    rec.isMeteringEnabled = true
    guard rec.record() else { return nil }
    recorder = rec
    recordURL = url
    return url.path
  }

  private func stopRecording() -> String? {
    let url = recordURL
    stopRecorder()
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return url.path
  }

  private func stopRecorder() {
    recorder?.stop()
    recorder = nil
    // Комната у каждой записи своя: с оценкой фона от прошлого раза
    // индикатор первые секунды врал бы.
    noiseFloorDb = nil
    meterLevel = 0
    meterAt = nil
  }

  /// Уровень для индикатора. Считается один раз здесь: его берут и панель
  /// записи, и поповер, и опрашивают они с разной частотой — поэтому
  /// сглаживание идёт по времени, а не по числу вызовов.
  ///
  /// Это не AGC: усиление сигнала не трогаем, иначе крик и шёпот выглядели
  /// бы одинаково. Двигаем только точку отсчёта и берём окно под речь.
  private func currentLevel() -> Double {
    guard let rec = recorder, rec.isRecording else { return 0 }
    rec.updateMeters()
    // Ниже −60 дБ считать нечего: это уже не комната, а цифровая тишина,
    // и фон, уехавший туда, растянул бы шкалу до бессмыслицы.
    let db = max(-60, Double(rec.averagePower(forChannel: 0)))
    let now = Date()
    let dt = min(0.25, now.timeIntervalSince(meterAt ?? now.addingTimeInterval(-1.0 / 30)))
    meterAt = now

    // Фон комнаты: вниз оценка идёт быстро, вверх — медленно, а громче
    // порога — почти никак. Иначе речь сама поднимает фон, от которого её
    // же и отсчитывают, и индикатор оседает за несколько секунд разговора.
    let was = noiseFloorDb ?? db
    let floorTau = db < was ? 0.5 : (db < was + 6 ? 3 : 60)
    let floor = was + (db - was) * (1 - exp(-dt / floorTau))
    noiseFloorDb = floor

    // Окно под речь, а не под весь тракт. Замер этой машины: тишина −33 дБ,
    // речь −18 дБ — весь размах 15 дБ, и на наивной шкале −60…0 это 0,45
    // против 0,7, то есть стрелка почти не шевелится. Порог — 4 дБ над
    // фоном (дыхание и вентилятор остаются внизу), потолок — 22 дБ над ним,
    // но не ниже −14 дБ: в очень тихой комнате фон уезжает так низко, что
    // от него любая речь упиралась бы в верх шкалы. На замеренных числах
    // обычная речь занимает около 0,6, а крик доходит до единицы.
    let bottom = floor + 4
    let top = max(floor + 22, -14)
    let target = max(0, min(1, (db - bottom) / (top - bottom)))

    // Баллистика: атака 20 мс, спад 300 мс. Быстрее атака — метр дрожит,
    // короче спад — глаз не успевает за всплесками; 300 мс — время
    // интеграции обычного VU-метра, к нему привыкло восприятие.
    let tau = target > meterLevel ? 0.02 : 0.3
    meterLevel += (target - meterLevel) * (1 - exp(-dt / tau))
    return meterLevel
  }

  // MARK: вставка текста

  /// Буфер обмена — чужая вещь: положили своё, вставили, вернули как было.
  /// Сохраняем все типы данных, а не только строку, иначе скопированная
  /// картинка после диктовки превращалась бы в текст.
  ///
  /// Возвращает, дошло ли дело до нажатия ⌘V. False значит, что текст
  /// в чужое окно не попал, и вызывающая сторона обязана этим заняться:
  /// показать неудачу и оставить текст хотя бы в буфере обмена.
  @discardableResult
  private func paste(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    // Без «Универсального доступа» событие клавиши не доходит никуда.
    // Проверяем до того, как трогать буфер: иначе мы бы затёрли чужую
    // копию ради нажатия, которое всё равно не состоится.
    guard AXIsProcessTrusted() else { return false }
    let pb = NSPasteboard.general
    let saved: [[NSPasteboard.PasteboardType: Data]] =
      pb.pasteboardItems?.map { item in
        var bag = [NSPasteboard.PasteboardType: Data]()
        for type in item.types {
          if let data = item.data(forType: type) { bag[type] = data }
        }
        return bag
      } ?? []

    pb.clearContents()
    pb.setString(text, forType: .string)
    let sent = sendCommandV()

    // Вернуть буфер сразу нельзя: приложение-получатель читает его уже
    // после того, как ⌘V дошло до него. Если нажатие не состоялось,
    // возвращать нечего и ждать нечего — но и оставлять свой текст
    // в буфере правильно: вызывающая сторона на это и рассчитывает.
    guard sent else { return false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      pb.clearContents()
      guard !saved.isEmpty else { return }
      let items = saved.map { bag -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in bag { item.setData(data, forType: type) }
        return item
      }
      pb.writeObjects(items)
    }
    return true
  }

  /// Возвращает, удалось ли отправить нажатие. Молча провалиться здесь
  /// нельзя: это единственный способ текста попасть в чужое окно.
  @discardableResult
  private func sendCommandV() -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    // Пользователь мог ещё держать fn+ctrl. Флаги задаём явно, иначе
    // получатель увидит ⌃⌘V вместо ⌘V.
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
      state: .eventSuppressionStateSuppressionInterval)
    let v = keyCodes["v"]!
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
    else {
      NSLog("tsukiko: не удалось создать событие ⌘V — текст не вставлен")
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
    return true
  }

  // MARK: главное окно

  /// Политику активации здесь не трогаем: без значка в Dock приложение
  /// живёт в .accessory, и вернуть .regular значило бы отменять настройку
  /// каждым открытием окна. Окно в .accessory показывается и становится
  /// ключевым, но только после явной активации — сам по себе фоновый
  /// процесс на передний план не выходит.
  static func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
      window.makeKeyAndOrderFront(nil)
    }
  }

  /// Сервер держит в памяти полтора гигабайта — оставлять его сиротой
  /// нельзя. Ищем по метке в аргументах, а не по pid-файлу: файла может
  /// не оказаться (падение, kill -9), и тогда процесс не найти уже ничем.
  ///
  /// SIGTERM whisper-server переживает — проверено, поэтому следом идёт
  /// SIGKILL. Чужие whisper-server без нашей метки не трогаем.
  /// По каким признакам сервер считается нашим. Присылает Dart сразу после
  /// старта; до первого сообщения — запасной вариант на случай падения,
  /// не успевшего дойти до `setServerMarks`.
  static var serverMarks: [String] = [
    NSHomeDirectory() + "/Library/Application Support/app.yuko.tsukiko"
  ]

  static func killWhisperServer() {
    let marks = serverMarks

    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,args="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()

    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let text = String(line)
      guard text.contains("whisper-server"), marks.contains(where: text.contains),
        let first = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first,
        let pid = pid_t(first)
      else { continue }
      kill(pid, SIGTERM)
      usleep(150_000)
      if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
    try? FileManager.default.removeItem(
      atPath: NSHomeDirectory()
        + "/Library/Application Support/app.yuko.tsukiko/whisper-server.pid")
  }
}
