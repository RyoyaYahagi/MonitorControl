import Foundation
import os.log

enum AutomationLogger {
  private static let osLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "MonitorControl",
    category: "BrightnessAutomation"
  )

  static func log(_ message: String) {
    os_log("%{public}@", log: self.osLog, type: .info, message)
  }
}
