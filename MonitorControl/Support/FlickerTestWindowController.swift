//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// PWM flicker test: steps the raw hardware backlight through levels so the user can film the screen
/// with a phone camera (slow-motion works best) and find the lowest level without visible banding.
/// That level can then be saved as the display's flicker-free floor.
class FlickerTestWindowController: NSWindowController, NSWindowDelegate {
  static var shared: FlickerTestWindowController?

  private let levels: [Float] = stride(from: 100, through: 5, by: -5).map { Float($0) / 100 }
  private var levelIndex = 0
  private weak var display: AppleDisplay?
  private var autoTimer: Timer?

  private let levelLabel = NSTextField(labelWithString: "")
  private let floorLabel = NSTextField(labelWithString: "")
  private let floorCheckbox = NSButton(checkboxWithTitle: "Enable flicker-free floor", target: nil, action: nil)
  private let autoButton = NSButton(title: "Auto-step (4s)", target: nil, action: nil)
  private let patternView = FlickerPatternView()

  static func show() {
    guard let display = Self.targetDisplay() else {
      let alert = NSAlert()
      alert.messageText = "No supported display"
      alert.informativeText = "The flicker test and flicker-free floor work on Apple displays (such as the built-in MacBook display) whose brightness is controlled by macOS."
      alert.runModal()
      return
    }
    if let existing = Self.shared {
      existing.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = FlickerTestWindowController(display: display)
    Self.shared = controller
    controller.showWindow(nil)
    controller.window?.center()
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private static func targetDisplay() -> AppleDisplay? {
    let apple = DisplayManager.shared.getAppleDisplays().filter { !$0.isDummy }
    return apple.first { $0.isBuiltIn() } ?? apple.first
  }

  init(display: AppleDisplay) {
    self.display = display
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "PWM Flicker Test – \(display.readPrefAsString(key: .friendlyName).isEmpty ? display.name : display.readPrefAsString(key: .friendlyName))"
    window.minSize = NSSize(width: 520, height: 480)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    self.buildUI()
    display.flickerTestActive = true
    self.levelIndex = 0
    self.applyLevel()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - UI

  private func buildUI() {
    guard let content = self.window?.contentView else {
      return
    }
    content.wantsLayer = true

    self.patternView.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(self.patternView)

    let info = NSTextField(wrappingLabelWithString: "Point your phone camera (slow-motion video is best) at the white area. Dark rolling bands mean PWM flicker at that level. Step down until bands appear, then go back up one step and save it as the floor. Below the floor, MonitorControl dims in software while the backlight stays at the floor.\n\nTip: turn off \"Automatically adjust brightness\" and True Tone in System Settings › Displays during the test.")
    info.font = NSFont.systemFont(ofSize: 12)
    info.textColor = .secondaryLabelColor

    self.levelLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
    self.levelLabel.alignment = .center
    self.floorLabel.font = NSFont.systemFont(ofSize: 12)
    self.floorLabel.textColor = .secondaryLabelColor
    self.floorLabel.alignment = .center

    let lower = NSButton(title: "◀ Lower", target: self, action: #selector(self.lowerClicked))
    let higher = NSButton(title: "Higher ▶", target: self, action: #selector(self.higherClicked))
    self.autoButton.target = self
    self.autoButton.action = #selector(self.autoClicked)
    self.autoButton.setButtonType(.pushOnPushOff)
    let stepRow = NSStackView(views: [lower, self.autoButton, higher])
    stepRow.spacing = 10

    let useAsFloor = NSButton(title: "Save this level as flicker-free floor", target: self, action: #selector(self.saveFloorClicked))
    useAsFloor.keyEquivalent = "\r"
    self.floorCheckbox.target = self
    self.floorCheckbox.action = #selector(self.floorCheckboxClicked)
    let done = NSButton(title: "Done", target: self, action: #selector(self.doneClicked))
    done.keyEquivalent = "\u{1b}"
    let floorRow = NSStackView(views: [self.floorCheckbox, useAsFloor, done])
    floorRow.spacing = 10

    let controls = NSStackView(views: [self.levelLabel, stepRow, self.floorLabel, floorRow, info])
    controls.orientation = .vertical
    controls.alignment = .centerX
    controls.spacing = 12
    controls.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 16, right: 18)
    controls.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(controls)

    NSLayoutConstraint.activate([
      self.patternView.topAnchor.constraint(equalTo: content.topAnchor),
      self.patternView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      self.patternView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      self.patternView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
      controls.topAnchor.constraint(equalTo: self.patternView.bottomAnchor),
      controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      info.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -36),
    ])
    self.refreshFloorUI()
  }

  private func refreshFloorUI() {
    guard let display = self.display else {
      return
    }
    let saved = display.readPrefAsFloat(key: .pwmFloor)
    let enabled = display.readPrefAsBool(key: .pwmFloorEnabled)
    self.floorCheckbox.state = enabled ? .on : .off
    self.floorCheckbox.isEnabled = saved > 0
    if saved > 0 {
      self.floorLabel.stringValue = "Saved floor: \(Int(round(saved * 100)))% hardware brightness" + (enabled ? " (active)" : " (disabled)")
    } else {
      self.floorLabel.stringValue = "No floor saved yet"
    }
  }

  private func applyLevel() {
    guard let display = self.display else {
      return
    }
    let level = self.levels[self.levelIndex]
    display.setRawHardwareBrightnessForTest(level)
    self.levelLabel.stringValue = "Hardware brightness: \(Int(round(level * 100)))%"
    self.patternView.levelText = "\(Int(round(level * 100)))%"
  }

  // MARK: - Actions

  @objc private func lowerClicked() {
    self.stopAuto()
    self.levelIndex = min(self.levelIndex + 1, self.levels.count - 1)
    self.applyLevel()
  }

  @objc private func higherClicked() {
    self.stopAuto()
    self.levelIndex = max(self.levelIndex - 1, 0)
    self.applyLevel()
  }

  @objc private func autoClicked() {
    if self.autoTimer != nil {
      self.stopAuto()
      return
    }
    self.autoButton.state = .on
    self.autoTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      guard let self = self else {
        return
      }
      if self.levelIndex >= self.levels.count - 1 {
        self.stopAuto()
        return
      }
      self.levelIndex += 1
      self.applyLevel()
    }
  }

  private func stopAuto() {
    self.autoTimer?.invalidate()
    self.autoTimer = nil
    self.autoButton.state = .off
  }

  @objc private func saveFloorClicked() {
    self.stopAuto()
    guard let display = self.display else {
      return
    }
    let level = self.levels[self.levelIndex]
    display.savePref(level, key: .pwmFloor)
    display.savePref(true, key: .pwmFloorEnabled)
    os_log("Flicker test: floor saved at %{public}@", type: .info, String(level))
    self.refreshFloorUI()
  }

  @objc private func floorCheckboxClicked() {
    guard let display = self.display else {
      return
    }
    display.savePref(self.floorCheckbox.state == .on, key: .pwmFloorEnabled)
    self.refreshFloorUI()
  }

  @objc private func doneClicked() {
    self.window?.close()
  }

  func windowWillClose(_: Notification) {
    self.stopAuto()
    // Restore the user's brightness, now honoring the (possibly new) floor
    if let display = self.display {
      display.endFlickerTest()
      display.sliderHandler[.brightness]?.setValue(display.getBrightness(), displayID: display.identifier)
    }
    Self.shared = nil
  }
}

/// Plain white field with fine black lines and the current level: rolling PWM bands are easy to see on camera.
class FlickerPatternView: NSView {
  var levelText: String = "" {
    didSet { self.needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.white.setFill()
    dirtyRect.fill()
    NSColor.black.withAlphaComponent(0.85).setFill()
    let lineWidth: CGFloat = 1
    var x: CGFloat = 0
    while x < self.bounds.width {
      NSRect(x: x, y: 0, width: lineWidth, height: 10).fill()
      NSRect(x: x, y: self.bounds.height - 10, width: lineWidth, height: 10).fill()
      x += 8
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold),
      .foregroundColor: NSColor.black.withAlphaComponent(0.12),
    ]
    let text = NSAttributedString(string: self.levelText, attributes: attrs)
    let size = text.size()
    text.draw(at: NSPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2))
  }
}
