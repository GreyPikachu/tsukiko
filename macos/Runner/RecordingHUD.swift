import Cocoa
import SwiftUI

/// Плавающая панель записи. Она отвечает на единственный вопрос —
/// «система меня слышит и работает?» — и уходит, как только ответила.
///
/// Своё окно, а не поповер из трея: у них разные задачи. Поповер —
/// настройки, которые открывают намеренно; эта панель приходит сама
/// и не должна ни забирать фокус, ни закрывать собой работу.
///
/// Пружины те же, что в lib/design.dart: Motion.settle — отклик 0,4 с
/// без перелёта, Motion.toss — 0,3 с с затуханием 0,72. Появление
/// перелёта не имеет: жеста, который нёс бы импульс, здесь не было.

enum HUDState: String {
  case hidden, recording, transcribing, done, failed, copied, cancelled, silent
}

final class HUDModel: ObservableObject {
  @Published var state: HUDState = .hidden
  @Published var pending = 0
  @Published var processing = false
  var onClearQueue: () -> Void = {}
  var onRecord: () -> Void = {}
  @Published var editing = false
  @Published var scale: Double = 1
  var onMove: (CGSize, Bool) -> Void = { _, _ in }
  var onScale: (Double) -> Void = { _ in }
  var onFinish: (Bool) -> Void = { _ in }
  var onReset: () -> Void = {}
  var labels: [String: String] = [:]
  func label(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }

  @Published var elapsed: TimeInterval = 0

  /// История уровня: полоски бегут справа налево, как настоящий сигнал.
  @Published var levels: [Double] = Array(repeating: 0, count: 22)

  var onCancel: () -> Void = {}
  var onStop: () -> Void = {}

  /// Прервать распознавание. Отдельно от [onCancel]: та отменяет запись,
  /// эта — уже идущий счёт модели.
  var onAbort: () -> Void = {}

  func push(level: Double) {
    levels.removeFirst()
    levels.append(level)
  }
}

struct HUDView: View {
  @ObservedObject var model: HUDModel

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private var time: String {
    let total = Int(model.elapsed)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  var body: some View {
    VStack(spacing: 8) {
      if model.editing {
        Text(model.label("title", "Положение плашки"))
          .font(.system(size: 14, weight: .semibold))
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 3)
            .onChanged { model.onMove($0.translation, false) }
            .onEnded { model.onMove($0.translation, true) })
        Text(model.label("hint", "Перетащите за полоски · центр экрана притягивает плашку"))
          .font(.system(size: 11)).foregroundColor(.secondary)
      }
      HStack(spacing: 12) {
      switch model.state {
      case .transcribing:
        Spinner().contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 3)
            .onChanged { model.onMove($0.translation, false) }
            .onEnded { model.onMove($0.translation, true) })
        Text("Распознаю…")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
        // Часовая запись считается минутами, и до этого выйти было нельзя
        // ничем, кроме выхода из приложения. Крестик рядом с прогрессом —
        // то же, чем отменяют загрузку в Safari и копирование в Finder:
        // знакомый жест, который не нужно объяснять. Он у самого правого
        // края — там же, где кончались кнопки записи, поэтому при смене
        // фазы панель не перекраивается.
        AbortButton(action: model.onAbort)
      case .cancelled:
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 15))
          .foregroundColor(.secondary)
        Text("Отменено · запись сохранена")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      case .done:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 15))
          .foregroundColor(.green)
        Text("Готово")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      case .failed:
        // Молча исчезнуть после неудачи — значит соврать, что всё в порядке.
        // Подробности и путь к сохранённой записи ждут в панели диктовки.
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 15))
          .foregroundColor(.orange)
        Text("Не распознано · запись сохранена")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      case .silent:
        // Записывать было нечего: клавишу отпустили раньше, чем микрофон
        // отдал первый отсчёт. Молча уйти здесь нельзя — это читалось бы
        // как «всё получилось», — а «не вставилось» было бы неправдой.
        Image(systemName: "mic.slash")
          .font(.system(size: 15))
          .foregroundColor(.secondary)
        Text("Ничего не записалось")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      case .copied:
        // Текст распознан, но в чужое окно не попал. Молчать здесь тоже
        // нельзя: человек ждёт слов там, где стоит курсор, и не узнает,
        // что они лежат в буфере обмена.
        Image(systemName: "doc.on.clipboard")
          .font(.system(size: 15))
          .foregroundColor(.orange)
        Text("Не вставилось · текст в буфере, ⌘V")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      default:
        Meter(levels: model.levels, reduceMotion: reduceMotion)
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 3)
            .onChanged { model.onMove($0.translation, false) }
            .onEnded { model.onMove($0.translation, true) })
          .help(model.label("drag", "Переместить плашку"))
          .accessibilityLabel(model.label("drag", "Переместить плашку"))
        Text(model.editing ? model.label("drag", "Переместить плашку") : time)
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .lineLimit(1)
          .fixedSize()
          .foregroundColor(.primary)
        Spacer(minLength: 0)
        if !model.editing {
          HUDButton(title: "Отменить", filled: false, action: model.onCancel)
          HUDButton(title: "Остановить", filled: true, action: model.onStop)
        }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if !model.editing && (model.pending > 0 || model.processing) {
        Menu {
          Text(model.label("queueTitle", "В очереди: \(model.pending)"))
          if model.state != .recording { Button(model.label("record", "Записать следующую"), action: model.onRecord) }
          if model.processing { Button(model.label("abort", "Отменить текущую расшифровку"), action: model.onAbort) }
          if model.pending > 0 { Button(model.label("clearQueue", "Убрать ожидающие · сохранить записи"), action: model.onClearQueue) }
        } label: {
          Text("\(model.pending + (model.processing ? 1 : 0))")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(4).background(Capsule().fill(Color.accentColor.opacity(0.16)))
        }
        .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 4)
        .accessibilityLabel("Очередь диктовок")
      }
    }
    // Поля шире, чем кажется нужным: содержимое, прижатое к скруглённому
    // краю, читается теснее, чем стоит на самом деле. Ширина панели растёт
    // на ту же величину, чтобы поля не съели место у кнопок.
    // Двадцать, а не двадцать два: шаг сетки во всём приложении — четыре.
    .padding(.horizontal, 20)
    .frame(height: 52)
      if model.editing {
        HStack(spacing: 10) {
          Text(model.label("scale", "Масштаб"))
          Slider(value: Binding(get: { model.scale }, set: model.onScale), in: 0.8...1.6, step: 0.1)
            .frame(width: 110).accessibilityLabel(model.label("scale", "Масштаб"))
          Text("\(Int(model.scale * 100))%").monospacedDigit().frame(width: 40)
          Button(model.label("reset", "Сбросить"), action: model.onReset).fixedSize()
          Button(model.label("cancel", "Отменить")) { model.onFinish(false) }.keyboardShortcut(.cancelAction).fixedSize()
          Button(model.label("save", "Сохранить")) { model.onFinish(true) }.keyboardShortcut(.defaultAction).fixedSize()
        }.font(.system(size: 11)).padding(.horizontal, 12)
      }
    }
    .frame(width: model.editing ? 600 : 372, height: model.editing ? 156 : 52)
    .scaleEffect(model.scale)
    .frame(width: (model.editing ? 600 : 372) * model.scale,
           height: (model.editing ? 156 : 52) * model.scale)
    // Отклик 0,25, а не 0,4: смену состояния человек вызвал сам, нажав
    // «Остановить», и ждать почти полсекунды, пока надпись доедет,
    // читается как задумчивость приложения. 0,4 — это для перемещений,
    // которые случаются сами.
    .animation(
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 1),
      value: model.state)
  }
}

/// Уровень сигнала полосками. Это не украшение: пока они шевелятся,
/// видно, что микрофон действительно слышит, а не пишет тишину.
private struct Meter: View {
  let levels: [Double]
  let reduceMotion: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule()
          .fill(Color.primary.opacity(0.55))
          .frame(width: 2.5, height: max(2.5, level * 24))
      }
    }
    .frame(width: 100, height: 26, alignment: .center)
    .animation(
      reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 1), value: levels)
  }
}

/// Неопределённый прогресс: длительность распознавания заранее
/// неизвестна, а показывать выдуманную шкалу — врать.
private struct Spinner: View {
  @State private var spin = false

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.7)
      .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      .frame(width: 14, height: 14)
      .rotationEffect(.degrees(spin ? 360 : 0))
      .onAppear {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
          spin = true
        }
      }
  }
}

/// Крестик отмены. Не кнопка с подписью: действие редкое, и громкая
/// кнопка рядом с «Распознаю…» читалась бы как основное намерение.
/// В покое он приглушён, под курсором проявляется вместе с круглой
/// подложкой — есть, когда его ищут, и молчит, когда не нужен.
private struct AbortButton: View {
  let action: () -> Void

  @State private var hover = false
  @State private var pressed = false

  var body: some View {
    Image(systemName: "xmark")
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.primary.opacity(hover ? 0.9 : 0.4))
      .frame(width: 22, height: 22)
      .background(
        Circle().fill(Color.primary.opacity(hover ? 0.08 : 0))
      )
      .contentShape(Circle())
      // Отклик на нажатие, а не на отпускании: задержка убивает
      // ощущение прямоты — то же правило, что у HUDButton.
      .scaleEffect(pressed ? 0.94 : 1)
      .animation(.easeOut(duration: 0.09), value: pressed)
      .animation(.easeOut(duration: 0.12), value: hover)
      .onHover { hover = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in pressed = true }
          .onEnded { value in
            pressed = false
            // Ушли с кнопки, не отпустив, — действие отменяется.
            let inside = abs(value.translation.width) < 20 && abs(value.translation.height) < 20
            if inside { action() }
          }
      )
      .help("Отменить распознавание")
      .accessibilityLabel("Отменить распознавание")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { action() }
  }
}

private struct HUDButton: View {
  let title: String
  let filled: Bool
  let action: () -> Void

  @State private var pressed = false
  @State private var hover = false

  var body: some View {
    Text(title)
      .font(.system(size: 12))
      .lineLimit(1)
      .fixedSize()
      .foregroundColor(filled ? .white : .primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(background)
      )
      // Подсветка на нажатии, а не на отпускании: задержка убивает
      // ощущение прямоты.
      .scaleEffect(pressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.09), value: pressed)
      .onHover { hover = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in pressed = true }
          .onEnded { value in
            pressed = false
            // Ушли с кнопки, не отпустив, — действие отменяется.
            let inside = abs(value.translation.width) < 24 && abs(value.translation.height) < 20
            if inside { action() }
          }
      )
  }

  private var background: Color {
    if filled {
      return Color.accentColor.opacity(hover ? 0.9 : 1)
    }
    return Color.primary.opacity(pressed ? 0.16 : hover ? 0.1 : 0.06)
  }
}

// ── окно ────────────────────────────────────────────────────────────────────

/// Панель не становится ключевой ни при каких условиях: заберёт фокус —
/// уйдёт из поля ввода, куда мы собираемся вставлять текст, и вставка
/// сломается целиком.
private final class HUDPanel: NSPanel {
  var editingEnabled = false
  override var canBecomeKey: Bool { editingEnabled }
  override var canBecomeMain: Bool { false }
}

final class RecordingHUD {
  private var panel: HUDPanel?
  private let model = HUDModel()
  private var ticker: Timer?
  private var startedAt: Date?
  private var hideAfterDone: Timer?

  /// Номер нынешнего показа. Уход панели — анимация в четверть секунды, и
  /// панель прячется не сразу, а в её обработчике завершения. Если за эту
  /// четверть секунды человек начал говорить снова, обработчик прежнего
  /// ухода всё равно доигрывал своё и убирал панель с экрана — уже поверх
  /// начатой записи. Со стороны это и есть «панель просто не появилась»:
  /// она появлялась и в ту же долю секунды исчезала, а исчезнув, обратно
  /// сама не приходила. Номер отличает свой уход от чужого.
  private var showNumber = 0
  private var hiding = false

  private var size: NSSize {
    NSSize(width: (model.editing ? 600 : 372) * model.scale,
           height: (model.editing ? 156 : 52) * model.scale)
  }
  private let defaults: UserDefaults
  var currentPlacement: HUDPlacement { placement }
  var isEditing: Bool { model.editing }
  var isVisible: Bool { panel?.isVisible == true }
  private let placementKey = "dictationHUDPlacement"
  private var placement = HUDPlacement()
  private var savedPlacement = HUDPlacement()
  private var dragOrigin: NSPoint?
  private var dragPointer: NSPoint?
  private weak var previousKeyWindow: NSWindow?
  private var keyMonitor: Any?
  private var layoutScreen: NSScreen?
  private var guides: NSPanel?
  private var visibleBeforeEditing = false
  private var stateBeforeEditing: HUDState = .hidden

  /// Откуда брать уровень сигнала — рекордер живёт в мосте.
  var levelSource: () -> Double = { 0 }

  init(
    onCancel: @escaping () -> Void, onStop: @escaping () -> Void,
    onAbort: @escaping () -> Void, onClearQueue: @escaping () -> Void,
    onRecord: @escaping () -> Void, defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    model.onCancel = onCancel
    model.onStop = onStop
    model.onAbort = onAbort
    model.onClearQueue = onClearQueue
    model.onRecord = onRecord
    if let saved = defaults.dictionary(forKey: placementKey) {
      placement = HUDPlacement(x: saved["x"] as? Double, y: saved["y"] as? Double,
                               scale: saved["scale"] as? Double ?? 1)
    }
    model.scale = placement.scale
    model.onMove = { [weak self] offset, ended in self?.move(offset, ended: ended) }
    model.onScale = { [weak self] scale in self?.setScale(scale) }
    model.onReset = { [weak self] in self?.resetPosition() }
    model.onFinish = { [weak self] save in self?.finishEditing(save: save) }
  }

  private func build() -> HUDPanel {
    if let panel { return panel }

    let panel = HUDPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = false
    // Панель принадлежит не окну, а моменту: она нужна на любом рабочем
    // столе, в том числе поверх чужого полноэкранного окна.
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
    ]

    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 14
    effect.layer?.masksToBounds = true
    effect.autoresizingMask = [.width, .height]

    let host = NSHostingView(rootView: HUDView(model: model))
    host.frame = effect.bounds
    host.autoresizingMask = [.width, .height]
    effect.addSubview(host)

    panel.contentView = effect
    self.panel = panel
    return panel
  }

  /// Экран, на котором сейчас работают, — тот, где указатель.
  ///
  /// `NSScreen.main` для этого не годится: он отвечает про экран с ключевым
  /// окном, а ключевого окна у нас нет вовсе — панель нарочно не берёт
  /// фокус. На одном мониторе разницы нет, на двух панель уезжала
  /// на соседний, то есть «не появлялась» и там, где на неё смотрят.
  private var currentScreen: NSScreen? {
    if let layoutScreen, NSScreen.screens.contains(layoutScreen) { return layoutScreen }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens.first
  }

  private var workArea: NSRect {
    let screen = currentScreen
    return screen.map { $0.visibleFrame.height > 0 ? $0.visibleFrame : $0.frame } ?? .zero
  }

  private var restingOrigin: NSPoint { placement.origin(in: workArea, size: size) }

  private func persist() {
    var saved: [String: Double] = ["scale": placement.scale]
    if let x = placement.x, let y = placement.y { saved["x"] = x; saved["y"] = y }
    defaults.set(saved, forKey: placementKey)
  }

  private func resize() {
    let panel = build()
    panel.setFrame(NSRect(origin: restingOrigin, size: size), display: true)
  }

  private func move(_ offset: CGSize, ended: Bool) {
    let panel = build()
    let pointer = NSEvent.mouseLocation
    if dragOrigin == nil {
      dragOrigin = panel.frame.origin
      dragPointer = NSPoint(x: pointer.x - offset.width * model.scale,
                            y: pointer.y + offset.height * model.scale)
    }
    let start = dragOrigin!, grabbed = dragPointer!
    let origin = placement.snap(NSPoint(x: start.x + pointer.x - grabbed.x,
                                        y: start.y + pointer.y - grabbed.y),
                                in: workArea, size: size)
    panel.setFrameOrigin(origin)
    placement.capture(origin: origin, in: workArea, size: size)
    if ended {
      dragOrigin = nil; dragPointer = nil
      if !model.editing { persist() }
    }
  }

  func setScale(_ scale: Double) {
    placement.scale = HUDPlacement.validScale(scale)
    model.scale = placement.scale
    resize()
    if !model.editing { persist() }
  }

  func resetPosition() {
    placement = HUDPlacement()
    model.scale = placement.scale
    resize()
    if !model.editing { persist() }
  }

  func configure(labels: [String: String]) {
    if model.editing { return }
    savedPlacement = placement
    visibleBeforeEditing = panel?.isVisible == true
    stateBeforeEditing = model.state
    model.labels = labels
    layoutScreen = currentScreen
    hideAfterDone?.invalidate(); hideAfterDone = nil
    showNumber += 1
    model.editing = true

    resize()
    let overlay = NSPanel(contentRect: workArea, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
    overlay.level = .floating
    overlay.isOpaque = false; overlay.backgroundColor = .clear
    overlay.ignoresMouseEvents = true
    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    overlay.contentView = NSHostingView(rootView: HUDGuides())
    overlay.orderFrontRegardless()
    guides = overlay
    previousKeyWindow = NSApp.keyWindow
    panel?.editingEnabled = true
    panel?.alphaValue = 1; panel?.makeKeyAndOrderFront(nil)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.model.editing else { return event }
      if event.keyCode == 53 { self.finishEditing(save: false); return nil }
      if event.keyCode == 36 { self.finishEditing(save: true); return nil }
      let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
      var delta = NSPoint.zero
      switch event.keyCode {
      case 123: delta.x = -step
      case 124: delta.x = step
      case 125: delta.y = -step
      case 126: delta.y = step
      default: return event
      }
      let p = self.build().frame.origin
      let moved = self.placement.clamp(NSPoint(x: p.x + delta.x, y: p.y + delta.y),
                                       in: self.workArea, size: self.size)
      self.panel?.setFrameOrigin(moved)
      self.placement.capture(origin: moved, in: self.workArea, size: self.size)
      return nil
    }
  }

  func finishEditing(save: Bool) {
    guard model.editing else { return }
    if !save { placement = savedPlacement }
    else { persist() }
    model.editing = false
    panel?.editingEnabled = false
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
    previousKeyWindow?.makeKeyAndOrderFront(nil)
    model.scale = placement.scale
    guides?.orderOut(nil); guides = nil
    resize()
    if stateBeforeEditing == .hidden { panel?.orderOut(nil); model.state = .hidden }
    else { model.state = stateBeforeEditing }
    if ![HUDState.hidden, .recording, .transcribing].contains(stateBeforeEditing) {
      linger(stateBeforeEditing, seconds: 2.6)
    }
    layoutScreen = nil
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func updateQueue(pending: Int, processing: Bool, labels: [String: String] = [:]) {
    model.labels.merge(labels) { _, new in new }
    model.pending = pending
    model.processing = processing
  }

  func show() {
    if model.editing { stateBeforeEditing = .recording }
    if model.state == .recording && panel?.isVisible == true && !hiding { return }
    hiding = false
    if !model.editing && panel?.isVisible != true { layoutScreen = nil; layoutScreen = currentScreen }
    let panel = build()
    hideAfterDone?.invalidate()
    hideAfterDone = nil
    ticker?.invalidate()
    ticker = nil
    showNumber += 1
    model.state = .recording
    model.levels = Array(repeating: 0, count: model.levels.count)
    startedAt = Date()
    model.elapsed = 0

    // Появление проигрываем, только если панели на экране не было. А вот
    // на экран выводим и проявляем всегда: «panel.isVisible» бывает true
    // и у панели, которая прямо сейчас доугасает до нуля, — и без этих
    // двух строк она так и оставалась прозрачной всю запись.
    let appearing = !panel.isVisible
    let rest = restingOrigin
    if appearing {
      // Приходит снизу и уходит вниз же: если что-то появилось одним
      // путём, мы ждём, что тем же путём оно и исчезнет.
      panel.setFrameOrigin(
        NSPoint(x: rest.x, y: reduceMotion ? rest.y : rest.y - 18))
      panel.alphaValue = 0
    } else {
      panel.setFrameOrigin(rest)
      panel.alphaValue = 1
    }
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.15 : (appearing ? 0.34 : 0.12)
      context.timingFunction = CAMediaTimingFunction(
        controlPoints: 0.22, 1, 0.36, 1)
      panel.animator().alphaValue = 1
      panel.animator().setFrameOrigin(rest)
    }

    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.model.push(level: self.levelSource())
      if let started = self.startedAt, self.model.state == .recording {
        self.model.elapsed = Date().timeIntervalSince(started)
      }
    }
    // scheduledTimer попадает только в default mode главного run loop.
    // Системное меню переводит его в eventTracking mode на всё время,
    // пока меню раскрыто, — и панель застывала вместе со временем и
    // измерителем, хотя рекордер продолжал писать. Common modes включают
    // оба режима, поэтому интерфейс записи продолжает жить поверх меню.
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  /// Запись кончилась — панель не исчезает, а перетекает в «Распознаю».
  /// Пропасть между «отпустил клавишу» и «текст появился» и есть то
  /// место, где пользователь начинает гадать, работает ли программа.
  func transcribing() {
    if model.editing { stateBeforeEditing = .transcribing }
    guard panel?.isVisible == true else { return }
    ticker?.invalidate()
    ticker = nil
    model.state = .transcribing
  }

  /// Короткое подтверждение — и уходит.
  func finish() {
    linger(.done, seconds: 0.7)
  }

  /// Неудача висит дольше подтверждения: её надо успеть прочитать.
  func failed() {
    linger(.failed, seconds: 2.6)
  }

  /// Текст уцелел, но остался в буфере обмена — об этом надо успеть
  /// прочитать так же, как о потерянной записи.
  func copied() {
    linger(.copied, seconds: 2.6)
  }

  /// Распознавание прервали сами. Панель не исчезает молча: надо сказать,
  /// что запись при этом сохранена, — иначе отмена читается как потеря.
  func cancelled() {
    linger(.cancelled, seconds: 2.2)
  }

  /// Записывать было нечего. Висит недолго: сказанного тут одно слово,
  /// и оно про то, что ничего не случилось.
  func silent() {
    linger(.silent, seconds: 1.8)
  }

  private func linger(_ state: HUDState, seconds: TimeInterval) {
    if model.editing { stateBeforeEditing = state }
    guard panel?.isVisible == true else {
      hide()
      return
    }
    ticker?.invalidate()
    ticker = nil
    model.state = state
    hideAfterDone?.invalidate()
    if model.editing { return }
    hideAfterDone = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      self?.hide()
    }
  }

  func hide() {
    if model.editing { stateBeforeEditing = .hidden; return }
    ticker?.invalidate()
    ticker = nil
    hideAfterDone?.invalidate()
    hideAfterDone = nil
    guard let panel, panel.isVisible else { return }
    let rest = restingOrigin
    hiding = true
    let mine = showNumber
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = reduceMotion ? 0.12 : 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
        if !reduceMotion {
          panel.animator().setFrameOrigin(NSPoint(x: rest.x, y: rest.y - 18))
        }
      },
      completionHandler: { [weak self] in
        // Пока панель угасала, могла начаться новая запись. Тогда убирать
        // с экрана нечего: на нём уже не наша панель, а следующая.
        guard let self, self.showNumber == mine else { return }
        panel.orderOut(nil)
        self.model.state = .hidden
      })
  }
}

/// Coordinates are fractions of the work area, measured from its top left.
struct HUDPlacement {
  var x: Double?
  var y: Double?
  var scale: Double
  init(x: Double? = nil, y: Double? = nil, scale: Double = 1) {
    self.x = x.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.y = y.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.scale = Self.validScale(scale)
  }
  static func validScale(_ scale: Double) -> Double {
    scale.isFinite ? min(1.6, max(0.8, scale)) : 1
  }
  func clamp(_ origin: NSPoint, in work: NSRect, size: NSSize) -> NSPoint {
    NSPoint(x: min(max(work.minX, work.maxX - size.width), max(work.minX, origin.x)),
            y: min(max(work.minY, work.maxY - size.height), max(work.minY, origin.y)))
  }
  func origin(in work: NSRect, size: NSSize) -> NSPoint {
    clamp(NSPoint(x: work.minX + (x ?? 0.5) * work.width - size.width / 2,
                  y: y.map { work.maxY - $0 * work.height - size.height / 2 }
                    ?? work.minY + 92), in: work, size: size)
  }
  func snap(_ origin: NSPoint, in work: NSRect, size: NSSize) -> NSPoint {
    var p = origin
    if abs(p.x + size.width / 2 - work.midX) <= 12 { p.x = work.midX - size.width / 2 }
    if abs(p.y + size.height / 2 - work.midY) <= 12 { p.y = work.midY - size.height / 2 }
    return clamp(p, in: work, size: size)
  }
  mutating func capture(origin: NSPoint, in work: NSRect, size: NSSize) {
    guard work.width > 0, work.height > 0 else { return }
    x = min(1, max(0, (origin.x + size.width / 2 - work.minX) / work.width))
    y = min(1, max(0, (work.maxY - origin.y - size.height / 2) / work.height))
  }
}

private struct HUDGuides: View {
  var body: some View {
    GeometryReader { area in
      ZStack {
        Color.blue.opacity(0.10)
        Rectangle().fill(Color.blue.opacity(0.65)).frame(width: 1)
        Rectangle().fill(Color.blue.opacity(0.65)).frame(height: 1)
      }.frame(width: area.size.width, height: area.size.height)
    }.accessibilityHidden(true)
  }
}
