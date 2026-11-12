import Cocoa
import Foundation

protocol AutomationBrightnessApplying: AnyObject {
  func apply(_ state: AutomationLightState) -> Bool
}

final class MonitorControlBrightnessApplier: AutomationBrightnessApplying {
  private let presets: BrightnessPresetStore
  private let manualObserver: ManualBrightnessChangeObserving

  init(
    presets: BrightnessPresetStore = BrightnessPresetStore(),
    manualObserver: ManualBrightnessChangeObserving
  ) {
    self.presets = presets
    self.manualObserver = manualObserver
  }

  func apply(_ state: AutomationLightState) -> Bool {
    let eligibleDisplays = DisplayManager.shared.getDdcCapableDisplays().filter { display in
      !display.isSw()
        && !display.readPrefAsBool(key: .forceSw)
        && !display.readPrefAsBool(key: .unavailableDDC, for: .brightness)
    }
    guard !eligibleDisplays.isEmpty else {
      return false
    }

    let targets = eligibleDisplays.compactMap { display -> (OtherDisplay, Float)? in
      guard let target = self.presets.brightness(for: state, displayID: display.prefsId) else {
        return nil
      }
      return (display, target)
    }
    guard targets.count == eligibleDisplays.count else {
      return false
    }

    for (display, target) in targets {
      // setBrightness owns the upstream smooth transition. Do not add a second
      // fade here; the existing combined DDC/software behavior remains intact.
      guard display.setBrightness(target, slow: true) else {
        return false
      }
      self.manualObserver.noteAutomatedBrightnessChange(displayID: display.identifier, target: target)
    }
    return true
  }
}

final class DisplayBrightnessController {
  static let shared = DisplayBrightnessController()

  private let sensorSource: SensorStateSource
  private var stateMachine = AutomationStateMachine()
  private let manualObserver: ManualBrightnessChangeObserving
  private let applier: AutomationBrightnessApplying
  private var isRunning = false

  init(
    sensorSource: SensorStateSource = ManualToggleSensorStateSource.shared,
    manualObserver: ManualBrightnessChangeObserving = DDCManualBrightnessObserver(),
    presets: BrightnessPresetStore = BrightnessPresetStore()
  ) {
    self.sensorSource = sensorSource
    self.manualObserver = manualObserver
    self.applier = MonitorControlBrightnessApplier(presets: presets, manualObserver: manualObserver)
  }

  func start() {
    guard !self.isRunning else {
      return
    }
    self.isRunning = true
    _ = self.manualObserver.detectManualBrightnessChange() // Establish the initial DDC baseline.
    AutomationLogger.log("Started; polling every 60 seconds")
    self.scheduleNextPoll()
  }

  /// Test route for Phase 2; no UI or sensor network integration is included.
  func toggleTestSensorState() {
    (self.sensorSource as? ManualToggleSensorStateSource)?.toggle()
  }

  func setTestSensorState(_ state: AutomationLightState) {
    (self.sensorSource as? ManualToggleSensorStateSource)?.setState(state)
  }

  private func scheduleNextPoll() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let controller = self, controller.isRunning else {
        return
      }
      controller.poll()
      controller.scheduleNextPoll()
    }
  }

  private func poll() {
    let now = Date()
    let manualChange = self.manualObserver.detectManualBrightnessChange()
    let outcome = self.stateMachine.evaluate(
      reading: self.sensorSource.readState(),
      now: now,
      manualBrightnessChanged: manualChange
    )
    guard case let .apply(state) = outcome else {
      return
    }

    guard self.applier.apply(state) else {
      AutomationLogger.log("No applicable display preset for \(state.rawValue); will retry")
      return
    }
    self.stateMachine.recordSuccessfulTransition(to: state, at: now)
    AutomationLogger.log("Applied \(state.rawValue) brightness preset")
  }
}
