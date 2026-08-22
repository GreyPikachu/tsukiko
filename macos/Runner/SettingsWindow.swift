import Cocoa
import FlutterMacOS

/// Окно настроек: обычное окно macOS со своим движком Flutter.
///
/// Движок третий — после главного окна и панели у строки меню. Иначе
/// не выходит: движок отдаёт свой вид одному окну, а те два свои уже
/// заняли. Создаётся он при первом открытии, а не на старте, — кто
/// в настройки не заходит, за них и не платит.
final class SettingsWindow: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var engine: FlutterEngine?
  private(set) var channel: FlutterMethodChannel?

  /// Канал жизненного цикла этого движка.
  ///
  /// Главное окно ведёт плагин, а это — обычное NSWindow со своим движком,
  /// и состояние жизненного цикла ему никто не возвращает: стоит окну
  /// потерять фокус (открылся Finder, ушли в другую программу), Flutter
  /// останавливает конвейер кадров — и больше не запускает. Окно после
  /// этого живо, но не рисуется и не отвечает на нажатия.
  ///
  /// Поэтому состояние досылаем сами по ключевому статусу окна. Если
  /// движок дошлёт своё — ничего не случится, сообщение то же самое.
  private var lifecycle: FlutterBasicMessageChannel?

  private func setLifecycle(_ state: String) {
    lifecycle?.sendMessage("AppLifecycleState.\(state)")
  }

  func windowDidBecomeKey(_ notification: Notification) {
    setLifecycle("resumed")
  }

  func windowDidResignKey(_ notification: Notification) {
    setLifecycle("inactive")
  }

  /// Вкладка, которую попросили открыть. Dart спрашивает её сам: до того
  /// как его изолят подпишется на канал, посланное ему сообщение теряется.
  private(set) var tab = "dictation"

  /// Окно закрыли — движок остаётся жить: он держит около ста мегабайт,
  /// а повторное открытие тогда мгновенное.
  // engine kept alive after close; выгружать его есть смысл
  // только если эти сто мегабайт станут заметны рядом с моделью.
  func show(tab: String, handler: @escaping FlutterMethodCallHandler) {
    self.tab = tab
    if window == nil {
      // allowHeadlessExecution обязателен: без него run(withEntrypoint:)
      // движок не запускает — тот ждёт вид, а подключённый вид стартует его
      // уже точкой входа по умолчанию. Окно настроек показывало содержимое
      // главного окна именно поэтому.
      let engine = FlutterEngine(
        name: "tsukiko-settings", project: nil, allowHeadlessExecution: true)
      engine.run(withEntrypoint: "settingsMain")
      RegisterGeneratedPlugins(registry: engine)
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false)
      window.title = "Настройки"
      window.contentViewController = controller
      // contentViewController перекраивает окно под свой вид, а вид Flutter
      // на этот момент ещё нулевой: окно схлопывалось в 0×32 — в одну
      // титульную полосу — и настройки просто не открывались. Размер задаём
      // после присваивания, иначе contentRect выше не значит ничего.
      window.setContentSize(NSSize(width: 580, height: 560))
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()

      let channel = FlutterMethodChannel(
        name: "tsukiko/dictation", binaryMessenger: engine.binaryMessenger)
      channel.setMethodCallHandler(handler)

      lifecycle = FlutterBasicMessageChannel(
        name: "flutter/lifecycle",
        binaryMessenger: engine.binaryMessenger,
        codec: FlutterStringCodec.sharedInstance())

      self.engine = engine
      self.channel = channel
      self.window = window
    } else {
      // Окно уже открыто: сообщение о вкладке дойдёт — изолят подписан.
      channel?.invokeMethod("tab", arguments: tab)
    }
    // Без значка в Dock приложение живёт в .accessory и само на передний
    // план не выходит — окно осталось бы за чужими.
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    setLifecycle("resumed")
  }
}
