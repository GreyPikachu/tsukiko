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
  case hidden, recording, transcribing, done, failed, copied, cancelled
}

final class HUDModel: ObservableObject {
  @Published var state: HUDState = .hidden
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
    HStack(spacing: 12) {
      switch model.state {
      case .transcribing:
        Spinner()
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
        Text(time)
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .lineLimit(1)
          .fixedSize()
          .foregroundColor(.primary)
        Spacer(minLength: 0)
        HUDButton(title: "Отменить", filled: false, action: model.onCancel)
        HUDButton(title: "Остановить", filled: true, action: model.onStop)
      }
    }
    // Поля шире, чем кажется нужным: содержимое, прижатое к скруглённому
    // краю, читается теснее, чем стоит на самом деле. Ширина панели растёт
    // на ту же величину, чтобы поля не съели место у кнопок.
    // Двадцать, а не двадцать два: шаг сетки во всём приложении — четыре.
    .padding(.horizontal, 20)
    .frame(height: 52)
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
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class RecordingHUD {
  private var panel: HUDPanel?
  private let model = HUDModel()
  private var ticker: Timer?
  private var startedAt: Date?
  private var hideAfterDone: Timer?

  private let size = NSSize(width: 372, height: 52)

  /// Откуда брать уровень сигнала — рекордер живёт в мосте.
  var levelSource: () -> Double = { 0 }

  init(
    onCancel: @escaping () -> Void, onStop: @escaping () -> Void,
    onAbort: @escaping () -> Void
  ) {
    model.onCancel = onCancel
    model.onStop = onStop
    model.onAbort = onAbort
  }

  private func build() -> HUDPanel {
    if let panel { return panel }

    let panel = HUDPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
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
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
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

  private var restingOrigin: NSPoint {
    let screen = NSScreen.main?.visibleFrame ?? .zero
    return NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 92)
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func show() {
    let panel = build()
    hideAfterDone?.invalidate()
    model.state = .recording
    model.levels = Array(repeating: 0, count: model.levels.count)
    startedAt = Date()
    model.elapsed = 0

    if !panel.isVisible {
      let rest = restingOrigin
      // Приходит снизу и уходит вниз же: если что-то появилось одним
      // путём, мы ждём, что тем же путём оно и исчезнет.
      panel.setFrameOrigin(
        NSPoint(x: rest.x, y: reduceMotion ? rest.y : rest.y - 18))
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = reduceMotion ? 0.15 : 0.34
        context.timingFunction = CAMediaTimingFunction(
          controlPoints: 0.22, 1, 0.36, 1)
        panel.animator().alphaValue = 1
        panel.animator().setFrameOrigin(rest)
      }
    }

    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.model.push(level: self.levelSource())
      if let started = self.startedAt, self.model.state == .recording {
        self.model.elapsed = Date().timeIntervalSince(started)
      }
    }
  }

  /// Запись кончилась — панель не исчезает, а перетекает в «Распознаю».
  /// Пропасть между «отпустил клавишу» и «текст появился» и есть то
  /// место, где пользователь начинает гадать, работает ли программа.
  func transcribing() {
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

  private func linger(_ state: HUDState, seconds: TimeInterval) {
    guard panel?.isVisible == true else {
      hide()
      return
    }
    ticker?.invalidate()
    ticker = nil
    model.state = state
    hideAfterDone?.invalidate()
    hideAfterDone = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
      [weak self] _ in
      self?.hide()
    }
  }

  func hide() {
    ticker?.invalidate()
    ticker = nil
    hideAfterDone?.invalidate()
    hideAfterDone = nil
    guard let panel, panel.isVisible else { return }
    let rest = restingOrigin
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
        panel.orderOut(nil)
        self?.model.state = .hidden
      })
  }
}
