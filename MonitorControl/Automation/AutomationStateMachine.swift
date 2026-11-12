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
}

struct AutomationStateMachine {
  let confirmationCount = 3
  let switchCooldown: TimeInterval = 10 * 60
  let manualOverrideDuration: TimeInterval = 30 * 60
  let maximumSensorAge: TimeInterval = 2 * 60

  private(set) var activeState: AutomationLightState?
  private(set) var lastTransitionAt: Date?

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
          now.timeIntervalSince(reading.sampledAt) <= self.maximumSensorAge else {
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
      AutomationLogger.log(expired ? "Manual pause expired" : "Sensor reversed; manual pause ended")
      return .none
    }

    guard self.consecutiveCount >= self.confirmationCount,
          self.activeState != reading.state else {
      return .none
    }
    if let lastTransitionAt = self.lastTransitionAt,
       now.timeIntervalSince(lastTransitionAt) < self.switchCooldown {
      return .none
    }
    return .apply(reading.state)
  }

  mutating func recordSuccessfulTransition(to state: AutomationLightState, at date: Date) {
    self.activeState = state
    self.lastTransitionAt = date
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
