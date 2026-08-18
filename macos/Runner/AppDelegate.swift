import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Нас поднял вход в систему или человек руками. Флаг приходит через
  /// argv от launch-агента (Contents/Library/LaunchAgents), а не через
  /// чтение Apple Event — оно однажды забрало событие открытия у AppKit
  /// и вместе с ним значок в строке меню.
  static let launchedAtLogin = CommandLine.arguments.contains("--login-item")

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
