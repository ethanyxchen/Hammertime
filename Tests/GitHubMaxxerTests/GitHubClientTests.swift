import Foundation
import Testing

@testable import GitHubMaxxerCore

@Suite(.serialized)
struct GitHubClientTests {
  private func client(_ handler: @escaping @Sendable (URLRequest) throws -> StubResponse)
    -> GitHubClient
  {
    StubProtocol.handler.set(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return GitHubClient(token: "test-token", session: URLSession(configuration: configuration))
  }

  @Test func verifiesIdentityAndAuthorizationHeader() async throws {
    let client = client { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
      return StubResponse(
        body:
          "{\"data\":{\"viewer\":{\"id\":\"u1\",\"login\":\"alex\",\"name\":null,\"avatarUrl\":\"https://github.com/alex.png\"}}}"
      )
    }
    let profile = try await client.profile()
    #expect(profile.login == "alex")
    #expect(profile.displayName == "alex")
  }

  @Test func rejectsUnauthorizedCredential() async {
    let client = client { _ in StubResponse(status: 401, body: "{}") }
    await #expect(throws: GitHubError.self) { try await client.profile() }
  }

  @Test func rejectsPartialGraphQLData() async {
    let client = client { _ in
      StubResponse(
        body:
          "{\"data\":{\"viewer\":{\"id\":\"u1\",\"login\":\"alex\",\"name\":null,\"avatarUrl\":\"https://github.com/alex.png\"}},\"errors\":[{\"message\":\"Access denied\"}]}"
      )
    }
    await #expect(throws: GitHubError.self) { try await client.profile() }
  }

  @Test func paginatesRepositories() async throws {
    let client = client { request in
      let body = try requestBody(request)
      #expect((body["query"] as! String).contains("ownerKind: owner { __typename }"))
      let after = (body["variables"] as? [String: Any])?["after"] as? String
      let id = after == nil ? "r1" : "r2"
      let next = after == nil ? "\"repo-page-2\"" : "null"
      return StubResponse(
        body:
          "{\"data\":{\"viewer\":{\"repositories\":{\"nodes\":[\(repositoryJSON(id))],\"pageInfo\":{\"hasNextPage\":\(after == nil),\"endCursor\":\(next)}}}}}"
      )
    }
    let repositories = try await client.repositories()
    #expect(repositories.map(\.id) == ["r1", "r2"])
    #expect(repositories.allSatisfy { $0.ownerKind == .organization })
  }

  @Test func paginatesMergedPullRequestsOfTheSignedInAccount() async throws {
    let client = client { request in
      let body = try requestBody(request)
      let variables = body["variables"] as! [String: Any]
      #expect((variables["query"] as! String).contains("author:@me"))
      let after = variables["after"] as? String
      return searchResponse(
        count: 2, nodes: [pullJSON(after == nil ? "p1" : "p2")],
        next: after == nil ? "pull-page-2" : nil)
    }
    let pulls = try await client.mergedPullRequests(
      from: fixedNow.addingTimeInterval(-3600), through: fixedNow)
    #expect(pulls.map(\.id) == ["p1", "p2"])
    #expect(pulls.allSatisfy { $0.repository.ownerKind == .organization })
  }

  @Test func searchesHistoryInParallelWindowsAndSplitsCrowdedOnes() async throws {
    let searches = LockedValues<String>()
    let client = client { request in
      let search = (try requestBody(request)["variables"] as! [String: Any])["query"] as! String
      let index = searches.append(search)
      return index == 0
        ? searchResponse(count: 1_001, nodes: [])
        : searchResponse(count: 1, nodes: [pullJSON("p\(index)")])
    }
    let start = Activity.historyInterval(endingAt: fixedNow).start
    let pulls = try await client.mergedPullRequests(from: start, through: fixedNow)
    let ranges = searches.values.map(mergedRange)
    let split = ranges[0]
    let leaves = ranges.dropFirst().sorted { $0.start < $1.start }
    #expect(pulls.count == leaves.count)
    #expect(ranges.count > 40)
    #expect(leaves.filter { split.contains($0.start) }.count == 2)
    #expect(leaves.first!.start == start)
    #expect(leaves.last!.end == fixedNow)
    #expect(zip(leaves, leaves.dropFirst()).allSatisfy { $1.start == $0.end.addingTimeInterval(1) })
    #expect(leaves.allSatisfy { $0.duration < 2 * 24 * 60 * 60 })
  }

  @Test func rejectsMissingPaginationCursor() async {
    let client = client { _ in
      StubResponse(
        body:
          "{\"data\":{\"viewer\":{\"repositories\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":null}}}}}"
      )
    }
    await #expect(throws: GitHubError.self) { try await client.repositories() }
  }

  @Test func downloadsTheRepositoryIconThroughItsDownloadURL() async throws {
    let client = client { request in
      switch request.url!.path() {
      case "/repos/acme/r1/git/trees/HEAD":
        #expect(request.url!.query() == "recursive=1")
        return StubResponse(
          body:
            "{\"tree\":[{\"path\":\"Resources\",\"type\":\"tree\"},{\"path\":\"Resources/App Icon.icns\",\"type\":\"blob\",\"size\":9}]}"
        )
      case "/repos/acme/r1/contents/Resources/App%20Icon.icns":
        return StubResponse(
          body:
            "{\"download_url\":\"https://media.githubusercontent.com/media/acme/r1/main/Resources/App%20Icon.icns?token=lfs\"}"
        )
      case "/media/acme/r1/main/Resources/App%20Icon.icns":
        #expect(request.url!.query() == "token=lfs")
        return StubResponse(body: "icon-data")
      default:
        Issue.record("Unexpected request \(request.url!)")
        return StubResponse(status: 404, body: "{}")
      }
    }
    let repository = Repository(id: "r1", nameWithOwner: "acme/r1", isPrivate: false)
    #expect(try await client.icon(of: repository) == Data("icon-data".utf8))
  }

  @Test func findsNoIconInARepositoryWithout() async throws {
    let client = client { _ in
      StubResponse(body: "{\"tree\":[{\"path\":\"README.md\",\"type\":\"blob\",\"size\":9}]}")
    }
    let repository = Repository(id: "r1", nameWithOwner: "acme/r1", isPrivate: false)
    #expect(try await client.icon(of: repository) == nil)
  }
}

private let fixedNow = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!

private func mergedRange(_ search: String) -> DateInterval {
  let bounds = search.split(separator: " ").first { $0.hasPrefix("merged:") }!
    .dropFirst(7).components(separatedBy: "..")
  let formatter = ISO8601DateFormatter()
  return DateInterval(
    start: formatter.date(from: bounds[0])!, end: formatter.date(from: bounds[1])!)
}

private func repositoryJSON(_ id: String) -> String {
  "{\"id\":\"\(id)\",\"nameWithOwner\":\"acme/\(id)\",\"isPrivate\":false,\"ownerKind\":{\"__typename\":\"Organization\"}}"
}

private func pullJSON(_ id: String) -> String {
  "{\"id\":\"\(id)\",\"title\":\"Improve search\",\"number\":42,\"url\":\"https://github.com/acme/r1/pull/42\",\"mergedAt\":\"2026-09-30T10:00:00Z\",\"repository\":\(repositoryJSON("r1"))}"
}

private func searchResponse(count: Int, nodes: [String], next: String? = nil) -> StubResponse {
  let cursor = next.map { "\"\($0)\"" } ?? "null"
  return StubResponse(
    body:
      "{\"data\":{\"search\":{\"issueCount\":\(count),\"nodes\":[\(nodes.joined(separator: ","))],\"pageInfo\":{\"hasNextPage\":\(next != nil),\"endCursor\":\(cursor)}}}}"
  )
}

func requestBody(_ request: URLRequest) throws -> [String: Any] {
  let data: Data
  if let body = request.httpBody {
    data = body
  } else if let stream = request.httpBodyStream {
    stream.open()
    defer { stream.close() }
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      collected.append(buffer, count: read)
    }
    data = collected
  } else {
    data = Data()
  }
  return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private struct StubResponse: Sendable {
  var status = 200
  var body: String
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Value] = []
  var values: [Value] { lock.withLock { stored } }
  func append(_ value: Value) -> Int {
    lock.withLock {
      let index = stored.count
      stored.append(value)
      return index
    }
  }
}

private final class StubHandler: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (URLRequest) throws -> StubResponse)?
  func set(_ handler: @escaping @Sendable (URLRequest) throws -> StubResponse) {
    lock.withLock { self.handler = handler }
  }
  func call(_ request: URLRequest) throws -> StubResponse {
    try lock.withLock { try handler!(request) }
  }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  static let handler = StubHandler()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let response = try Self.handler.call(request)
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(response.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
