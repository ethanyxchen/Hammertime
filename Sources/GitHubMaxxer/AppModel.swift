import AppKit
import Foundation
import GitHubMaxxerCore
import Observation
import os

struct AccountConnection: Codable, Identifiable {
  let id: UUID
  var label: String
  var profile: GitHubProfile
  var scope: RepositoryScope
  var snapshot: GitHubSnapshot

  var profileURL: URL { URL(string: "https://github.com/\(profile.login)")! }
}

struct OrganizationPreferences: Codable, Equatable {
  var pinned: [String] = []
  var names: [String: String] = [:]

  static func key(_ organization: String) -> String { organization.lowercased() }

  var normalized: OrganizationPreferences {
    var seen = Set<String>()
    return OrganizationPreferences(
      pinned: pinned.map(Self.key).filter { seen.insert($0).inserted },
      names: Dictionary(names.map { (Self.key($0.key), $0.value) }) { first, _ in first })
  }
}

struct Landing: Equatable {
  static let celebration: TimeInterval = 2.5
  let pullRequests: Set<String>
  let date: Date
  let reveal: Date

  var slam: Date? { reveal > date ? date : nil }
}

extension Landing {
  init(_ arrived: Set<String>, joining previous: Landing?, since started: Date) {
    if let previous, previous.date >= started {
      self.init(
        pullRequests: previous.pullRequests.union(arrived), date: previous.date,
        reveal: previous.reveal)
    } else {
      let date = Date.now
      let delay =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Landing.celebration
      self.init(pullRequests: arrived, date: date, reveal: date.addingTimeInterval(delay))
    }
  }
}

enum WorkspaceColour: String, CaseIterable, Codable, Identifiable {
  case terracotta, ochre, plum, slate, rosewood, umber

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

struct Workspace: Codable, Equatable {
  var goals = Goals()
  var colour = WorkspaceColour.terracotta
}

struct Workspaces: Codable, Equatable {
  var personal = Workspace()
  var organizations: [String: Workspace] = [:]

  subscript(filter: ActivityFilter) -> Workspace? {
    get {
      switch filter {
      case .all: nil
      case .personal: personal
      case .organization(let owner): organizations[OrganizationPreferences.key(owner)]
      }
    }
    set {
      guard let newValue else { return }
      switch filter {
      case .all: return
      case .personal: personal = newValue
      case .organization(let owner): organizations[OrganizationPreferences.key(owner)] = newValue
      }
    }
  }

  var unusedColour: WorkspaceColour {
    let used = [personal.colour] + organizations.values.map(\.colour)
    return WorkspaceColour.allCases.min { colour, other in
      used.count { $0 == colour } < used.count { $0 == other }
    }!
  }
}

struct SyncedSettings: Codable, Equatable {
  static let file = "hammertime.json"
  static let description = "Hammertime settings"
  var workspaces: Workspaces
  var organizations: OrganizationPreferences
  var scopes: [String: RepositoryScope]
}

extension SyncedSettings {
  init(_ gist: Gist) throws {
    self = try JSONDecoder().decode(SyncedSettings.self, from: Data(gist.content.utf8))
  }

  func content() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

private struct SyncedGist: Codable {
  let account: UUID
  let gist: Gist
}

private struct SavedState: Codable {
  var workspaces = Workspaces()
  var connections: [AccountConnection] = []
  var organizations = OrganizationPreferences()
  var synced: SyncedGist?
}

extension SavedState {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaces = try container.decodeIfPresent(Workspaces.self, forKey: .workspaces) ?? Workspaces()
    connections = try container.decode([AccountConnection].self, forKey: .connections)
    organizations =
      try container.decodeIfPresent(OrganizationPreferences.self, forKey: .organizations)
      ?? OrganizationPreferences()
    synced = try container.decodeIfPresent(SyncedGist.self, forKey: .synced)
  }
}

@MainActor
@Observable
final class AppModel {
  var destination: Destination = .activity(.all)
  private(set) var connections: [AccountConnection] = []
  private(set) var workspaceSettings = Workspaces()
  private(set) var organizationPreferences = OrganizationPreferences()
  private(set) var isRefreshing = false
  private(set) var isConnecting = false
  private(set) var connectionErrors: [UUID: String] = [:]
  private(set) var storageError: String?
  private(set) var syncError: String?
  private(set) var now = Date.now
  private(set) var landing: Landing?
  private var held: Landing?
  private var isFocused = false
  let isPreview: Bool
  private let credentials: any CredentialStorage
  private let session: URLSession
  private let stateURL: URL
  private var refreshTask: Task<Void, Never>?
  private var synced: SyncedGist?
  private var syncTask: Task<Void, Never>?
  private var syncPending = false

  init(
    preview: Bool = false, stateURL: URL? = nil,
    credentials: any CredentialStorage = CredentialStore(),
    session: URLSession = .shared
  ) {
    isPreview = preview
    self.credentials = credentials
    self.session = session
    self.stateURL =
      stateURL
      ?? URL.applicationSupportDirectory
      .appending(path: "Hammertime", directoryHint: .isDirectory)
      .appending(path: "state.json")
    if preview {
      connections = PreviewData.connections(now: now)
      workspaceSettings.personal.goals = Goals(daily: 2)
      workspaceSettings.organizations["northstar"] = Workspace(
        goals: Goals(daily: 3), colour: .slate)
    } else if FileManager.default.fileExists(atPath: self.stateURL.path) {
      do {
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: self.stateURL))
        workspaceSettings = state.workspaces
        connections = state.connections
        organizationPreferences = state.organizations
        synced = state.synced
        reconcileOrganizations()
      } catch {
        storageError = "Saved activity could not be loaded. \(error.localizedDescription)"
      }
    }
  }

  var pullRequests: [MergedPullRequest] {
    let pending = landing.flatMap { $0.reveal > now ? $0.pullRequests : nil } ?? []
    let withheld = pending.union(held?.pullRequests ?? [])
    return merged.filter { !withheld.contains($0.id) }
  }

  var announced: [MergedPullRequest] {
    let ids = held?.pullRequests ?? []
    return merged.filter { ids.contains($0.id) }
  }

  var banner: Landing? { announced.isEmpty ? nil : held }

  var isWelcoming: Bool {
    connections.isEmpty
      || landing.map { $0.pullRequests.isEmpty && $0.slam != nil && $0.reveal > now } == true
  }

  private var merged: [MergedPullRequest] {
    let interval = Activity.historyInterval(endingAt: now)
    return Activity.mergedPullRequests(
      from: connections.map {
        ScopedActivity(pullRequests: $0.snapshot.pullRequests, scope: $0.scope)
      }
    ).filter { interval.contains($0.mergedAt) }
  }

  private var countedOwners: [String] {
    connections.flatMap { account in
      account.snapshot.visibleRepositories.filter(account.scope.includes).map(\.owner)
    }
  }

  private func isPersonal(_ owner: String) -> Bool {
    personalLogins.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
  }

  var organizations: [String] {
    let owners = countedOwners.filter { !isPersonal($0) }
    return Dictionary(owners.map { (OrganizationPreferences.key($0), $0) }) { first, _ in first }
      .values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  func isPerson(_ owner: String) -> Bool {
    connections.flatMap(\.snapshot.visibleRepositories).contains {
      $0.owner.caseInsensitiveCompare(owner) == .orderedSame && $0.ownerKind != .organization
    }
  }

  var sidebarOrganizations: [String] {
    organizationPreferences.pinned.compactMap { key in
      organizations.first { OrganizationPreferences.key($0) == key }
    } + organizations.filter { !isPinned($0) }
  }

  var countsPersonal: Bool { countedOwners.contains(where: isPersonal) }

  var opensWindowAtLaunch: Bool { connections.isEmpty || isPreview }

  var workspaces: [ActivityFilter] {
    (countsPersonal ? [.personal] : []) + sidebarOrganizations.map(ActivityFilter.organization)
  }

  var activities: [ActivityFilter] { [.all] + workspaces }

  func title(for filter: ActivityFilter) -> String {
    guard case .organization(let owner) = filter else { return filter.title }
    return displayName(for: owner)
  }

  func goals(for filter: ActivityFilter) -> Goals {
    switch filter {
    case .all: Goals(daily: workspaces.map { goals(for: $0).daily }.reduce(0, +))
    case .personal, .organization: workspaceSettings[filter]?.goals ?? Goals()
    }
  }

  func colour(for filter: ActivityFilter) -> WorkspaceColour? {
    workspaceSettings[filter]?.colour
  }

  func setDailyGoal(_ value: Int, for filter: ActivityFilter) {
    workspaceSettings[filter]?.goals = Goals(clamping: value)
    persist()
  }

  func setColour(_ colour: WorkspaceColour, for filter: ActivityFilter) {
    workspaceSettings[filter]?.colour = colour
    persist()
  }

  func displayName(for organization: String) -> String {
    organizationPreferences.names[OrganizationPreferences.key(organization)] ?? organization
  }

  func isPinned(_ organization: String) -> Bool {
    organizationPreferences.pinned.contains(OrganizationPreferences.key(organization))
  }

  func setPinned(_ pinned: Bool, organization: String) {
    let key = OrganizationPreferences.key(organization)
    organizationPreferences.pinned.removeAll { $0 == key }
    if pinned { organizationPreferences.pinned.append(key) }
    persist()
  }

  func setCounted(_ counted: Bool, owner: String, for id: UUID) {
    guard let account = connections.first(where: { $0.id == id }) else { return }
    setScope(
      account.scope.counting(owner, counted, among: account.snapshot.visibleRepositories), for: id)
  }

  func stopCounting(_ owner: String) {
    for account in connections { setCounted(false, owner: owner, for: account.id) }
  }

  func renameOrganization(_ organization: String, to name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    organizationPreferences.names[OrganizationPreferences.key(organization)] =
      name.isEmpty ? nil : name
    persist()
  }

  func pullRequests(for filter: ActivityFilter) -> [MergedPullRequest] {
    filter.pullRequests(in: pullRequests, personalLogins: personalLogins)
  }

  private var personalLogins: Set<String> { Set(connections.map(\.profile.login)) }

  var lastUpdated: Date? { connections.map { $0.snapshot.fetchedAt }.min() }
  var errors: [String] {
    [storageError, syncError].compactMap(\.self)
      + connections.compactMap { account in
        connectionErrors[account.id].map { "\(account.label): \($0)" }
      }
  }

  func progress(for period: GoalPeriod, filter: ActivityFilter = .all) -> GoalProgress {
    let pulls = filter.pullRequests(in: merged, personalLogins: personalLogins)
    return GoalProgress(
      count: period.pullRequests(in: pulls, now: now).count, target: goals(for: filter)[period])
  }

  func isReached(_ period: GoalPeriod, filter: ActivityFilter = .all) -> Bool {
    isReached(period, in: period.pullRequests(in: merged, now: now), filter: filter)
  }

  func isReached(_ period: GoalPeriod, in pulls: [MergedPullRequest], filter: ActivityFilter)
    -> Bool
  {
    goals(for: filter)[period] > 0
      && (filter == .all ? workspaces : [filter]).allSatisfy { workspace in
        workspace.pullRequests(in: pulls, personalLogins: personalLogins).count
          >= goals(for: workspace)[period]
      }
  }

  func setScope(_ scope: RepositoryScope, for id: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    connections[index].scope = scope
    persist()
  }

  func rename(_ label: String, id: UUID) {
    guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
    let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
    connections[index].label = name.isEmpty ? connections[index].profile.login : name
    persist()
  }

  func connect(token: String, replacing id: UUID? = nil) async throws {
    guard !isPreview else { return }
    guard !isConnecting else { throw ConnectionError.busy }
    isConnecting = true
    defer { isConnecting = false }
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let client = GitHubClient(token: token, session: session)
    let fetchedAt = Date.now
    async let pulls = client.mergedPullRequests(
      from: Activity.historyInterval(endingAt: fetchedAt).start, through: fetchedAt)
    let profile = try await client.profile()
    if let existing = connections.first(where: { $0.id == id }), existing.profile.id != profile.id {
      throw ConnectionError.wrongAccount(existing.profile.login)
    }
    let connectionID =
      id ?? connections.first { $0.profile.id == profile.id }?.id ?? UUID()
    let snapshot = GitHubSnapshot(
      repositories: connections.first { $0.id == connectionID }?.snapshot.repositories ?? [],
      pullRequests: try await pulls, fetchedAt: fetchedAt)
    try Task.checkCancellation()
    try credentials.save(token, for: connectionID)
    let isFirst = connections.isEmpty
    if let index = connections.firstIndex(where: { $0.id == connectionID }) {
      connections[index].profile = profile
      connections[index].snapshot = snapshot
    } else {
      connections.append(
        AccountConnection(
          id: connectionID, label: profile.login,
          profile: profile,
          scope: remoteSettings?.scopes[profile.id]
            ?? .active(in: snapshot.pullRequests, login: profile.login),
          snapshot: snapshot
        ))
    }
    connectionErrors[connectionID] = nil
    now = .now
    if isFirst { slam(Landing([], joining: nil, since: now)) }
    persist()
    Task { await refreshRepositories() }
  }

  func remove(_ id: UUID) throws {
    if !isPreview { try credentials.delete(for: id) }
    connections.removeAll { $0.id == id }
    connectionErrors[id] = nil
    persist()
  }

  func refresh() async {
    now = .now
    guard !isPreview, !isRefreshing, !isConnecting, !connections.isEmpty else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    let started = Date.now
    let results = await fetch { client, account in
      let interval = account.snapshot.refreshInterval(endingAt: started)
      return (
        interval, try await client.mergedPullRequests(from: interval.start, through: interval.end)
      )
    }
    for (id, result) in results {
      guard let index = connections.firstIndex(where: { $0.id == id }),
        connections[index].snapshot.fetchedAt <= started
      else { continue }
      switch result {
      case .success(let (interval, pulls)):
        let known = Set(merged.map(\.id))
        connections[index].snapshot.record(pulls, mergedIn: interval)
        land(Set(merged.map(\.id)).subtracting(known), since: started)
        connectionErrors[id] = nil
      case .failure(is CancellationError): return
      case .failure(let error): connectionErrors[id] = error.localizedDescription
      }
    }
    persist()
  }

  func refreshRepositories() async {
    guard !isPreview else { return }
    for (id, result) in await fetch({ client, _ in try await client.repositories() }) {
      guard let index = connections.firstIndex(where: { $0.id == id }) else { continue }
      switch result {
      case .success(let repositories): connections[index].snapshot.repositories = repositories
      case .failure(is CancellationError): return
      case .failure(let error): connectionErrors[id] = error.localizedDescription
      }
    }
    persist()
  }

  private func fetch<Value: Sendable>(
    _ request: @escaping @Sendable (GitHubClient, AccountConnection) async throws -> Value
  ) async -> [(UUID, Result<Value, any Error>)] {
    let session = session
    let accounts = connections.map { account in
      (account, Result { try credentials.read(for: account.id) })
    }
    return await withTaskGroup(of: (UUID, Result<Value, any Error>).self) { group in
      for (account, token) in accounts {
        group.addTask {
          do {
            let client = GitHubClient(token: try token.get(), session: session)
            return (account.id, .success(try await request(client, account)))
          } catch {
            return (account.id, .failure(error))
          }
        }
      }
      var results: [(UUID, Result<Value, any Error>)] = []
      for await result in group { results.append(result) }
      return results
    }
  }

  private func land(_ arrived: Set<String>, since started: Date) {
    guard !arrived.isEmpty else { return }
    guard isFocused else {
      held = Landing(arrived.union(held?.pullRequests ?? []), joining: held, since: started)
      Logger.merges.log("Holding \(arrived.count) merges for the banner")
      return
    }
    Logger.merges.log("Slamming \(arrived.count) merges in the window")
    slam(Landing(arrived, joining: landing, since: started))
  }

  private func slam(_ landing: Landing) {
    self.landing = landing
    Task {
      try? await Task.sleep(for: .seconds(max(0, landing.reveal.timeIntervalSinceNow)))
      now = .now
    }
  }

  func setFocused(_ focused: Bool) {
    isFocused = focused
    Logger.merges.log("Window focused: \(focused)")
    if focused { releaseBanner() }
  }

  func releaseBanner() {
    guard let held else { return }
    Logger.merges.log("Releasing banner")
    let date = Date.now
    self.held = nil
    landing = Landing(pullRequests: held.pullRequests, date: date, reveal: date)
    now = date
  }

  func startRefreshing() {
    guard refreshTask == nil, !isPreview else { return }
    refreshTask = Task { await runRefreshLoop() }
  }

  private func runRefreshLoop() async {
    await refresh()
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      await refresh()
    }
  }

  private func reconcileOrganizations() {
    organizationPreferences = organizationPreferences.normalized
    for organization in organizations where workspaceSettings[.organization(organization)] == nil {
      workspaceSettings.organizations[OrganizationPreferences.key(organization)] = Workspace(
        colour: workspaceSettings.unusedColour)
    }
  }

  func syncSettings() async {
    guard !isPreview else { return }
    syncPending = true
    let task =
      syncTask
      ?? Task {
        while syncPending {
          syncPending = false
          await exchangeSettings()
        }
        syncTask = nil
      }
    syncTask = task
    await task.value
  }

  private var remoteSettings: SyncedSettings? {
    synced.flatMap { try? SyncedSettings($0.gist) }
  }

  private func localSettings(keeping scopes: [String: RepositoryScope]) -> SyncedSettings {
    SyncedSettings(
      workspaces: workspaceSettings, organizations: organizationPreferences,
      scopes: scopes.merging(connections.map { ($0.profile.id, $0.scope) }) { $1 })
  }

  private func exchangeSettings() async {
    guard let primary = connections.first else {
      syncError = nil
      return
    }
    guard let token = try? credentials.read(for: primary.id) else { return }
    let client = GitHubClient(token: token, session: session)
    let known = synced?.account == primary.id ? synced?.gist : nil
    let scopes = remoteSettings?.scopes ?? [:]
    do {
      let gist = try await settingsGist(client, known: known, keeping: scopes)
      guard connections.first?.id == primary.id else { return }
      let settings = try? SyncedSettings(gist)
      let isNewer = known.map { $0.id != gist.id || gist.updatedAt > $0.updatedAt } ?? true
      if let settings, isNewer { apply(settings) }
      synced = SyncedGist(account: primary.id, gist: gist)
      let local = localSettings(keeping: settings?.scopes ?? scopes)
      if local != settings {
        let updated = try await client.updateGist(
          gist.id, file: SyncedSettings.file, content: try local.content())
        synced = SyncedGist(account: primary.id, gist: updated)
      }
      syncError = nil
      save()
    } catch {
      syncError = "Settings could not sync with GitHub. \(error.localizedDescription)"
    }
  }

  private func settingsGist(
    _ client: GitHubClient, known: Gist?, keeping scopes: [String: RepositoryScope]
  ) async throws -> Gist {
    if let known {
      do {
        return try await client.gist(known.id, file: SyncedSettings.file, ifNoneMatch: known.etag)
          ?? known
      } catch GitHubError.http(404), GitHubError.invalidResponse {}
    }
    if let found = try await client.gist(
      named: SyncedSettings.file, description: SyncedSettings.description)
    {
      return found
    }
    do {
      return try await client.createGist(
        file: SyncedSettings.file, content: try localSettings(keeping: scopes).content(),
        description: SyncedSettings.description)
    } catch GitHubError.http(404), GitHubError.forbidden {
      throw SyncError.gistAccess
    }
  }

  private func apply(_ settings: SyncedSettings) {
    workspaceSettings = settings.workspaces
    organizationPreferences = settings.organizations
    for index in connections.indices {
      if let scope = settings.scopes[connections[index].profile.id] {
        connections[index].scope = scope
      }
    }
    reconcileOrganizations()
  }

  private func persist() {
    save()
    Task { await syncSettings() }
  }

  private func save() {
    guard !isPreview else { return }
    reconcileOrganizations()
    do {
      let directory = stateURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let state = SavedState(
        workspaces: workspaceSettings, connections: connections,
        organizations: organizationPreferences, synced: synced)
      try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
      storageError = nil
    } catch {
      storageError = "Changes could not be saved. \(error.localizedDescription)"
    }
  }
}

private enum SyncError: LocalizedError {
  case gistAccess
  var errorDescription: String? {
    "It needs gist access. Run gh auth refresh -s gist, then reconnect the account."
  }
}

private enum ConnectionError: LocalizedError {
  case wrongAccount(String)
  case busy
  var errorDescription: String? {
    switch self {
    case .busy: "Another GitHub connection is loading. Wait for it to finish, then try again."
    case .wrongAccount(let login):
      "You signed in to a different account. Reconnect @\(login), or add it as a new connection."
    }
  }
}
