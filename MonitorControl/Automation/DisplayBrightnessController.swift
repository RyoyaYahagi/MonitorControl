import Cocoa
import Foundation

protocol AutomationBrightnessApplying: AnyObject {
  func apply(_ state: AutomationLightState) -> Bool
}

enum AutomationDisplayProvider {
  static func displays() -> [Display] {
    let manager = DisplayManager.shared
    let ddcDisplays: [Display] = manager.getDdcCapableDisplays()
    let builtInAppleDisplays: [Display] = manager.getAppleDisplays().filter {
      $0.isBuiltIn() && !$0.isDummy
    }
    return ddcDisplays + builtInAppleDisplays
  }
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
    let eligibleDisplays = AutomationDisplayProvider.displays().filter { display in
      if let otherDisplay = display as? OtherDisplay {
        return !otherDisplay.isSw()
          && !otherDisplay.readPrefAsBool(key: .forceSw)
          && !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness)
      }
      if let appleDisplay = display as? AppleDisplay {
        return appleDisplay.isBuiltIn() && !appleDisplay.isDummy
      }
      return false
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
      if let appleDisplay = display as? AppleDisplay {
        AutomationLogger.log("Applied \(state.rawValue) preset to built-in Apple display \(appleDisplay.identifier) (\(appleDisplay.name), \(appleDisplay.prefsId))")
      }
    }
    AutomationLogger.log("Applied \(state.rawValue) brightness preset on \(appliedCount) of \(eligibleDisplays.count) eligible displays")
    return appliedCount > 0
  }
}

final class DisplayBrightnessController {
  static let shared = DisplayBrightnessController()

  private let manualSensorSource: SensorStateSource
  private let timerSensorSource: SensorStateSource
  private let inputModeStore: AutomationInputModeStore
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
    timerSensorSource: SensorStateSource = TimerSensorStateSource(),
    inputModeStore: AutomationInputModeStore = AutomationInputModeStore(),
    manualObserver: ManualBrightnessChangeObserving = DDCManualBrightnessObserver(),
    presets: BrightnessPresetStore = BrightnessPresetStore()
  ) {
    self.manualSensorSource = sensorSource
    self.timerSensorSource = timerSensorSource
    self.inputModeStore = inputModeStore
    self.manualObserver = manualObserver
    self.applier = MonitorControlBrightnessApplier(presets: presets, manualObserver: manualObserver)
  }

  var currentInputMode: AutomationInputMode {
    self.inputModeStore.mode
  }

  var currentInputState: AutomationLightState? {
    self.activeSensorSource.readState()?.state
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

  /// Manual input route for the automation menu and Phase 2 tests.
  func toggleTestSensorState() {
    guard let source = self.manualSensorSource as? ManualToggleSensorStateSource else {
      return
    }
    self.setTestSensorState(source.state?.opposite ?? .day)
  }

  func setTestSensorState(_ state: AutomationLightState) {
    guard let source = self.manualSensorSource as? ManualToggleSensorStateSource else {
      return
    }
    self.updateInputMode(to: .manual)
    source.setState(state)
    self.applyExplicitlySelectedState(state, sourceDescription: "Manual sensor state")
  }

  func setInputMode(_ mode: AutomationInputMode) {
    self.updateInputMode(to: mode)
    guard mode == .timer else {
      return
    }
    guard let reading = self.timerSensorSource.readState() else {
      AutomationLogger.log("Timer input selected, but current state could not be determined")
      return
    }
    self.applyExplicitlySelectedState(reading.state, sourceDescription: "Timer input selected")
  }

  func timerScheduleDidChange() {
    guard self.inputModeStore.mode == .timer else {
      return
    }
    guard let reading = self.timerSensorSource.readState() else {
      AutomationLogger.log("Timer schedule changed, but current state could not be determined")
      return
    }
    self.applyExplicitlySelectedState(reading.state, sourceDescription: "Timer schedule changed")
  }

  func clearTestSensorState() {
    self.updateInputMode(to: .manual)
    (self.manualSensorSource as? ManualToggleSensorStateSource)?.clear()
  }

  private var activeSensorSource: SensorStateSource {
    self.inputModeStore.mode == .manual ? self.manualSensorSource : self.timerSensorSource
  }

  private func updateInputMode(to mode: AutomationInputMode) {
    let previousMode = self.inputModeStore.mode
    self.inputModeStore.mode = mode
    if previousMode != mode {
      AutomationLogger.log("Automation input mode changed from \(previousMode.rawValue) to \(mode.rawValue)")
    }
  }

  private func applyExplicitlySelectedState(_ state: AutomationLightState, sourceDescription: String) {
    self.stateMachine.prepareForExplicitStateSelection()
    let now = Date()
    let didApply = self.applier.apply(state)
    if didApply {
      self.stateMachine.recordSuccessfulTransition(to: state, at: now)
    }
    AutomationLogger.log("\(sourceDescription) \(state.rawValue); immediate preset application \(didApply ? "succeeded" : "failed")")
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
    let manualChange = self.manualObserver.detectManualBrightnessChange()
    let reading = self.activeSensorSource.readState()
    let now = Date()
    let outcome = self.stateMachine.evaluate(
      reading: reading,
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
