import Foundation
import os

extension Logger {
  static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "app")
  static let merges = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "merges")
}
