import Cocoa
import Foundation

final class AutomationMenuController: NSObject, NSMenuDelegate {
  static let shared = AutomationMenuController()

  private let presets = BrightnessPresetStore()
  private weak var menu: NSMenu?
  private var previousDelegate: NSMenuDelegate?

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
    AutomationLogger.log("Manual sensor state set to day from automation menu")
    self.refreshMenu()
  }

  @objc private func selectNight(_: Any?) {
    DisplayBrightnessController.shared.setTestSensorState(.night)
    AutomationLogger.log("Manual sensor state set to night from automation menu")
    self.refreshMenu()
  }

  @objc private func selectUnset(_: Any?) {
    DisplayBrightnessController.shared.clearTestSensorState()
    AutomationLogger.log("Manual sensor state cleared from automation menu")
    self.refreshMenu()
  }

  private func registerPreset(for state: AutomationLightState) {
    let displays = DisplayManager.shared.getDdcCapableDisplays()
    guard !displays.isEmpty else {
      AutomationLogger.log("Could not register \(state.rawValue) preset: no DDC-capable displays")
      self.refreshMenu()
      return
    }

    var savedCount = 0
    for display in displays {
      guard !display.readPrefAsBool(key: .forceSw),
            !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) else {
        AutomationLogger.log("Skipped \(state.rawValue) preset for display \(display.identifier): DDC brightness unavailable")
        continue
      }

      guard let values = display.readDDCValues(for: .brightness, tries: 1, minReplyDelay: nil), values.1 > 0 else {
        AutomationLogger.log("Could not read current brightness for display \(display.identifier); \(state.rawValue) preset not saved")
        continue
      }

      var brightness = display.convDDCToValue(for: .brightness, from: values.0)
      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
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
        }
      }
      guard brightness.isFinite else {
        AutomationLogger.log("Could not register \(state.rawValue) preset for display \(display.identifier): invalid brightness value")
        continue
      }

      self.presets.save(brightness, for: state, displayID: display.prefsId)
      savedCount += 1
      AutomationLogger.log("Registered \(state.rawValue) preset for display \(display.identifier): \(Int((brightness * 100).rounded()))%")
    }
    AutomationLogger.log("Registered \(state.rawValue) preset on \(savedCount) of \(displays.count) DDC-capable displays")
    self.refreshMenu()
  }

  private func refreshMenu() {
    guard let menu = self.menu else {
      return
    }
    for item in menu.items.reversed() where item.tag == Self.automationMenuTag {
      menu.removeItem(item)
    }

    self.appendItem("明るさ自動化", to: menu, action: nil, enabled: false)
    self.appendItem("現在の明るさを昼用に登録", to: menu, action: #selector(self.registerDayPreset(_:)))
    self.appendItem("現在の明るさを夜用に登録", to: menu, action: #selector(self.registerNightPreset(_:)))

    for display in DisplayManager.shared.getDdcCapableDisplays() {
      let day = self.presets.brightness(for: .day, displayID: display.prefsId)
      let night = self.presets.brightness(for: .night, displayID: display.prefsId)
      let dayText = day.map { "\(Int(($0 * 100).rounded()))%" } ?? "未登録"
      let nightText = night.map { "\(Int(($0 * 100).rounded()))%" } ?? "未登録"
      self.appendItem("\(display.name) — 昼 \(dayText) / 夜 \(nightText)", to: menu, action: nil, enabled: false)
    }

    self.appendItem("状態：昼", to: menu, action: #selector(self.selectDay(_:)), showsStateSelection: true, state: .day)
    self.appendItem("状態：夜", to: menu, action: #selector(self.selectNight(_:)), showsStateSelection: true, state: .night)
    self.appendItem("状態：未設定", to: menu, action: #selector(self.selectUnset(_:)), showsStateSelection: true, state: nil)
    menu.addItem(.separator())
    menu.items.last?.tag = Self.automationMenuTag
  }

  private func appendItem(
    _ title: String,
    to menu: NSMenu,
    action: Selector?,
    enabled: Bool = true,
    showsStateSelection: Bool = false,
    state: AutomationLightState? = nil
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    item.tag = Self.automationMenuTag
    if showsStateSelection {
      item.state = ManualToggleSensorStateSource.shared.state == state ? .on : .off
    }
    menu.addItem(item)
  }

  private static let automationMenuTag = 28471
}
