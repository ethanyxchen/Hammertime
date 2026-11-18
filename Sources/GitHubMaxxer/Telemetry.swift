import Foundation
import os

@MainActor
final class Telemetry {
  private static let endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")!
  private static let identifierKey = "telemetryIdentifier"
  private static let reportedKey = "telemetryReported"

  private let bundle: Bundle
  private let defaults: UserDefaults
  private let session: URLSession
  private var task: Task<Void, Never>?

  init(bundle: Bundle = .main, defaults: UserDefaults = .standard, session: URLSession = .shared) {
    self.bundle = bundle
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
    guard let projectToken = bundle.object(forInfoDictionaryKey: "PostHogProjectToken") as? String
    else { return }
    if let reported = defaults.object(forKey: Self.reportedKey) as? Date,
      Calendar.current.isDate(reported, inSameDayAs: date)
    {
      return
    }
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "api_key": projectToken,
      "event": "app_active",
      "distinct_id": identifier,
      "properties": properties,
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

  private var properties: [String: Any] {
    let system = ProcessInfo.processInfo.operatingSystemVersion
    var properties: [String: Any] = [
      "$os_name": "macOS",
      "$os_version": "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
      "$process_person_profile": false,
    ]
    properties["$app_namespace"] = bundle.bundleIdentifier
    properties["$app_name"] = bundle.object(forInfoDictionaryKey: "CFBundleName")
    properties["$app_version"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
    return properties
  }

  private var identifier: String {
    if let identifier = defaults.string(forKey: Self.identifierKey) { return identifier }
    let identifier = UUID().uuidString
    defaults.set(identifier, forKey: Self.identifierKey)
    return identifier
  }
}
