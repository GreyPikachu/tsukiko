import Cocoa
import FlutterMacOS

/// Поповер у строки меню: выезжает под значком, прячется при потере
/// фокуса. Внутри — второй движок Flutter, тот же, на котором работает
/// диктовка, поэтому панель показывает её состояние без всяких мостов
/// между изолятами.

// ── панель у строки меню ────────────────────────────────────────────────────

private final class TrayPanel: NSPanel {
  // Безрамочное окно по умолчанию не становится ключевым, и в нём
  // не работали бы ни щелчки, ни ввод.
  override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private var panel: TrayPanel?
  private var controller: FlutterViewController?
  private var onShown: (() -> Void)?

  private let size = NSSize(width: 320, height: 556)

  func build(engine: FlutterEngine, onShown: @escaping () -> Void) {
    self.onShown = onShown

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Свой силуэт вместо системного символа. Картинка шаблонная: чёрный
    // и альфа, всё остальное система рисует сама — под светлую и тёмную
    // строку меню и под выделение.
    if let icon = NSImage(named: "MenuBarIcon") {
      icon.isTemplate = true
      icon.accessibilityDescription = "tsukiko"
      item.button?.image = icon
    } else {
      // Без картинки и без заголовка кнопка нулевой ширины, и значка
      // в строке меню просто не видно.
      item.button?.title = "тс"
    }
    item.button?.target = self
    item.button?.action = #selector(clicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item

    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

    let panel = TrayPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.delegate = self
    panel.animationBehavior = .utilityWindow

    // Настоящий материал системы под содержимым: панель должна выглядеть
    // как поповер, а не как окно с закрашенным фоном.
    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true
    effect.autoresizingMask = [.width, .height]

    controller.view.frame = effect.bounds
    controller.view.autoresizingMask = [.width, .height]
    controller.backgroundColor = .clear
    effect.addSubview(controller.view)

    panel.contentView = effect
    self.panel = panel
    self.controller = controller
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    let rightClick = NSApp.currentEvent?.type == .rightMouseUp
    if rightClick {
      showMenu()
    } else if panel?.isVisible == true {
      hide()
    } else {
      show()
    }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "Открыть tsukiko", action: #selector(openMain), keyEquivalent: ""))
    menu.items.last?.target = self
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Завершить tsukiko", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  @objc private func openMain() {
    hide()
    DictationBridge.showMainWindow()
  }

  func show() {
    guard let panel, let button = statusItem?.button,
      let buttonWindow = button.window
    else { return }

    let anchor = buttonWindow.convertToScreen(button.frame)
    let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
    var x = anchor.midX - size.width / 2
    if let visible = screen?.visibleFrame {
      x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
    }
    let y = anchor.minY - size.height - 6

    // Появление: панель выезжает из-под иконки на несколько точек и
    // проявляется — то же движение, что у системных поповеров.
    // Пока панель ни разу не показывали, слой Flutter не имеет поверхности
    // для рисования. Задаём размер до появления, иначе первый показ пустой.
    panel.setFrame(NSRect(x: x, y: y + 8, width: size.width, height: size.height), display: false)
    if let content = panel.contentView, let view = controller?.view {
      view.frame = content.bounds
      content.layoutSubtreeIfNeeded()
    }
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      panel.animator().setFrame(
        NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
    onShown?()
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.12
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        panel.orderOut(nil)
      })
  }

  func windowDidResignKey(_ notification: Notification) {
    hide()
  }
}
