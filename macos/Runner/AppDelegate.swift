import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Запустила нас система при входе или человек руками. Спросить об этом
  /// можно только в самом начале запуска: событие открытия приходит один
  /// раз, и позже его уже не достать.
  static private(set) var launchedAtLogin = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    if let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication,
      let how = event.paramDescriptor(forKeyword: keyAEPropData)
    {
      AppDelegate.launchedAtLogin = how.enumCodeValue == keyAELaunchedAsLogInItem
    }
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
