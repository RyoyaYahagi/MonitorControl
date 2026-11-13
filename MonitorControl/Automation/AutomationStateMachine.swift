import Foundation

enum AutomationLightState: String, CaseIterable {
  case day
  case night

  var opposite: AutomationLightState {
    self == .day ? .night : .day
  }
}

struct SensorStateReading {
  let state: AutomationLightState
  let sampledAt: Date
}

enum AutomationStateMachineOutcome {
  case none
  case apply(AutomationLightState)
  case reapply(AutomationLightState, sources: Set<AutomationReapplicationSource>)
}

enum AutomationReapplicationSource: Hashable {
  case manualOverride
  case lifecycleEvent
}

struct AutomationStateMachine {
  let confirmationCount = 3
  let switchCooldown: TimeInterval = 10 * 60
  let manualOverrideDuration: TimeInterval = 30 * 60
  let maximumSensorAge: TimeInterval = 10 * 60

  private(set) var activeState: AutomationLightState?
  private(set) var lastTransitionAt: Date?
  private(set) var pendingReapplicationSources = Set<AutomationReapplicationSource>()

  var hasPendingReapplication: Bool {
    !self.pendingReapplicationSources.isEmpty
  }

  var confirmedSensorState: AutomationLightState? {
    self.consecutiveCount >= self.confirmationCount ? self.candidateState : self.activeState
  }

  private var candidateState: AutomationLightState?
  private var consecutiveCount = 0
  private var lastKnownSensorState: AutomationLightState?
  private var manualOverrideStartedAt: Date?
  private var manualOverrideReferenceState: AutomationLightState?

  mutating func evaluate(
    reading: SensorStateReading?,
    now: Date,
    manualBrightnessChanged: Bool
  ) -> AutomationStateMachineOutcome {
    if manualBrightnessChanged, self.manualOverrideStartedAt == nil {
      self.manualOverrideStartedAt = now
      self.manualOverrideReferenceState = self.lastKnownSensorState ?? self.activeState
      AutomationLogger.log("Manual brightness change detected; automation paused")
    }

    guard let reading = reading,
          reading.sampledAt <= now,
          now.timeIntervalSince(reading.sampledAt) < self.maximumSensorAge else {
      self.candidateState = nil
      self.consecutiveCount = 0
      return .none
    }

    self.lastKnownSensorState = reading.state
    self.updateCandidate(with: reading.state)

    if let overrideStartedAt = self.manualOverrideStartedAt {
      let expired = now.timeIntervalSince(overrideStartedAt) >= self.manualOverrideDuration
      let sensorReversed: Bool
      if let referenceState = self.manualOverrideReferenceState {
        sensorReversed = reading.state != referenceState
      } else {
        self.manualOverrideReferenceState = reading.state
        sensorReversed = false
      }
      guard expired || sensorReversed else {
        return .none
      }
      self.manualOverrideStartedAt = nil
      self.manualOverrideReferenceState = nil
      self.candidateState = nil
      self.consecutiveCount = 0
      self.requestManualOverrideReapplication()
      AutomationLogger.log(expired ? "Manual pause expired" : "Sensor reversed; manual pause ended")
      return .none
    }

    let candidateIsConfirmed = self.consecutiveCount >= self.confirmationCount
    if candidateIsConfirmed, self.activeState != reading.state {
      if self.hasPendingReapplication {
        return .reapply(reading.state, sources: self.pendingReapplicationSources)
      }
      if let lastTransitionAt = self.lastTransitionAt,
         now.timeIntervalSince(lastTransitionAt) < self.switchCooldown {
        return .none
      }
      return .apply(reading.state)
    }

    if self.hasPendingReapplication, self.activeState == reading.state {
      return .reapply(reading.state, sources: self.pendingReapplicationSources)
    }
    return .none
  }

  mutating func requestLifecycleReapplication() {
    self.pendingReapplicationSources.insert(.lifecycleEvent)
  }

  private mutating func requestManualOverrideReapplication() {
    self.pendingReapplicationSources.insert(.manualOverride)
  }

  mutating func prepareForManualStateSelection() {
    self.manualOverrideStartedAt = nil
    self.manualOverrideReferenceState = nil
    self.pendingReapplicationSources.removeAll()
  }

  mutating func recordSuccessfulTransition(to state: AutomationLightState, at date: Date) {
    self.activeState = state
    self.lastTransitionAt = date
    self.pendingReapplicationSources.removeAll()
  }

  mutating func recordSuccessfulReapplication(to state: AutomationLightState, at date: Date) {
    if self.activeState != state {
      self.activeState = state
      self.lastTransitionAt = date
    }
    self.pendingReapplicationSources.removeAll()
  }

  private mutating func updateCandidate(with state: AutomationLightState) {
    if self.candidateState == state {
      self.consecutiveCount += 1
    } else {
      self.candidateState = state
      self.consecutiveCount = 1
    }
  }
}
