import ServiceManagement
import os

enum LoginItem {
  static let offeredKey = "loginItemOffered"

  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      Logger.app.error("Login item could not be changed: \(error.localizedDescription)")
    }
  }
}
