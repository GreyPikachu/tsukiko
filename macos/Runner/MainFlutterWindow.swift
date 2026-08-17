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

    // Инспектор тоже говорит с прослойкой — например, чтобы убрать значок
    // из Dock. Своего движка у него нет общего с панелью, поэтому канал
    // вешаем и сюда.
    DictationBridge.shared.attach(
      messenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    self.title = "tsukiko"

    // Окно можно закрыть и открыть заново из строки меню — значит его
    // нельзя освобождать при закрытии.
    self.isReleasedWhenClosed = false

    // Три панели (очередь · текст · настройки) в 800×600 не помещаются.
    self.minSize = NSSize(width: 900, height: 560)
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.center()

    // Переопределения жизненного цикла в наследнике FlutterAppDelegate
    // до нас не доходят, поэтому подписываемся на уведомление сами.
    // Раньше запуска приложения нельзя: значок в строке меню, созданный
    // до него, система не рисует.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { _ in
      DictationBridge.shared.start()
    }

    // Уведомление могло уже пройти: awakeFromNib окна и запуск приложения
    // идут в порядке, который нам не принадлежит, а опоздавший наблюдатель
    // не срабатывает никогда — значка в строке меню тогда нет вовсе, и
    // диктовки вместе с ним. Просим ещё и следующим витком цикла событий:
    // он всё равно наступает после запуска, а start() идемпотентен.
    DispatchQueue.main.async { DictationBridge.shared.start() }
  }
}
