import Cocoa
import Foundation

final class AutomationMenuController: NSObject, NSMenuDelegate {
  static let shared = AutomationMenuController()

  private let presets = BrightnessPresetStore()
  private weak var menu: NSMenu?
  private var previousDelegate: NSMenuDelegate?
  private let presetRegistrationQueue = DispatchQueue(label: "MonitorControl.BrightnessPresetRegistration")
  private var isRegisteringPreset = false

  func install(in menu: NSMenu) {
    guard self.menu !== menu else {
      self.refreshMenu()
      return
    }
    self.menu = menu
    self.previousDelegate = menu.delegate
    menu.delegate = self
    self.refreshMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    (self.previousDelegate as? MenuHandler)?.menuWillOpen(menu)
    self.refreshMenu()
  }

  @objc private func registerDayPreset(_: Any?) {
    self.registerPreset(for: .day)
  }

  @objc private func registerNightPreset(_: Any?) {
    self.registerPreset(for: .night)
  }

  @objc private func selectDay(_: Any?) {
    DisplayBrightnessController.shared.setTestSensorState(.day)
    self.refreshMenu()
  }

  @objc private func selectNight(_: Any?) {
    DisplayBrightnessController.shared.setTestSensorState(.night)
    self.refreshMenu()
  }

  @objc private func selectManualInputMode(_: Any?) {
    DisplayBrightnessController.shared.setInputMode(.manual)
    self.refreshMenu()
  }

  @objc private func selectTimerInputMode(_: Any?) {
    DisplayBrightnessController.shared.setInputMode(.timer)
    self.refreshMenu()
  }

  @objc private func selectUnset(_: Any?) {
    DisplayBrightnessController.shared.clearTestSensorState()
    AutomationLogger.log("Manual sensor state cleared from automation menu")
    self.refreshMenu()
  }

  private func registerPreset(for state: AutomationLightState) {
    guard !self.isRegisteringPreset else {
      return
    }
    let displays = DisplayManager.shared.getDdcCapableDisplays()
    guard !displays.isEmpty else {
      AutomationLogger.log("Could not register \(state.rawValue) preset: no DDC-capable displays")
      self.refreshMenu()
      return
    }

    self.isRegisteringPreset = true
    self.refreshMenu()
    self.presetRegistrationQueue.async { [weak self] in
      guard let controller = self else {
        return
      }
      controller.captureAndSavePreset(for: state, on: displays)
      DispatchQueue.main.async {
        controller.isRegisteringPreset = false
        controller.refreshMenu()
      }
    }
  }

  private func captureAndSavePreset(for state: AutomationLightState, on displays: [OtherDisplay]) {
    var savedCount = 0
    for display in displays {
      guard !display.readPrefAsBool(key: .forceSw),
            !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) else {
        AutomationLogger.log("Skipped \(state.rawValue) preset for display \(display.identifier): DDC brightness unavailable")
        continue
      }

      let lifecycleStateAllowsRead = DispatchQueue.main.sync {
        app.sleepID == 0 && app.reconfigureID == 0
      }
      let tries: UInt = Arm64DDC.isArm64 ? 0 : 1
      let ddcValues = display.readDDCValues(
        for: .brightness,
        tries: tries,
        minReplyDelay: nil,
        lifecycleStateAllowsRead: lifecycleStateAllowsRead
      )
      var brightness: Float
      var source: String
      var usesCachedEffectiveBrightness = false
      if let values = ddcValues, values.1 > 0 {
        brightness = display.convDDCToValue(for: .brightness, from: values.0)
        source = "DDC read"
      } else {
        guard display.prefExists(for: .brightness) else {
          AutomationLogger.log("Could not read current brightness for display \(display.identifier) and no cached value exists; \(state.rawValue) preset not saved")
          continue
        }
        brightness = display.getBrightness()
        source = "cached brightness after DDC read failure"
        usesCachedEffectiveBrightness = true
      }

      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue), !usesCachedEffectiveBrightness {
        if brightness > 0 {
          let switchingPoint = display.combinedBrightnessSwitchingValue()
          brightness = switchingPoint + brightness * (1 - switchingPoint)
        } else {
          guard display.prefExists(for: .brightness) else {
            AutomationLogger.log("Could not register \(state.rawValue) preset for display \(display.identifier): combined low-brightness cache unavailable")
            continue
          }
          // At DDC zero, use MonitorControl's cached effective value, which
          // includes the software dimming level in combined brightness mode.
          brightness = display.getBrightness()
          source = "cached brightness (combined mode with DDC at zero)"
          usesCachedEffectiveBrightness = true
        }
      }
      guard brightness.isFinite else {
        AutomationLogger.log("Could not register \(state.rawValue) preset for display \(display.identifier): invalid brightness value")
        continue
      }

      self.presets.save(brightness, for: state, displayID: display.prefsId)
      savedCount += 1
      AutomationLogger.log("Registered \(state.rawValue) preset for display \(display.identifier): \(Int((brightness * 100).rounded()))% (source: \(source))")
    }
    AutomationLogger.log("Registered \(state.rawValue) preset on \(savedCount) of \(displays.count) DDC-capable displays")
  }

  private func refreshMenu() {
    guard let menu = self.menu else {
      return
    }
    let controller = DisplayBrightnessController.shared
    let selectedState = controller.currentInputState
    for item in menu.items.reversed() where item.tag == Self.automationMenuTag {
      menu.removeItem(item)
    }

    self.appendItem("明るさ自動化", to: menu, action: nil, enabled: false)
    self.appendItem("入力：手動", to: menu, action: #selector(self.selectManualInputMode(_:)), showsInputModeSelection: true, inputMode: .manual)
    self.appendItem("入力：タイマー（\(AutomationTimerSchedule.formattedDescription)）", to: menu, action: #selector(self.selectTimerInputMode(_:)), showsInputModeSelection: true, inputMode: .timer)
    let dayTitle = self.isRegisteringPreset ? "昼用プリセットを登録中…" : "現在の明るさを昼用に登録"
    let nightTitle = self.isRegisteringPreset ? "夜用プリセットを登録中…" : "現在の明るさを夜用に登録"
    self.appendItem(dayTitle, to: menu, action: #selector(self.registerDayPreset(_:)), enabled: !self.isRegisteringPreset)
    self.appendItem(nightTitle, to: menu, action: #selector(self.registerNightPreset(_:)), enabled: !self.isRegisteringPreset)

    for display in DisplayManager.shared.getDdcCapableDisplays() {
      let day = self.presets.brightness(for: .day, displayID: display.prefsId)
      let night = self.presets.brightness(for: .night, displayID: display.prefsId)
      let dayText = day.map { "\(Int(($0 * 100).rounded()))%" } ?? "未登録"
      let nightText = night.map { "\(Int(($0 * 100).rounded()))%" } ?? "未登録"
      self.appendItem("\(display.name) — 昼 \(dayText) / 夜 \(nightText)", to: menu, action: nil, enabled: false)
    }

    self.appendItem("状態：昼", to: menu, action: #selector(self.selectDay(_:)), showsStateSelection: true, state: .day, selectedState: selectedState)
    self.appendItem("状態：夜", to: menu, action: #selector(self.selectNight(_:)), showsStateSelection: true, state: .night, selectedState: selectedState)
    self.appendItem("状態：未設定", to: menu, action: #selector(self.selectUnset(_:)), showsStateSelection: true, state: nil, selectedState: selectedState)
    menu.addItem(.separator())
    menu.items.last?.tag = Self.automationMenuTag
  }

  private func appendItem(
    _ title: String,
    to menu: NSMenu,
    action: Selector?,
    enabled: Bool = true,
    showsStateSelection: Bool = false,
    state: AutomationLightState? = nil,
    selectedState: AutomationLightState? = nil,
    showsInputModeSelection: Bool = false,
    inputMode: AutomationInputMode? = nil
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    item.tag = Self.automationMenuTag
    if showsStateSelection {
      item.state = selectedState == state ? .on : .off
    }
    if showsInputModeSelection {
      item.state = DisplayBrightnessController.shared.currentInputMode == inputMode ? .on : .off
    }
    menu.addItem(item)
  }

  private static let automationMenuTag = 28471
}
