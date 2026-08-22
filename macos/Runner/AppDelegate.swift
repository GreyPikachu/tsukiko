import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Нас поднял вход в систему или человек руками. Флаг приходит через
  /// argv от launch-агента (Contents/Library/LaunchAgents), а не через
  /// чтение Apple Event — оно однажды забрало событие открытия у AppKit
  /// и вместе с ним значок в строке меню.
  static let launchedAtLogin = CommandLine.arguments.contains("--login-item")

  /// Уже запущенная копия tsukiko, если она есть.
  ///
  /// Модель весит гигабайты, и двух копий в памяти быть не должно. Раньше
  /// вторая копия ловила это сама и показывала окно с надписью «tsukiko
  /// уже открыта» — тупик, из которого нельзя было даже добраться до первой
  /// копии. Теперь второй копии просто не бывает: она поднимает окно
  /// первой и завершается, как это делают все приложения macOS.
  ///
  /// Считается один раз: после `terminate` список процессов уже не тот,
  /// а ответ нужен и здесь, и в MainFlutterWindow.
  static let running: NSRunningApplication? = {
    guard let id = Bundle.main.bundleIdentifier else { return nil }
    let mine = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .first { $0.processIdentifier != mine }
  }()

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    guard let other = AppDelegate.running else { return }
    // Открытие через LaunchServices, а не `activate()`: первая копия могла
    // жить без значка в Dock и с закрытым окном — активировать там нечего.
    // Открытие приходит к ней как «запустили ещё раз», то есть в
    // applicationShouldHandleReopen, и окно показывается.
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(
      at: other.bundleURL ?? Bundle.main.bundleURL, configuration: config)
    NSApp.terminate(nil)
  }

  // Диктовка работает в фоне, поэтому закрытое окно больше не значит
  // «выйти»: приложение остаётся в строке меню.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// «Настройки…» в меню приложения. В шаблоне у этого пункта есть ⌘,
  /// и нет действия: сочетание, которое приложение обещает и в поповере,
  /// и в инспекторе, не делало ничего. Надпись стоит в xib, а действие
  /// назначается здесь: цель у пункта живая, из макета её не назначить.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if let item = NSApp.mainMenu?.items.first?.submenu?.items
      .first(where: { $0.keyEquivalent == "," })
    {
      item.target = self
      item.action = #selector(openSettings)
    }
  }

  @objc private func openSettings() {
    DictationBridge.openSettings(tab: "dictation")
  }

  // Щелчок по значку в Dock, когда все окна закрыты.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { DictationBridge.showMainWindow() }
    return true
  }
}
