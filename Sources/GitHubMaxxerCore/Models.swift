import Foundation

public struct GitHubProfile: Codable, Sendable, Hashable {
  public let id: String
  public let login: String
  public let name: String?
  public let avatarUrl: URL

  public init(id: String, login: String, name: String?, avatarUrl: URL) {
    self.id = id
    self.login = login
    self.name = name
    self.avatarUrl = avatarUrl
  }

  public var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? login }
}

public struct Repository: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let nameWithOwner: String
  public let isPrivate: Bool
  public let ownerKind: RepositoryOwnerKind?

  public init(
    id: String, nameWithOwner: String, isPrivate: Bool,
    ownerKind: RepositoryOwnerKind? = nil
  ) {
    self.id = id
    self.nameWithOwner = nameWithOwner
    self.isPrivate = isPrivate
    self.ownerKind = ownerKind
  }

  public var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
  public var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

public struct RepositoryOwnerKind: Codable, Sendable, Hashable {
  public let type: String

  public static let organization = Self(type: "Organization")

  public init(type: String) { self.type = type }

  private enum CodingKeys: String, CodingKey { case type = "__typename" }
}

public struct MergedPullRequest: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let title: String
  public let number: Int
  public let url: URL
  public let mergedAt: Date
  public let additions: Int
  public let deletions: Int
  public let repository: Repository

  public init(
    id: String, title: String, number: Int, url: URL, mergedAt: Date, additions: Int,
    deletions: Int, repository: Repository
  ) {
    self.id = id
    self.title = title
    self.number = number
    self.url = url
    self.mergedAt = mergedAt
    self.additions = additions
    self.deletions = deletions
    self.repository = repository
  }

  public var changedLines: Int { additions + deletions }
}

public struct GitHubSnapshot: Codable, Sendable {
  public var repositories: [Repository]
  public private(set) var pullRequests: [MergedPullRequest]
  public private(set) var fetchedAt: Date

  public init(
    repositories: [Repository], pullRequests: [MergedPullRequest], fetchedAt: Date
  ) {
    self.repositories = repositories
    self.pullRequests = pullRequests
    self.fetchedAt = fetchedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repositories = try container.decode([Repository].self, forKey: .repositories)
    guard let pulls = try? container.decode([MergedPullRequest].self, forKey: .pullRequests)
    else {
      pullRequests = []
      fetchedAt = .distantPast
      return
    }
    pullRequests = pulls
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
  }

  public var hasFetched: Bool { fetchedAt > .distantPast }

  public var visibleRepositories: [Repository] {
    var seen = Set<String>()
    return (repositories + pullRequests.map(\.repository)).filter { seen.insert($0.id).inserted }
      .sorted { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
  }

  public static let refreshOverlap: TimeInterval = 60 * 60

  public func refreshInterval(endingAt now: Date) -> DateInterval {
    let resumed = fetchedAt.addingTimeInterval(-Self.refreshOverlap)
    let start = max(resumed, Activity.historyInterval(endingAt: now).start)
    return DateInterval(start: min(start, now), end: now)
  }

  public mutating func record(_ pulls: [MergedPullRequest], mergedIn interval: DateInterval) {
    let history = Activity.historyInterval(endingAt: interval.end).start
    let refreshed = Set(pulls.map(\.id))
    pullRequests =
      pulls + pullRequests.filter { !refreshed.contains($0.id) && $0.mergedAt >= history }
    fetchedAt = interval.end
  }
}

public struct RepositoryScope: Codable, Sendable, Equatable {
  public var owners: Set<String>
  public var repositories: Set<String>

  public init(owners: Set<String> = [], repositories: Set<String> = []) {
    self.owners = owners
    self.repositories = repositories
  }

  public static func active(in pulls: [MergedPullRequest], login: String) -> RepositoryScope {
    RepositoryScope(owners: Set(pulls.map(\.repository.owner)).union([login]))
  }

  public func includes(_ repository: Repository) -> Bool {
    counts(repository.owner) || repositories.contains(repository.id)
  }

  public func counts(_ owner: String) -> Bool {
    owners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
  }

  public func counting(_ owner: String, _ counted: Bool, among available: [Repository])
    -> RepositoryScope
  {
    var scope = self
    scope.owners = owners.filter { $0.caseInsensitiveCompare(owner) != .orderedSame }
    if counted { scope.owners.insert(owner) }
    scope.repositories.subtract(available.owned(by: owner).map(\.id))
    return scope
  }

  public enum Coverage: CaseIterable, Sendable {
    case all, some, none
  }

  public func coverage(of owner: String, among available: [Repository]) -> Coverage {
    if counts(owner) { return .all }
    return available.owned(by: owner).contains { repositories.contains($0.id) } ? .some : .none
  }

  public func covering(_ owner: String, _ coverage: Coverage, among available: [Repository])
    -> RepositoryScope
  {
    switch coverage {
    case .all: return counting(owner, true, among: available)
    case .none: return counting(owner, false, among: available)
    case .some:
      guard counts(owner) else { return self }
      var scope = counting(owner, false, among: available)
      scope.repositories.formUnion(available.owned(by: owner).map(\.id))
      return scope
    }
  }
}

extension [Repository] {
  public func owned(by owner: String) -> [Repository] {
    filter { $0.owner.caseInsensitiveCompare(owner) == .orderedSame }
  }
}
