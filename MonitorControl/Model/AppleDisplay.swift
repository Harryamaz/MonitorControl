//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

class AppleDisplay: Display {
  private var displayQueue: DispatchQueue

  /// Hardware brightness value last written by us while the flicker-free floor is active (-1 = unknown).
  /// Used to detect external changes (native brightness keys, Control Center, auto-brightness) as relative deltas.
  var pwmFloorLastHardware: Float = -1
  /// True while software dimming is applied on top of the floor, so we know to reset gamma when going above it.
  private var pwmFloorSwActive = false
  /// While the flicker test is running, external brightness tracking is paused.
  var flickerTestActive = false

  override init(_ identifier: CGDirectDisplayID, name: String, vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?, isVirtual: Bool = false, isDummy: Bool = false) {
    self.displayQueue = DispatchQueue(label: String("displayQueue-\(identifier)"))
    super.init(identifier, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
  }

  // MARK: - Flicker-free floor

  /// The active floor (0...1), or nil when the feature is disabled for this display.
  var pwmFloor: Float? {
    guard self.readPrefAsBool(key: .pwmFloorEnabled) else {
      return nil
    }
    let floor = self.readPrefAsFloat(key: .pwmFloor)
    return floor > 0 ? min(floor, 1) : nil
  }

  func setPwmFloor(enabled: Bool, value: Float? = nil) {
    if let value = value {
      self.savePref(max(0.05, min(value, 1)), key: .pwmFloor)
    }
    self.savePref(enabled, key: .pwmFloorEnabled)
    os_log("Flicker-free floor for display %{public}@ set to %{public}@ (enabled: %{public}@)", type: .info, String(self.identifier), String(self.readPrefAsFloat(key: .pwmFloor)), String(enabled))
    // Re-apply the current perceived brightness with the new settings
    self.applyPerceivedBrightness(self.getBrightness())
  }

  /// Applies a perceived brightness value. Above the floor this is plain hardware brightness.
  /// Below the floor the hardware stays at the floor and the rest is done with gamma (or shade) dimming.
  private func applyPerceivedBrightness(_ value: Float) {
    let value = max(min(value, 1), 0)
    guard let floor = self.pwmFloor else {
      if self.pwmFloorSwActive {
        _ = self.setSwBrightness(1, noPrefSave: true)
        self.pwmFloorSwActive = false
      }
      self.pwmFloorLastHardware = -1
      self.setAppleBrightness(value: value)
      return
    }
    if value < floor {
      let gammaFactor = value / floor
      // setSwBrightness applies swBrightnessTransform, so feed it the inverse to get the exact gamma factor (clamped by the app's low threshold)
      let swValue = max(0, min(1, self.swBrightnessTransform(value: gammaFactor, reverse: true)))
      self.setAppleBrightness(value: floor)
      _ = self.setSwBrightness(swValue, noPrefSave: true)
      self.pwmFloorSwActive = true
      self.pwmFloorLastHardware = floor
    } else {
      if self.pwmFloorSwActive {
        _ = self.setSwBrightness(1, noPrefSave: true)
        self.pwmFloorSwActive = false
      }
      self.setAppleBrightness(value: value)
      self.pwmFloorLastHardware = value
    }
  }

  // MARK: - Hardware access

  func getAppleBrightness() -> Float {
    guard !self.isDummy else {
      return 1
    }
    var brightness: Float = 0
    DisplayServicesGetBrightness(self.identifier, &brightness)
    return brightness
  }

  func setAppleBrightness(value: Float) {
    guard !self.isDummy else {
      return
    }
    _ = self.displayQueue.sync {
      DisplayServicesSetBrightness(self.identifier, value)
    }
  }

  override func setDirectBrightness(_ to: Float, transient: Bool = false) -> Bool {
    guard !self.isDummy else {
      return false
    }
    let value = max(min(to, 1), 0)
    self.applyPerceivedBrightness(value)
    if !transient {
      self.savePref(value, for: .brightness)
      self.brightnessSyncSourceValue = value
      self.smoothBrightnessTransient = value
    }
    return true
  }

  override func getBrightness() -> Float {
    guard !self.isDummy else {
      return 1
    }
    if self.prefExists(for: .brightness) {
      return self.readPrefAsFloat(for: .brightness)
    } else {
      return self.getAppleBrightness()
    }
  }

  override func refreshBrightness() -> Float {
    guard !self.smoothBrightnessRunning, !self.flickerTestActive else {
      return 0
    }
    if let floor = self.pwmFloor {
      return self.refreshBrightnessWithFloor(floor: floor)
    }
    let brightness = self.getAppleBrightness()
    let oldValue = self.brightnessSyncSourceValue
    self.savePref(brightness, for: .brightness)
    if brightness != oldValue {
      os_log("Pushing slider and reporting delta for Apple display %{public}@", type: .info, String(self.identifier))
      var newValue: Float

      if abs(brightness - oldValue) < 0.01 {
        newValue = brightness
      } else if brightness > oldValue {
        newValue = oldValue + max((brightness - oldValue) / 3, 0.005)
      } else {
        newValue = oldValue + min((brightness - oldValue) / 3, -0.005)
      }
      self.brightnessSyncSourceValue = newValue
      if let sliderHandler = self.sliderHandler[.brightness] {
        sliderHandler.setValue(newValue, displayID: self.identifier)
      }
      return newValue - oldValue
    }
    return 0
  }

  /// With the floor active, the saved brightness pref is the *perceived* value and the hardware value is what we set.
  /// Any external hardware change (macOS brightness keys, Control Center, auto-brightness) is applied as a relative delta
  /// to the perceived value, so the native keys keep working continuously below the floor.
  private func refreshBrightnessWithFloor(floor: Float) -> Float {
    let hardware = self.getAppleBrightness()
    let perceived = self.getBrightness()
    guard self.pwmFloorLastHardware >= 0 else {
      // First run after launch / reconfiguration: gamma was reset, so restore our state.
      if self.prefExists(for: .brightness), perceived < floor, abs(hardware - floor) < 0.02 {
        self.applyPerceivedBrightness(perceived)
      } else {
        self.savePref(hardware, for: .brightness)
        self.applyPerceivedBrightness(hardware)
      }
      self.brightnessSyncSourceValue = self.getBrightness()
      self.sliderHandler[.brightness]?.setValue(self.getBrightness(), displayID: self.identifier)
      return 0
    }
    let externalDelta = hardware - self.pwmFloorLastHardware
    guard abs(externalDelta) > 0.004 else {
      return 0
    }
    let newValue = max(0, min(1, perceived + externalDelta))
    os_log("External brightness change %{public}@ on display %{public}@ with flicker-free floor; perceived %{public}@ -> %{public}@", type: .info, String(externalDelta), String(self.identifier), String(perceived), String(newValue))
    _ = self.setDirectBrightness(newValue)
    self.sliderHandler[.brightness]?.setValue(newValue, displayID: self.identifier)
    return newValue - perceived
  }

  // MARK: - Flicker test support

  /// Sets raw hardware brightness with no software dimming (used by the flicker test).
  func setRawHardwareBrightnessForTest(_ value: Float) {
    if self.pwmFloorSwActive {
      _ = self.setSwBrightness(1, noPrefSave: true)
      self.pwmFloorSwActive = false
    }
    self.setAppleBrightness(value: max(0, min(1, value)))
  }

  /// Ends the flicker test and restores the user's perceived brightness.
  func endFlickerTest() {
    self.flickerTestActive = false
    self.applyPerceivedBrightness(self.getBrightness())
  }
}
