import Cocoa
import Foundation

protocol ManualBrightnessChangeObserving: AnyObject {
  func detectManualBrightnessChange() -> Bool
  func noteAutomatedBrightnessChange(displayID: CGDirectDisplayID, target: Float)
}

/// Infers a manual change from a readable DDC value changing away from the
/// app's saved target. This cannot observe a physical button press itself; it
/// can only infer a resulting value change when DDC reads are supported.
final class DDCManualBrightnessObserver: ManualBrightnessChangeObserving {
  private var previousValues: [CGDirectDisplayID: Float] = [:]
  private var automatedTargets: [CGDirectDisplayID: Float] = [:]
  private var unobservableDisplays = Set<CGDirectDisplayID>()

  func noteAutomatedBrightnessChange(displayID: CGDirectDisplayID, target: Float) {
    self.automatedTargets[displayID] = target
  }

  func detectManualBrightnessChange() -> Bool {
    var detectedChange = false

    for display in DisplayManager.shared.getDdcCapableDisplays() {
      let displayID = display.identifier
      guard !display.isSw(),
            !display.readPrefAsBool(key: .forceSw) else {
        self.previousValues.removeValue(forKey: displayID)
        self.automatedTargets.removeValue(forKey: displayID)
        continue
      }

      guard !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) else {
        self.logUnobservableDisplay(displayID, reason: "DDC brightness reads are disabled")
        self.previousValues.removeValue(forKey: displayID)
        self.automatedTargets.removeValue(forKey: displayID)
        continue
      }

      guard let values = display.readDDCValues(for: .brightness, tries: 1, minReplyDelay: nil),
            values.1 > 0 else {
        self.logUnobservableDisplay(displayID, reason: "DDC brightness read failed")
        continue
      }
      self.unobservableDisplays.remove(displayID)
      var observed = display.convDDCToValue(for: .brightness, from: values.0)
      guard observed.isFinite else {
        continue
      }

      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
        let switchingPoint = display.combinedBrightnessSwitchingValue()
        // At DDC zero, gamma/software dimming carries the remaining value, so
        // the DDC reading alone cannot identify the effective brightness.
        guard observed > 0 else {
          self.logUnobservableDisplay(displayID, reason: "combined low-brightness mode hides the effective value")
          self.previousValues.removeValue(forKey: displayID)
          self.automatedTargets.removeValue(forKey: displayID)
          continue
        }
        observed = switchingPoint + observed * (1 - switchingPoint)
      }

      if display.smoothBrightnessRunning {
        self.previousValues[displayID] = observed
        continue
      }

      if let target = self.automatedTargets[displayID] {
        self.automatedTargets.removeValue(forKey: displayID)
        // These thresholds are unverified. Validate on Mac hardware and
        // distinguish them from DDC propagation delay, quantization, and
        // failed writes.
        if abs(observed - target) <= 0.05 {
          self.previousValues[displayID] = observed
          continue
        }
      }

      // The 0.02 change threshold is also unverified; validate it against DDC
      // propagation delay, quantization, and failed writes on Mac hardware.
      if let previous = self.previousValues[displayID], abs(observed - previous) > 0.02 {
        detectedChange = true
      }
      self.previousValues[displayID] = observed
    }

    return detectedChange
  }

  private func logUnobservableDisplay(_ displayID: CGDirectDisplayID, reason: String) {
    guard self.unobservableDisplays.insert(displayID).inserted else {
      return
    }
    AutomationLogger.log("Manual brightness observation unavailable for display \(displayID): \(reason)")
  }
}
