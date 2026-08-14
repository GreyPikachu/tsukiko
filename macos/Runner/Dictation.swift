import AVFoundation
import Cocoa
import FlutterMacOS

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

/// Функциональные клавиши можно назначать в одиночку, обычные — нет:
/// «q» без модификаторов отобрала бы у пользователя букву.
private func standaloneAllowed(_ code: CGKeyCode) -> Bool {
  guard let name = keyNames[code] else { return false }
  return name.hasPrefix("f") && name.count > 1 && Int(name.dropFirst()) != nil
}

private struct HotkeySpec {
  var mods = Set<String>()
  var key: CGKeyCode?

  var isEmpty: Bool { mods.isEmpty && key == nil }

  init() {}

  init(_ raw: [String: Any]?) {
    guard let raw else { return }
    mods = Set((raw["mods"] as? [String]) ?? [])
    if let name = raw["key"] as? String { key = keyCodes[name] }
  }

  /// Совпадение строгое: fn+ctrl не должно срабатывать на fn+ctrl+cmd,
  /// иначе диктовка вклинивалась бы в чужие сочетания.
  func matches(_ flags: CGEventFlags, code: CGKeyCode?) -> Bool {
    if isEmpty { return false }
    guard modNames(flags) == mods else { return false }
    return key == code
  }
}

// ── мост ────────────────────────────────────────────────────────────────────

final class DictationBridge: NSObject {
  static let shared = DictationBridge()

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
  private var holdDown = false

  private var tap: CFMachPort?
  private var tapSource: CFRunLoopSource?

  private var capturing = false
  private var capturePeak = Set<String>()
  private weak var captureChannel: FlutterMethodChannel?

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
      onStop: { [weak self] in self?.channel?.invokeMethod("hud", arguments: "stop") })
    hud.levelSource = { [weak self] in self?.currentLevel() ?? 0 }
    return hud
  }()

  // MARK: запуск

  func start() {
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

    panel.build(engine: engine) { [weak self] in
      self?.channel?.invokeMethod("panelShown", arguments: nil)
    }
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
      reply(nil)
    case "capture":
      // Назначенное сочетание ждёт то окно, которое его попросило:
      // инспектор и панель живут на разных движках.
      captureChannel = source
      capturing = true
      capturePeak = []
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
      paste((args?["text"] as? String) ?? "")
      reply(true)
    case "hud":
      switch (args?["state"] as? String) ?? "" {
      case "recording": hud.show()
      case "transcribing": hud.transcribing()
      case "done": hud.finish()
      case "failed": hud.failed()
      default: hud.hide()
      }
      reply(nil)
    case "hidePanel":
      panel.hide()
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
    default:
      reply(FlutterMethodNotImplemented)
    }
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

    if capturing {
      return capture(type: type, event: event, mods: mods, code: code)
    }

    switch type {
    case .keyDown:
      if toggle.matches(flags, code: code) {
        send("toggle", down: true)
        return nil  // иначе fn+пробел вставит пробел в чужое поле
      }
      if hold.key != nil, hold.matches(flags, code: code) {
        if !holdDown {
          holdDown = true
          send("hold", down: true)
        }
        return nil
      }
    case .keyUp:
      if hold.key != nil, holdDown, code == hold.key {
        holdDown = false
        send("hold", down: false)
        return nil
      }
    case .flagsChanged:
      // Сочетания из одних модификаторов обычной клавиши не имеют:
      // отследить их можно только по смене набора флагов.
      if hold.key == nil, !hold.isEmpty {
        let now = mods == hold.mods
        if now, !holdDown {
          holdDown = true
          send("hold", down: true)
        } else if !now, holdDown {
          holdDown = false
          send("hold", down: false)
        }
      }
      if toggle.key == nil, !toggle.isEmpty, mods == toggle.mods {
        send("toggle", down: true)
      }
    default:
      break
    }
    // Модификаторы всегда пропускаем дальше: ⌃ и ⌘ нужны всей системе.
    return Unmanaged.passUnretained(event)
  }

  /// Назначение сочетания. Модификаторы копятся, пока их держат, и
  /// отдаются, когда отпустили, — иначе «fn+ctrl» записалось бы как «fn».
  private func capture(
    type: CGEventType, event: CGEvent, mods: Set<String>, code: CGKeyCode
  ) -> Unmanaged<CGEvent>? {
    switch type {
    case .keyDown:
      guard !mods.isEmpty || standaloneAllowed(code) else {
        return Unmanaged.passUnretained(event)
      }
      capturing = false
      sendCaptured(mods: mods, key: keyNames[code])
      return nil
    case .flagsChanged:
      if mods.count > capturePeak.count { capturePeak = mods }
      if mods.isEmpty, capturePeak.count >= 2 {
        capturing = false
        sendCaptured(mods: capturePeak, key: nil)
      }
      return Unmanaged.passUnretained(event)
    default:
      return nil
    }
  }

  private func send(_ id: String, down: Bool) {
    DispatchQueue.main.async {
      self.channel?.invokeMethod("hotkey", arguments: ["id": id, "down": down])
    }
  }

  private func sendCaptured(mods: Set<String>, key: String?) {
    let target = captureChannel ?? channel
    DispatchQueue.main.async {
      target?.invokeMethod(
        "captured", arguments: ["mods": Array(mods), "key": key as Any])
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
  private func paste(_ text: String) {
    guard !text.isEmpty else { return }
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
    sendCommandV()

    // Вернуть буфер сразу нельзя: приложение-получатель читает его уже
    // после того, как ⌘V дошло до него.
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
  }

  private func sendCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    // Пользователь мог ещё держать fn+ctrl. Флаги задаём явно, иначе
    // получатель увидит ⌃⌘V вместо ⌘V.
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
      state: .eventSuppressionStateSuppressionInterval)
    let v = keyCodes["v"]!
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
    else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
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
  static func killWhisperServer() {
    let support = NSHomeDirectory() + "/Library/Application Support/app.yuko.tsukiko"
    let marks = ["/tmp/tsukiko-whisper", support]

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
    try? FileManager.default.removeItem(atPath: support + "/whisper-server.pid")
  }
}
