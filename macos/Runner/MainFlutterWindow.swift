import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    // Без этой строки окно не показывается вовсе: MacosWindowUtilsConfig
    // из Dart ожидает, что окном управляет плагин.
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)

    super.awakeFromNib()

    self.title = "tsukiko"

    // Три панели (очередь · текст · настройки) в 800×600 не помещаются.
    self.minSize = NSSize(width: 900, height: 560)
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.center()
  }
}
