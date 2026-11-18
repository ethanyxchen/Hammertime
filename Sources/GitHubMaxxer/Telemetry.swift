import Foundation
import os

@MainActor
final class Telemetry {
  private static let endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")!
  private static let projectKey = "phc_oD466wk7pH93TruVPWHTEdAwMC57LJwoAJgZqgcHokYH"
  private static let identifierKey = "telemetryIdentifier"
  private static let reportedKey = "telemetryReported"

  private let defaults: UserDefaults
  private let session: URLSession
  private var task: Task<Void, Never>?

  init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
    self.defaults = defaults
    self.session = session
  }

  func start() {
    guard task == nil else { return }
    task = Task {
      while !Task.isCancelled {
        await reportIfDue(at: .now)
        do { try await Task.sleep(for: .seconds(3600)) } catch { return }
      }
    }
  }

  func reportIfDue(at date: Date) async {
    if let reported = defaults.object(forKey: Self.reportedKey) as? Date,
      Calendar.current.isDate(reported, inSameDayAs: date)
    {
      return
    }
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "api_key": Self.projectKey,
      "event": "app_active",
      "distinct_id": identifier,
      "properties": [
        "app": "hammertime",
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "unknown",
        "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "$process_person_profile": false,
      ],
    ])
    do {
      let (_, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
      defaults.set(date, forKey: Self.reportedKey)
    } catch {
      Logger.app.error(
        "Telemetry could not be sent: \(error.localizedDescription, privacy: .public)")
    }
  }

  private var identifier: String {
    if let identifier = defaults.string(forKey: Self.identifierKey) { return identifier }
    let identifier = UUID().uuidString
    defaults.set(identifier, forKey: Self.identifierKey)
    return identifier
  }
}
