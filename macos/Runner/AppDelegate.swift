import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Диктовка работает в фоне, поэтому закрытое окно больше не значит
  // «выйти»: приложение остаётся в строке меню.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Щелчок по значку в Dock, когда все окна закрыты.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { DictationBridge.showMainWindow() }
    return true
  }
}
