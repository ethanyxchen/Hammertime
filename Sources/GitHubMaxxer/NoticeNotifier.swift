import Foundation
import Observation
import UserNotifications

@MainActor
final class NoticeNotifier: NSObject, UNUserNotificationCenterDelegate {
  private static let category = "sign-in"
  private let model: AppModel
  private let center = UNUserNotificationCenter.current()
  private var posted: [String: Notice] = [:]

  init(model: AppModel) {
    self.model = model
    super.init()
    center.delegate = self
    center.removeAllDeliveredNotifications()
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.category,
        actions: [
          UNNotificationAction(
            identifier: Self.category, title: "Sign In Again", options: .foreground)
        ],
        intentIdentifiers: [])
    ])
    Task { [weak self] in
      for await notices in Observations({ model.notices.filter { $0.signIn != nil } }) {
        await self?.post(notices)
      }
    }
  }

  private func post(_ notices: [Notice]) async {
    let current = Set(notices.map(\.id))
    let cleared = posted.keys.filter { !current.contains($0) }
    center.removeDeliveredNotifications(withIdentifiers: cleared)
    for id in cleared { posted[id] = nil }
    for notice in notices where posted[notice.id] != notice {
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        continue
      }
      posted[notice.id] = notice
      let content = UNMutableNotificationContent()
      content.title = notice.title
      content.body = notice.detail
      content.categoryIdentifier = Self.category
      try? await center.add(
        UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let id = response.notification.request.identifier
    await MainActor.run {
      guard let notice = model.notices.first(where: { $0.id == id }) else { return }
      model.show(notice)
      NotificationCenter.default.post(name: .reopenHammertime, object: nil)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
}
