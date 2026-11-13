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
      AutomationLogger.log("No eligible displays for \(state.rawValue) brightness preset; applied 0")
      return false
    }

    var appliedCount = 0
    for display in eligibleDisplays {
      guard let target = self.presets.brightness(for: state, displayID: display.prefsId) else {
        AutomationLogger.log("Skipped \(state.rawValue) preset for display \(display.identifier) (\(display.name), \(display.prefsId)): no preset registered")
        continue
      }
      // setBrightness owns the upstream smooth transition. Do not add a second
      // fade here; the existing combined DDC/software behavior remains intact.
      guard display.setBrightness(target, slow: true) else {
        AutomationLogger.log("Could not apply \(state.rawValue) preset to display \(display.identifier) (\(display.name), \(display.prefsId)): setBrightness returned false")
        continue
      }
      self.manualObserver.noteAutomatedBrightnessChange(displayID: display.identifier, target: target)
      appliedCount += 1
    }
    AutomationLogger.log("Applied \(state.rawValue) brightness preset on \(appliedCount) of \(eligibleDisplays.count) eligible displays")
    return appliedCount > 0
  }
}

final class DisplayBrightnessController {
  static let shared = DisplayBrightnessController()

  private let sensorSource: SensorStateSource
  private var stateMachine = AutomationStateMachine()
  private let manualObserver: ManualBrightnessChangeObserving
  private let applier: AutomationBrightnessApplying
  private var isRunning = false
  private var wakeObserverTokens: [NSObjectProtocol] = []
  private var displayCallbackRegistered = false
  private var reapplicationDebounceUntil = Date.distantPast
  private var reapplicationWorkItem: DispatchWorkItem?
  private var lastLifecycleReapplication: (state: AutomationLightState, at: Date)?

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
    self.registerResumeObservers()
    self.registerDisplayReconfigurationCallback()
    AutomationLogger.log("Started; polling every 60 seconds")
    self.scheduleNextPoll()
  }

  func requestReapplication(reason: String) {
    let now = Date()
    if let last = self.lastLifecycleReapplication,
       self.stateMachine.confirmedSensorState == last.state,
       now.timeIntervalSince(last.at) < 60 {
      AutomationLogger.log("Dropped duplicate lifecycle reapplication for \(last.state.rawValue) within 60 seconds")
      return
    }
    if !self.stateMachine.hasPendingReapplication {
      AutomationLogger.log("Reapplication requested: \(reason)")
    }
    self.stateMachine.requestLifecycleReapplication()
    self.reapplicationDebounceUntil = now.addingTimeInterval(5)

    self.reapplicationWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let controller = self,
            controller.isRunning,
            controller.stateMachine.hasPendingReapplication else {
        return
      }
      controller.poll()
    }
    self.reapplicationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
  }

  /// Test route for Phase 2; no UI or sensor network integration is included.
  func toggleTestSensorState() {
    (self.sensorSource as? ManualToggleSensorStateSource)?.toggle()
  }

  func setTestSensorState(_ state: AutomationLightState) {
    (self.sensorSource as? ManualToggleSensorStateSource)?.setState(state)
  }

  func clearTestSensorState() {
    (self.sensorSource as? ManualToggleSensorStateSource)?.clear()
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

  private func registerResumeObservers() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
      let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.requestReapplication(reason: "system wake")
      }
      self.wakeObserverTokens.append(token)
    }
  }

  private func registerDisplayReconfigurationCallback() {
    guard !self.displayCallbackRegistered else {
      return
    }
    let result = CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
      if flags.contains(.beginConfigurationFlag) {
        return
      }
      DispatchQueue.main.async {
        DisplayBrightnessController.shared.requestReapplication(reason: "display reconfiguration")
      }
    }, nil)
    if result == .success {
      self.displayCallbackRegistered = true
    } else {
      AutomationLogger.log("Could not register display reconfiguration callback: \(result.rawValue)")
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
    switch outcome {
    case .none:
      return
    case let .apply(state):
      guard self.applier.apply(state) else {
        AutomationLogger.log("No applicable display preset for \(state.rawValue); will retry")
        return
      }
      self.stateMachine.recordSuccessfulTransition(to: state, at: now)
      AutomationLogger.log("Applied \(state.rawValue) brightness preset")
    case let .reapply(state, sources):
      let includesManualOverride = sources.contains(.manualOverride)
      // A manual-release cause takes precedence over lifecycle-only waiting.
      let isLifecycleOnly = sources.contains(.lifecycleEvent) && !includesManualOverride
      if isLifecycleOnly {
        guard now >= self.reapplicationDebounceUntil else {
          return
        }
      }
      guard self.applier.apply(state) else {
        AutomationLogger.log("No applicable display preset for reapplication of \(state.rawValue); will retry")
        return
      }
      // Preserve lifecycle deduplication for trailing notifications in a merged request.
      if sources.contains(.lifecycleEvent) {
        self.lastLifecycleReapplication = (state, now)
      }
      self.stateMachine.recordSuccessfulReapplication(to: state, at: now)
      self.reapplicationWorkItem?.cancel()
      self.reapplicationWorkItem = nil
      AutomationLogger.log("Reapplied \(state.rawValue) brightness preset")
    }
  }
}
