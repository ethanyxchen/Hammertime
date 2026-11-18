import Foundation
import Testing

@testable import GitHubMaxxer

@MainActor
@Suite(.serialized)
struct TelemetryTests {
  @Test func aBuildWithoutAProjectTokenReportsNothing() async throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapturingProtocol.self]
    let telemetry = Telemetry(
      bundle: try appBundle([:]), defaults: defaults,
      session: URLSession(configuration: configuration))
    let sent = CapturingProtocol.requests.values.count

    await telemetry.reportIfDue(at: .now)

    #expect(CapturingProtocol.requests.values.count == sent)
  }

  @Test func reportsOncePerDayAsTheAppWithAStableAnonymousIdentifier() async throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapturingProtocol.self]
    let telemetry = Telemetry(
      bundle: try appBundle(["PostHogProjectToken": "phc_test"]), defaults: defaults,
      session: URLSession(configuration: configuration))
    let morning = Date(timeIntervalSince1970: 1_800_000_000)

    let sent = CapturingProtocol.requests.values.count

    await telemetry.reportIfDue(at: morning)
    await telemetry.reportIfDue(at: morning.addingTimeInterval(60))
    await telemetry.reportIfDue(at: morning.addingTimeInterval(86_400))

    let requests = CapturingProtocol.requests.values.dropFirst(sent)
    #expect(requests.count == 2)
    let bodies = try requests.map(requestBody)
    #expect(bodies.map { $0["event"] as? String } == ["app_active", "app_active"])
    #expect(bodies[0]["api_key"] as? String == "phc_test")
    #expect(bodies[0]["distinct_id"] as? String == bodies[1]["distinct_id"] as? String)
    let properties = try #require(bodies[0]["properties"] as? [String: Any])
    #expect(properties["$app_namespace"] as? String == "com.ethanyxchen.hammertime")
    #expect(properties["$app_name"] as? String == "Hammertime")
    #expect(properties["$app_version"] as? String == "1.2.3")
  }
}

private func appBundle(_ info: [String: String]) throws -> Bundle {
  let url = URL.temporaryDirectory.appending(path: "\(UUID()).app")
  try FileManager.default.createDirectory(
    at: url.appending(path: "Contents"), withIntermediateDirectories: true)
  try NSDictionary(
    dictionary: info.merging([
      "CFBundleIdentifier": "com.ethanyxchen.hammertime",
      "CFBundleName": "Hammertime",
      "CFBundleShortVersionString": "1.2.3",
    ]) { $1 }
  ).write(to: url.appending(path: "Contents/Info.plist"))
  return try #require(Bundle(url: url))
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
