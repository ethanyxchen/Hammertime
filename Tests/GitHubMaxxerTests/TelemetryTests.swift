import Foundation
import Testing

@testable import GitHubMaxxer

@MainActor
struct TelemetryTests {
  @Test func reportsOncePerDayAsTheAppWithAStableAnonymousIdentifier() async throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapturingProtocol.self]
    let bundleURL = URL.temporaryDirectory.appending(path: "\(UUID()).app")
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    try FileManager.default.createDirectory(
      at: bundleURL.appending(path: "Contents"), withIntermediateDirectories: true)
    try NSDictionary(dictionary: [
      "CFBundleIdentifier": "com.ethanyxchen.hammertime",
      "CFBundleName": "Hammertime",
      "CFBundleShortVersionString": "1.2.3",
    ]).write(to: bundleURL.appending(path: "Contents/Info.plist"))
    let telemetry = Telemetry(
      bundle: try #require(Bundle(url: bundleURL)), defaults: defaults,
      session: URLSession(configuration: configuration))
    let morning = Date(timeIntervalSince1970: 1_800_000_000)

    await telemetry.reportIfDue(at: morning)
    await telemetry.reportIfDue(at: morning.addingTimeInterval(60))
    await telemetry.reportIfDue(at: morning.addingTimeInterval(86_400))

    let requests = CapturingProtocol.requests.values
    #expect(requests.count == 2)
    let bodies = try requests.map(requestBody)
    #expect(bodies.map { $0["event"] as? String } == ["app_active", "app_active"])
    #expect(bodies[0]["distinct_id"] as? String == bodies[1]["distinct_id"] as? String)
    let properties = try #require(bodies[0]["properties"] as? [String: Any])
    #expect(properties["$app_namespace"] as? String == "com.ethanyxchen.hammertime")
    #expect(properties["$app_name"] as? String == "Hammertime")
    #expect(properties["$app_version"] as? String == "1.2.3")
  }
}

private final class CapturingProtocol: URLProtocol, @unchecked Sendable {
  static let requests = LockedValues<URLRequest>()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests.append(request)
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"status\":1}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
