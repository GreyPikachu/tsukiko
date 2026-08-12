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

  private var hold = HotkeySpec()
  private var toggle = HotkeySpec()
  private var holdDown = false

  private var tap: CFMachPort?
  private var tapSource: CFRunLoopSource?

  private var capturing = false
  private var capturePeak = Set<String>()

  private var recorder: AVAudioRecorder?
  private var recordURL: URL?

  private lazy var panel = PanelController()

  // MARK: запуск

  func start() {
    let engine = FlutterEngine(
      name: "tsukiko-panel", project: nil, allowHeadlessExecution: true)
    engine.run(withEntrypoint: "panelMain")
    // macos_ui спрашивает у системы цвет выделения через свой плагин —
    // на незарегистрированном движке панель падала бы на первом кадре.
    RegisterGeneratedPlugins(registry: engine)
    self.engine = engine

    channel = FlutterMethodChannel(
      name: "tsukiko/dictation", binaryMessenger: engine.binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, reply in
      self?.handle(call, reply)
    }

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

  private func handle(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "bind":
      hold = HotkeySpec(args?["hold"] as? [String: Any])
      toggle = HotkeySpec(args?["toggle"] as? [String: Any])
      reply(nil)
    case "capture":
      capturing = true
      capturePeak = []
      reply(nil)
    case "cancelCapture":
      capturing = false
      reply(nil)
    case "accessibility":
      // Именно эта пара отвечает за перехват клавиш. AXIsProcessTrusted
      // отвечает про другое разрешение и на выданном доступе врёт «нет».
      if (args?["prompt"] as? Bool) ?? false, !CGPreflightListenEventAccess() {
        CGRequestListenEventAccess()
      }
      reply(CGPreflightListenEventAccess())
    case "record":
      startRecording(reply)
    case "stopRecord":
      reply(stopRecording())
    case "level":
      reply(currentLevel())
    case "paste":
      paste((args?["text"] as? String) ?? "")
      reply(true)
    case "hidePanel":
      panel.hide()
      reply(nil)
    case "openMainWindow":
      panel.hide()
      DictationBridge.showMainWindow()
      reply(nil)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  // MARK: перехват клавиш

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
      NSLog("tsukiko: не удалось создать event tap — нет «Универсального доступа»")
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
    DispatchQueue.main.async {
      self.channel?.invokeMethod(
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
  }

  private func currentLevel() -> Double {
    guard let rec = recorder, rec.isRecording else { return 0 }
    rec.updateMeters()
    let db = Double(rec.averagePower(forChannel: 0))
    // −60 дБ — тишина, 0 дБ — предел. Ниже порога индикатор просто спит.
    return max(0, min(1, (db + 60) / 60))
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

  static func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
      window.makeKeyAndOrderFront(nil)
    }
  }

  /// Сервер держит в памяти полтора гигабайта — оставлять его сиротой
  /// нельзя. Dart пишет pid на диск специально ради этой минуты.
  static func killWhisperServer() {
    let path = NSHomeDirectory()
      + "/Library/Application Support/app.yuko.tsukiko/whisper-server.pid"
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
      let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return }
    kill(pid, SIGTERM)
    try? FileManager.default.removeItem(atPath: path)
  }
}
