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

  /// Вкладка, которую попросили открыть. Dart спрашивает её сам: до того
  /// как его изолят подпишется на канал, посланное ему сообщение теряется.
  private(set) var tab = "dictation"

  /// Окно закрыли — движок остаётся жить: он держит около сорока мегабайт,
  /// а повторное открытие тогда мгновенное.
  // engine kept alive after close; выгружать его есть смысл
  // только если эти сорок мегабайт станут заметны рядом с моделью.
  func show(tab: String, handler: @escaping FlutterMethodCallHandler) {
    self.tab = tab
    if window == nil {
      let engine = FlutterEngine(
        name: "tsukiko-settings", project: nil, allowHeadlessExecution: false)
      engine.run(withEntrypoint: "settingsMain")
      RegisterGeneratedPlugins(registry: engine)
      let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false)
      window.title = "Настройки"
      window.contentViewController = controller
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()

      let channel = FlutterMethodChannel(
        name: "tsukiko/dictation", binaryMessenger: engine.binaryMessenger)
      channel.setMethodCallHandler(handler)

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
  }
}
