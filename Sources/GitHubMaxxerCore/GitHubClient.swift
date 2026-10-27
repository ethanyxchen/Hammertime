import Foundation

public struct GitHubClient: Sendable {
  private let token: String
  private let session: URLSession

  public init(token: String, session: URLSession = .shared) {
    self.token = token
    self.session = session
  }

  public func profile() async throws -> GitHubProfile {
    let response: ProfileResponse = try await query(
      "query { viewer { id login name avatarUrl } }", variables: EmptyVariables()
    )
    return response.viewer
  }

  public func repositories() async throws -> [Repository] {
    var cursor: String?
    var result: [Repository] = []
    repeat {
      let response: RepositoriesResponse = try await query(
        """
        query($after: String) {
          viewer {
            repositories(first: 100, after: $after, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
              nodes { id nameWithOwner isPrivate ownerKind: owner { __typename } }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """,
        variables: PageVariables(after: cursor)
      )
      result.append(contentsOf: response.viewer.repositories.nodes)
      cursor = try response.viewer.repositories.pageInfo.nextCursor(previous: cursor)
    } while cursor != nil
    return result
  }

  public func mergedPullRequests(from start: Date, through end: Date) async throws
    -> [MergedPullRequest]
  {
    let first = floor(start.timeIntervalSince1970)
    let last = floor(end.timeIntervalSince1970)
    return try await withThrowingTaskGroup { group in
      for lower in stride(from: first, through: last, by: Self.searchWindow) {
        group.addTask {
          try await mergedPullRequests(
            from: lower, through: min(lower + Self.searchWindow - 1, last))
        }
      }
      var result: [MergedPullRequest] = []
      for try await pulls in group { result += pulls }
      return result
    }
  }

  private static let searchWindow: TimeInterval = 2 * 24 * 60 * 60

  private func mergedPullRequests(from first: TimeInterval, through last: TimeInterval)
    async throws -> [MergedPullRequest]
  {
    let formatter = ISO8601DateFormatter()
    let range = [first, last].map { formatter.string(from: Date(timeIntervalSince1970: $0)) }
    let search = "is:pr is:merged author:@me merged:\(range[0])..\(range[1])"
    var cursor: String?
    var result: [MergedPullRequest] = []
    repeat {
      let response: SearchResponse = try await query(
        """
        query($query: String!, $after: String) {
          search(query: $query, type: ISSUE, first: 100, after: $after) {
            issueCount
            nodes {
              ... on PullRequest {
                id title number url mergedAt
                repository { id nameWithOwner isPrivate ownerKind: owner { __typename } }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        """,
        variables: SearchVariables(query: search, after: cursor)
      )
      if response.search.issueCount > 1_000 {
        guard last > first else { throw GitHubError.searchLimit }
        let middle = floor((first + last) / 2)
        async let earlier = mergedPullRequests(from: first, through: middle)
        async let later = mergedPullRequests(from: middle + 1, through: last)
        return try await earlier + later
      }
      result.append(contentsOf: response.search.nodes)
      cursor = try response.search.pageInfo.nextCursor(previous: cursor)
    } while cursor != nil
    return result
  }

  public func gist(named file: String, description: String) async throws -> Gist? {
    var page = 1
    while true {
      let (data, _) = try await send("gists?per_page=100&page=\(page)")
      let gists = try Self.decoder.decode([GistResponse].self, from: data)
      let match = gists.first { $0.files[file] != nil && $0.description == description }
      if let match {
        return try await gist(match.id, file: file)
      }
      guard gists.count == 100 else { return nil }
      page += 1
    }
  }

  public func gist(_ id: String, file: String, ifNoneMatch etag: String? = nil) async throws
    -> Gist?
  {
    let (data, response) = try await send(
      "gists/\(id)", headers: etag.map { ["If-None-Match": $0] } ?? [:])
    guard response.statusCode != 304 else { return nil }
    return try Gist(data, response, file: file)
  }

  public func createGist(file: String, content: String, description: String) async throws -> Gist {
    let body = GistRequest(
      description: description, public: false, files: [file: .init(content: content)])
    let (data, response) = try await send(
      "gists", method: "POST", body: JSONEncoder().encode(body))
    return try Gist(data, response, file: file)
  }

  public func updateGist(_ id: String, file: String, content: String) async throws -> Gist {
    let body = GistRequest(files: [file: .init(content: content)])
    let (data, response) = try await send(
      "gists/\(id)", method: "PATCH", body: JSONEncoder().encode(body))
    return try Gist(data, response, file: file)
  }

  public func icon(of repository: Repository) async throws -> Data? {
    let (data, _) = try await send("repos/\(repository.nameWithOwner)/git/trees/HEAD?recursive=1")
    let tree = try Self.decoder.decode(TreeResponse.self, from: data)
    guard let icon = RepositoryIcon.best(among: tree.tree.filter { $0.type == "blob" }) else {
      return nil
    }
    let path = icon.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? icon.path
    let (metadata, _) = try await send("repos/\(repository.nameWithOwner)/contents/\(path)")
    let file = try Self.decoder.decode(FileResponse.self, from: metadata)
    let (content, response) = try await session.data(from: file.downloadUrl)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw GitHubError.invalidResponse
    }
    return content
  }

  fileprivate static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func query<Response: Decodable & Sendable, Variables: Encodable & Sendable>(
    _ query: String, variables: Variables
  ) async throws -> Response {
    let (data, _) = try await send(
      "graphql", method: "POST",
      body: JSONEncoder().encode(GraphQLRequest(query: query, variables: variables)))
    let failures = try Self.decoder.decode(GraphQLFailures.self, from: data)
    if let error = failures.errors?.first {
      throw GitHubError.graphQL(error.message)
    }
    let envelope = try Self.decoder.decode(GraphQLResponse<Response>.self, from: data)
    guard let result = envelope.data else { throw GitHubError.invalidResponse }
    return result
  }

  private func send(
    _ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Hammertime", forHTTPHeaderField: "User-Agent")
    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    request.httpBody = body
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
    switch response.statusCode {
    case 200..<300, 304: return (data, response)
    case 401: throw GitHubError.unauthorized
    case 403, 429:
      if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        || response.statusCode == 429
      {
        throw GitHubError.rateLimited
      }
      throw GitHubError.forbidden
    default: throw GitHubError.http(response.statusCode)
    }
  }
}

public struct Gist: Codable, Sendable, Equatable {
  public let id: String
  public let content: String
  public let updatedAt: Date
  public let etag: String?

  init(_ data: Data, _ response: HTTPURLResponse, file: String) throws {
    let gist = try GitHubClient.decoder.decode(GistResponse.self, from: data)
    guard let content = gist.files[file]?.content else { throw GitHubError.invalidResponse }
    self.id = gist.id
    self.content = content
    self.updatedAt = gist.updatedAt
    self.etag = response.value(forHTTPHeaderField: "ETag")
  }
}

public enum GitHubError: LocalizedError, Sendable {
  case unauthorized, forbidden, rateLimited, invalidResponse, searchLimit
  case http(Int)
  case graphQL(String)

  public var errorDescription: String? {
    switch self {
    case .unauthorized: "GitHub rejected this connection. Sign in again."
    case .forbidden:
      "GitHub denied access. Check this connection's repository access and your organization's app approval or SSO authorization."
    case .rateLimited:
      "GitHub's request limit was reached. Your last activity is still available; try again later."
    case .invalidResponse: "GitHub returned an incomplete response. Try refreshing again."
    case .searchLimit:
      "Too many PRs were merged in a single search window. Activity could not be loaded completely."
    case .http(let status): "GitHub returned HTTP \(status). Try again later."
    case .graphQL(let message): "GitHub: \(message)"
    }
  }
}

private struct EmptyVariables: Encodable, Sendable {}
private struct PageVariables: Encodable, Sendable { let after: String? }
private struct SearchVariables: Encodable, Sendable {
  let query: String
  let after: String?
}
private struct GraphQLRequest<Variables: Encodable>: Encodable {
  let query: String
  let variables: Variables
}
private struct GraphQLResponse<Response: Decodable>: Decodable {
  let data: Response?
}
private struct GraphQLFailures: Decodable {
  let errors: [Failure]?
  struct Failure: Decodable { let message: String }
}
private struct PageInfo: Decodable, Sendable {
  let hasNextPage: Bool
  let endCursor: String?

  func nextCursor(previous: String?) throws -> String? {
    guard hasNextPage else { return nil }
    guard let endCursor, endCursor != previous else { throw GitHubError.invalidResponse }
    return endCursor
  }
}
private struct Page<Node: Decodable & Sendable>: Decodable, Sendable {
  let nodes: [Node]
  let pageInfo: PageInfo
}
private struct ProfileResponse: Decodable, Sendable { let viewer: GitHubProfile }
private struct RepositoriesResponse: Decodable, Sendable {
  let viewer: Viewer
  struct Viewer: Decodable, Sendable { let repositories: Page<Repository> }
}
private struct SearchResponse: Decodable, Sendable {
  let search: Search
  struct Search: Decodable, Sendable {
    let issueCount: Int
    let nodes: [MergedPullRequest]
    let pageInfo: PageInfo
  }
}
private struct TreeResponse: Decodable {
  let tree: [RepositoryFile]
}
private struct FileResponse: Decodable {
  let downloadUrl: URL
  enum CodingKeys: String, CodingKey { case downloadUrl = "download_url" }
}
private struct GistRequest: Encodable {
  var description: String?
  var `public`: Bool?
  let files: [String: File]
  struct File: Encodable { let content: String }
}
private struct GistResponse: Decodable {
  let id: String
  let description: String?
  let updatedAt: Date
  let files: [String: File]
  struct File: Decodable { let content: String? }
  enum CodingKeys: String, CodingKey {
    case id, description, files
    case updatedAt = "updated_at"
  }
}
