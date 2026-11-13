import Foundation

protocol SensorStateSource: AnyObject {
  func readState() -> SensorStateReading?
}

enum AutomationInputMode: String {
  case manual
  case timer
}

final class AutomationInputModeStore {
  static let key = "automation.inputMode"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var mode: AutomationInputMode {
    get {
      guard let rawValue = self.defaults.string(forKey: Self.key) else {
        return .manual
      }
      return AutomationInputMode(rawValue: rawValue) ?? .manual
    }
    set {
      self.defaults.set(newValue.rawValue, forKey: Self.key)
    }
  }
}

enum AutomationTimerSchedule {
  // Times are stored as minutes after midnight; defaults define 07:00–19:00 daytime.
  static let dayStartMinutesKey = "automation.schedule.dayStartMinutes"
  static let nightStartMinutesKey = "automation.schedule.nightStartMinutes"
  static let defaultDayStartMinutes = 7 * 60
  static let defaultNightStartMinutes = 19 * 60

  static var dayStartMinutes: Int {
    self.minutes(forKey: self.dayStartMinutesKey, defaultValue: self.defaultDayStartMinutes)
  }

  static var nightStartMinutes: Int {
    self.minutes(forKey: self.nightStartMinutesKey, defaultValue: self.defaultNightStartMinutes)
  }

  static var formattedDescription: String {
    "昼 \(self.format(self.dayStartMinutes))〜／夜 \(self.format(self.nightStartMinutes))〜"
  }

  private static func minutes(forKey key: String, defaultValue: Int) -> Int {
    guard let value = UserDefaults.standard.object(forKey: key) as? Int,
          (0..<24 * 60).contains(value) else {
      return defaultValue
    }
    return value
  }

  private static func format(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }
}

/// Manual Phase 2 input. Each read refreshes the timestamp for the selected state.
final class ManualToggleSensorStateSource: SensorStateSource {
  static let shared = ManualToggleSensorStateSource()

  private(set) var state: AutomationLightState?

  func setState(_ state: AutomationLightState) {
    self.state = state
  }

  func toggle() {
    self.state = self.state?.opposite ?? .day
  }

  func clear() {
    self.state = nil
  }

  func readState() -> SensorStateReading? {
    guard let state = self.state else {
      return nil
    }
    return SensorStateReading(state: state, sampledAt: Date())
  }
}

final class TimerSensorStateSource: SensorStateSource {
  private let now: () -> Date
  private let calendar: () -> Calendar

  init(now: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { .current }) {
    self.now = now
    self.calendar = calendar
  }

  func readState() -> SensorStateReading? {
    let sampledAt = self.now()
    let components = self.calendar().dateComponents([.hour, .minute], from: sampledAt)
    guard let hour = components.hour, let minute = components.minute else {
      return nil
    }

    let currentMinutes = hour * 60 + minute
    let dayStart = AutomationTimerSchedule.dayStartMinutes
    let nightStart = AutomationTimerSchedule.nightStartMinutes
    let isDay = dayStart < nightStart && currentMinutes >= dayStart && currentMinutes < nightStart
    let state: AutomationLightState = isDay ? .day : .night
    return SensorStateReading(state: state, sampledAt: sampledAt)
  }
}
