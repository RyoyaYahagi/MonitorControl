import Foundation

final class BrightnessPresetStore {
  static let keyPrefix = "automation.preset."

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func save(_ brightness: Float, for state: AutomationLightState, displayID: String) {
    guard brightness.isFinite else {
      return
    }
    self.defaults.set(
      min(max(brightness, 0), 1),
      forKey: Self.key(for: state, displayID: displayID)
    )
  }

  func brightness(for state: AutomationLightState, displayID: String) -> Float? {
    let key = Self.key(for: state, displayID: displayID)
    guard self.defaults.object(forKey: key) != nil else {
      return nil
    }
    let value = self.defaults.float(forKey: key)
    return value.isFinite ? min(max(value, 0), 1) : nil
  }

  static func key(for state: AutomationLightState, displayID: String) -> String {
    "\(self.keyPrefix)\(state.rawValue).\(displayID)"
  }
}
