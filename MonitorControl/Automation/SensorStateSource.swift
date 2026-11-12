import Foundation

protocol SensorStateSource: AnyObject {
  func readState() -> SensorStateReading?
}

/// Phase 2 test input. Each read refreshes the timestamp for the selected state;
/// setState, toggle, and clear provide a small manual test route without a UI.
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
