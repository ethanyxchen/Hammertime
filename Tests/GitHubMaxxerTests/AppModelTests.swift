import AppKit
import Foundation
import GitHubMaxxerCore
import Testing

@testable import GitHubMaxxer

@MainActor
struct AppModelTests {
  @Test func signingInAgainUpdatesAccountByGitHubID() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile,
      scope: RepositoryScope(allRepositories: false, owners: ["northstar"]),
      snapshot: sample.snapshot)
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("oauth-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SignedInProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))

    try await model.connect(token: "cli-credential")

    #expect(model.connections.count == 1)
    #expect(model.connections[0].id == connection.id)
    #expect(model.connections[0].profile.login == "renamed-user")
    #expect(model.connections[0].scope == connection.scope)
    #expect(model.connections[0].label == connection.label)
    #expect(!connection.snapshot.repositories.isEmpty)
    #expect(model.connections[0].snapshot.repositories == connection.snapshot.repositories)
    #expect(try store.read(for: connection.id) == "cli-credential")
    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.connections.count == 1)
    #expect(reloaded.connections[0].id == connection.id)
  }

  @Test func firstConnectionSlamsTheWelcomeScreen() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SignedInProtocol.self]
    let model = AppModel(
      stateURL: directory.appending(path: "state.json"), credentials: TestCredentials(),
      session: URLSession(configuration: configuration))

    try await model.connect(token: "cli-credential")

    #expect(model.connections[0].label == model.connections[0].profile.login)
    #expect(
      model.connections[0].scope
        == RepositoryScope(allRepositories: false, owners: ["renamed-user"]))
    let landing = try #require(model.landing)
    #expect(landing.pullRequests.isEmpty)
    #expect(model.isWelcoming == (landing.slam != nil))

    try await model.connect(token: "cli-credential")

    #expect(model.landing == landing)
  }

  @Test func dailyGoalUpdatesWeeklyAndMonthlyTargets() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let model = AppModel(stateURL: url, credentials: TestCredentials())
    model.setDailyGoal(3, for: .personal)
    #expect(model.progress(for: .day, filter: .personal).target == 3)
    #expect(model.progress(for: .week, filter: .personal).target == 15)
    #expect(model.progress(for: .month, filter: .personal).target == 60)
    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.goals(for: .personal) == Goals(daily: 3))
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let personal = (state["workspaces"] as! [String: Any])["personal"] as! [String: Any]
    #expect(Set((personal["goals"] as! [String: Any]).keys) == ["daily"])
  }

  @Test func organisationsKeepTheColourTheyFirstReceive() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["beta/app", "acme/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false, ownerKind: .organization)
    }
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile, scope: RepositoryScope(),
      snapshot: GitHubSnapshot(
        repositories: [], pullRequests: repositories.map(mergedPullRequest), fetchedAt: .now))
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())

    #expect(model.colour(for: .personal) == .terracotta)
    #expect(model.colour(for: .organization("acme")) == .ochre)
    #expect(model.colour(for: .organization("beta")) == .plum)
    #expect(model.colour(for: .all) == nil)

    model.setColour(.slate, for: .organization("ACME"))
    model.setPinned(true, organization: "beta")

    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.colour(for: .organization("acme")) == .slate)
    #expect(reloaded.colour(for: .organization("beta")) == .plum)
    #expect(reloaded.colour(for: .personal) == .terracotta)
  }

  @Test func allActivityTargetSumsEachOrganisationsTarget() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["acme/app", "beta/app", "gone/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false, ownerKind: .organization)
    }
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile,
      scope: RepositoryScope(
        allRepositories: false, owners: ["acme", "beta", sample.profile.login]),
      snapshot: GitHubSnapshot(
        repositories: [
          Repository(
            id: "\(sample.profile.login)/app", nameWithOwner: "\(sample.profile.login)/app",
            isPrivate: false)
        ],
        pullRequests: repositories.map(mergedPullRequest), fetchedAt: .now))
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())

    model.setDailyGoal(2, for: .personal)
    model.setDailyGoal(4, for: .organization("ACME"))
    model.setDailyGoal(0, for: .organization("beta"))
    model.setDailyGoal(9, for: .organization("gone"))
    model.stopCounting("acme")
    model.setDailyGoal(50, for: .all)

    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.workspaces == [.personal, .organization("beta")])
    #expect(reloaded.goals(for: .organization("acme")) == Goals(daily: 4))
    #expect(reloaded.goals(for: .organization("beta")) == Goals(daily: 0))
    #expect(reloaded.goals(for: .all) == Goals(daily: 2))
    #expect(reloaded.progress(for: .month).target == 40)

    reloaded.setCounted(true, owner: "acme", for: connection.id)
    #expect(reloaded.goals(for: .all) == Goals(daily: 6))
    #expect(reloaded.progress(for: .week, filter: .organization("acme")).target == 20)
  }

  @Test func previewSeparatesOrganizationAndPersonalActivity() {
    let model = AppModel(preview: true)
    #expect(model.organizations == ["northstar"])
    let work = model.pullRequests(for: .organization("northstar"))
    let personal = model.pullRequests(for: .personal)
    #expect(!work.isEmpty)
    #expect(!personal.isEmpty)
    #expect(work.count + personal.count == model.pullRequests.count)
    #expect(
      model.progress(for: .month, filter: .organization("northstar")).count
        == GoalPeriod.month.count(in: work, now: model.now))
  }

  @Test func allActivityIsReachedOnlyWhenEveryWorkspaceTargetIsMet() throws {
    let model = AppModel(preview: true)
    let pulls = model.pullRequests
    let work = model.pullRequests(for: .organization("northstar")).count
    try #require(model.pullRequests(for: .personal).count >= 2)
    model.setDailyGoal(1, for: .personal)
    model.setDailyGoal(work + 1, for: .organization("northstar"))
    #expect(pulls.count >= model.goals(for: .all).daily)
    #expect(!model.isReached(.day, in: pulls, filter: .all))
    #expect(model.isReached(.day, in: pulls, filter: .personal))
    model.setDailyGoal(work, for: .organization("northstar"))
    #expect(model.isReached(.day, in: pulls, filter: .all))
  }

  @Test func sidebarOrganizationsKeepPinsCountedOwnersAndLocalNames() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["acme/app", "beta/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false, ownerKind: .organization)
    }
    let pulls = repositories.map(mergedPullRequest)
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile, scope: RepositoryScope(),
      snapshot: GitHubSnapshot(repositories: [], pullRequests: pulls, fetchedAt: .now))
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(model.sidebarOrganizations == ["acme", "beta"])

    model.setPinned(true, organization: "beta")
    model.renameOrganization("acme", to: "  Acme Inc  ")
    #expect(model.sidebarOrganizations == ["beta", "acme"])
    #expect(model.displayName(for: "acme") == "Acme Inc")
    model.stopCounting("beta")
    #expect(model.sidebarOrganizations == ["acme"])

    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.sidebarOrganizations == ["acme"])
    #expect(reloaded.isPinned("beta"))
    #expect(reloaded.pullRequests(for: .all) == [pulls[0]])
    #expect(reloaded.progress(for: .day).count == 1)
    #expect(reloaded.displayName(for: "acme") == "Acme Inc")
    reloaded.renameOrganization("acme", to: " ")
    reloaded.setCounted(true, owner: "beta", for: connection.id)
    #expect(Set(reloaded.pullRequests(for: .all)) == Set(pulls))
    #expect(reloaded.displayName(for: "acme") == "acme")
    #expect(reloaded.sidebarOrganizations == ["beta", "acme"])
  }

  @Test func personalIsAWorkspaceOnlyWhileAConnectedLoginsRepositoryCounts() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["acme/app", "\(sample.profile.login)/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false)
    }
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile,
      scope: RepositoryScope(allRepositories: false, owners: ["acme"]),
      snapshot: GitHubSnapshot(
        repositories: repositories, pullRequests: repositories.map(mergedPullRequest),
        fetchedAt: .now))
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())
    model.setDailyGoal(2, for: .personal)
    model.setDailyGoal(1, for: .organization("acme"))

    #expect(model.workspaces == [.organization("acme")])
    #expect(model.goals(for: .all) == Goals(daily: 1))

    model.setCounted(true, owner: sample.profile.login.uppercased(), for: connection.id)
    #expect(model.workspaces == [.personal, .organization("acme")])
    #expect(model.goals(for: .all) == Goals(daily: 3))

    model.setCounted(false, owner: sample.profile.login, for: connection.id)
    #expect(model.workspaces == [.organization("acme")])
    var scope = try #require(model.connections.first).scope
    scope.repositories.insert(repositories[1].id)
    model.setScope(scope, for: connection.id)
    #expect(model.workspaces == [.personal, .organization("acme")])
  }

  @Test func sidebarListsCountedOrganizationsWithOrWithoutMergedPullRequests() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["acme/app", "quiet/app", "other/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false, ownerKind: .organization)
    }
    let people = [sample.profile.login, "friend"].map {
      Repository(id: "\($0)/app", nameWithOwner: "\($0)/app", isPrivate: false)
    }
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile,
      scope: RepositoryScope(
        allRepositories: false, owners: ["acme", "quiet", "friend", sample.profile.login]),
      snapshot: GitHubSnapshot(
        repositories: repositories + people,
        pullRequests: [mergedPullRequest(in: repositories[0])], fetchedAt: .now))
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())

    #expect(model.sidebarOrganizations == ["acme", "friend", "quiet"])
    #expect(model.isPerson("Friend"))
    #expect(!model.isPerson("acme"))
  }

  @Test func organizationPreferencesIgnoreOwnerCase() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repositories = ["acme/app", "beta/app", "Beta/tools"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false, ownerKind: .organization)
    }
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile, scope: RepositoryScope(),
      snapshot: GitHubSnapshot(
        repositories: [], pullRequests: repositories.map(mergedPullRequest), fetchedAt: .now))
    let saved = OrganizationPreferences(
      pinned: ["Beta"], names: ["Beta": "Beta Labs"])
    try JSONEncoder().encode(
      FixtureState(connections: [connection], organizations: saved)
    ).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())

    #expect(model.isPinned("beta"))
    #expect(model.displayName(for: "beta") == "Beta Labs")
    #expect(model.sidebarOrganizations == ["beta", "acme"])

    model.stopCounting("ACME")
    #expect(model.sidebarOrganizations == ["beta"])
    model.setPinned(false, organization: "BETA")
    model.setCounted(true, owner: "Acme", for: connection.id)
    model.renameOrganization("BeTa", to: "")
    #expect(!model.isPinned("beta"))
    #expect(model.displayName(for: "beta") == "beta")
    #expect(model.sidebarOrganizations == ["acme", "beta"])
  }

  @Test func organizationPreferencesOutliveOrganizationsThatDisappear() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let repository = Repository(
      id: "acme/app", nameWithOwner: "acme/app", isPrivate: false, ownerKind: .organization)
    let connection = AccountConnection(
      id: UUID(), label: "Work", profile: sample.profile,
      scope: RepositoryScope(allRepositories: false),
      snapshot: GitHubSnapshot(repositories: [repository], pullRequests: [], fetchedAt: .now))
    let saved = OrganizationPreferences(
      pinned: ["acme", "gone"], names: ["acme": "Acme", "gone": "Gone"])
    try JSONEncoder().encode(
      FixtureState(connections: [connection], organizations: saved)
    ).write(to: url)
    let model = AppModel(stateURL: url, credentials: TestCredentials())

    model.setDailyGoal(2, for: .personal)

    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.organizationPreferences == saved)
  }

  @Test func syncCreatesTheGistFromLocalSettingsAndPushesChanges() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, connection, token) = try syncingModel(in: directory)

    model.setDailyGoal(3, for: .personal)
    await model.syncSettings()

    let created = try #require(GistProtocol.settings(for: token))
    #expect(created.workspaces.personal.goals == Goals(daily: 3))
    #expect(created.scopes == [connection.profile.id: connection.scope])

    model.setDailyGoal(5, for: .personal)
    await model.syncSettings()

    #expect(GistProtocol.settings(for: token)?.workspaces.personal.goals == Goals(daily: 5))
    #expect(GistProtocol.gists.values.count { $0.token == token } == 1)

    GistProtocol.emptyFiles(for: token)
    model.setDailyGoal(6, for: .personal)
    await model.syncSettings()

    #expect(GistProtocol.settings(for: token)?.workspaces.personal.goals == Goals(daily: 6))

    GistProtocol.delete(for: token)
    model.setDailyGoal(7, for: .personal)
    await model.syncSettings()

    #expect(GistProtocol.settings(for: token)?.workspaces.personal.goals == Goals(daily: 7))
    #expect(model.errors.isEmpty)
  }

  @Test func syncReplacesAnUnreadableGistAndLeavesUnrelatedGistsAlone() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, token) = try syncingModel(in: directory)
    let unrelated = GistProtocol.publish("notes", for: token, description: "My notes")
    let unreadable = GistProtocol.publish("{\"goals\": 3}", for: token)

    model.setDailyGoal(2, for: .personal)
    await model.syncSettings()

    #expect(GistProtocol.gists[unrelated]?.content == "notes")
    #expect(GistProtocol.gists.count { $0.value.token == token } == 2)
    #expect(GistProtocol.settings(for: token)?.workspaces.personal.goals == Goals(daily: 2))
    #expect(GistProtocol.gists[unreadable] != nil)
    #expect(model.errors.isEmpty)
  }

  @Test func gistSettingsWinTheFirstSyncAndKeepWhatThisMacCannotSee() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, connection, token) = try syncingModel(in: directory)
    let scope = RepositoryScope(allRepositories: false, owners: ["acme"])
    let elsewhere = RepositoryScope(allRepositories: false, owners: ["elsewhere"])
    var remote = SyncedSettings(
      workspaces: Workspaces(
        personal: Workspace(goals: Goals(daily: 4), colour: .plum),
        organizations: ["elsewhere": Workspace(goals: Goals(daily: 7), colour: .umber)]),
      organizations: OrganizationPreferences(pinned: ["elsewhere"], names: ["elsewhere": "Far"]),
      scopes: [connection.profile.id: scope, "other-account": elsewhere])
    GistProtocol.publish(remote, for: token)

    await model.syncSettings()

    #expect(model.goals(for: .personal) == Goals(daily: 4))
    #expect(model.colour(for: .personal) == .plum)
    #expect(model.connections[0].scope == scope)

    model.setDailyGoal(6, for: .personal)
    await model.syncSettings()

    remote.workspaces.personal.goals = Goals(daily: 6)
    #expect(GistProtocol.settings(for: token) == remote)

    remote.workspaces.personal.goals = Goals(daily: 8)
    GistProtocol.publish(remote, for: token)
    await model.syncSettings()

    #expect(model.goals(for: .personal) == Goals(daily: 8))
    let reloaded = AppModel(
      stateURL: directory.appending(path: "state.json"), credentials: TestCredentials())
    #expect(reloaded.goals(for: .personal) == Goals(daily: 8))

    GistProtocol.delete(for: token)
    model.setDailyGoal(9, for: .personal)
    await model.syncSettings()

    remote.workspaces.personal.goals = Goals(daily: 9)
    #expect(GistProtocol.settings(for: token) == remote)
    #expect(model.errors.isEmpty)
  }

  @Test func goalsSurviveRelaunchAndStayInRange() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let model = AppModel(stateURL: url, credentials: TestCredentials())
    model.setDailyGoal(-4, for: .personal)
    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.goals(for: .personal) == Goals(daily: 0))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func previewNeverWritesAccountState() {
    let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(
      path: "state.json")
    let model = AppModel(preview: true, stateURL: url, credentials: TestCredentials())
    model.setDailyGoal(3, for: .personal)
    model.setScope(RepositoryScope(allRepositories: false), for: model.connections[0].id)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func disconnectRemovesCredentialAndSavedActivity() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let model = AppModel(stateURL: url, credentials: store)

    try model.remove(connection.id)

    #expect(model.connections.isEmpty)
    #expect(store.tokens[connection.id] == nil)
    #expect(AppModel(stateURL: url, credentials: store).connections.isEmpty)
  }

  @Test func failedRefreshPreservesSnapshotAndReportsError() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connections = PreviewData.connections(now: .now)
    let state = FixtureState(connections: connections)
    try JSONEncoder().encode(state).write(to: url)
    let store = TestCredentials()
    let id = connections[0].id
    try store.save("test-credential", for: id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UnavailableProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    let before = model.pullRequests
    let updated = model.lastUpdated
    await model.refresh()
    #expect(model.pullRequests == before)
    #expect(model.lastUpdated == updated)
    #expect(model.connectionErrors[id]?.contains("503") == true)
    #expect(!model.isRefreshing)
    let reloaded = AppModel(stateURL: url, credentials: TestCredentials())
    #expect(reloaded.pullRequests == before)
  }

  @Test func refreshLandsOnlyNewlyMergedPullRequests() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    model.setFocused(true)

    await model.refresh()
    let landing = try #require(model.landing)
    await model.refresh()

    #expect(landing.pullRequests == ["fresh-test-credential"])
    #expect(model.landing == landing)
    #expect(
      model.pullRequests.contains { $0.id == "fresh-test-credential" }
        == (landing.reveal <= model.now))
  }

  @Test func refreshLeavesRepositoriesForTheRepositoriesPage() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    #expect(!connection.snapshot.repositories.isEmpty)

    await model.refresh()
    #expect(model.connections[0].snapshot.repositories == connection.snapshot.repositories)

    await model.refreshRepositories()
    #expect(model.connections[0].snapshot.repositories.isEmpty)
  }

  @Test func refreshMergesEveryAccountsArrivalsIntoOneLanding() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let sample = PreviewData.connections(now: .now)[0]
    let connections = ["first", "second"].map { name in
      AccountConnection(
        id: UUID(), label: name,
        profile: GitHubProfile(
          id: name, login: name, name: nil, avatarUrl: sample.profile.avatarUrl),
        scope: RepositoryScope(), snapshot: sample.snapshot)
    }
    try JSONEncoder().encode(FixtureState(connections: connections)).write(
      to: url)
    let store = TestCredentials()
    for connection in connections { try store.save(connection.label, for: connection.id) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    model.setFocused(true)

    await model.refresh()

    #expect(model.landing?.pullRequests == ["fresh-first", "fresh-second"])
  }

  @Test func mergesWhileUnfocusedWaitInTheBannerUntilFocus() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))

    await model.refresh()

    let listed = GoalPeriod.day.pullRequests(in: model.pullRequests, now: model.now).count
    #expect(model.progress(for: .day).count == listed + 1)
    #expect(model.landing == nil)
    #expect(model.banner?.pullRequests == ["fresh-test-credential"])
    let banner = try #require(model.banner)
    #expect(model.pullRequests(in: banner).map(\.id) == ["fresh-test-credential"])
    #expect(model.icons["r1"] != nil)
    #expect(!model.pullRequests.contains { $0.id == "fresh-test-credential" })

    model.setFocused(true)

    let landing = try #require(model.landing)
    #expect(model.banner == nil)
    #expect(model.pullRequests(in: banner).map(\.id) == ["fresh-test-credential"])
    #expect(landing.pullRequests == ["fresh-test-credential"])
    #expect(landing.slam == nil)
    #expect(model.pullRequests.contains { $0.id == "fresh-test-credential" })
  }

  @Test func releasingTheBannerAddsItsMergesWithoutFocus() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    await model.refresh()

    model.releaseBanner()

    let landing = try #require(model.landing)
    #expect(model.banner == nil)
    #expect(landing.pullRequests == ["fresh-test-credential"])
    #expect(landing.slam == nil)
    #expect(model.pullRequests.contains { $0.id == "fresh-test-credential" })
  }

  @Test func bannerClearsWhenItsMergesDisappear() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "state.json")
    let connection = PreviewData.connections(now: .now)[0]
    try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
    let store = TestCredentials()
    try store.save("test-credential", for: connection.id)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergedProtocol.self]
    let model = AppModel(
      stateURL: url, credentials: store, session: URLSession(configuration: configuration))
    await model.refresh()
    #expect(model.banner != nil)

    try model.remove(connection.id)

    #expect(model.banner == nil)
  }
}

@MainActor
private func syncingModel(in directory: URL) throws -> (
  AppModel, AccountConnection, token: String
) {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: "state.json")
  let connection = PreviewData.connections(now: .now)[0]
  try JSONEncoder().encode(FixtureState(connections: [connection])).write(to: url)
  let token = UUID().uuidString
  let store = TestCredentials()
  try store.save(token, for: connection.id)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [GistProtocol.self]
  let model = AppModel(
    stateURL: url, credentials: store, session: URLSession(configuration: configuration))
  return (model, connection, token)
}

private func mergedPullRequest(in repository: Repository) -> MergedPullRequest {
  MergedPullRequest(
    id: repository.id, title: "Ship", number: 1,
    url: URL(string: "https://github.com/\(repository.nameWithOwner)/pull/1")!,
    mergedAt: .now.addingTimeInterval(-1), repository: repository)
}

@MainActor
private final class TestCredentials: CredentialStorage {
  var tokens: [UUID: String] = [:]

  func save(_ token: String, for id: UUID) throws {
    tokens[id] = token
  }

  func read(for id: UUID) throws -> String {
    guard let token = tokens[id] else { throw CredentialError.invalidData }
    return token
  }

  func delete(for id: UUID) throws {
    tokens[id] = nil
  }
}

private struct FixtureState: Encodable {
  let connections: [AccountConnection]
  var organizations: OrganizationPreferences?
}

private final class SignedInProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let query = try requestBody(request)["query"] as! String
      let body: String
      if query.contains("repositories(first") {
        body = """
          {"data":{"viewer":{"repositories":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
          """
      } else if query.contains("search(query") {
        body = """
          {"data":{"search":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
          """
      } else {
        body = """
          {"data":{"viewer":{"id":"preview-user","login":"renamed-user","name":null,"avatarUrl":"https://github.com/renamed-user.png"}}}
          """
      }
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

private final class UnavailableProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class MergedProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  static let icon = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!.representation(using: .png, properties: [:])!

  override func startLoading() {
    let mergedAt = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-60))
    let token = request.value(forHTTPHeaderField: "Authorization")?.split(separator: " ").last ?? ""
    let body =
      switch request.url!.path() {
      case "/repos/acme/app/git/trees/HEAD":
        Data(#"{"tree":[{"path":"Resources/AppIcon.icns","type":"blob","size":1}]}"#.utf8)
      case "/repos/acme/app/contents/Resources/AppIcon.icns": Self.icon
      default:
        Data(
          ((try? requestBody(request)["query"] as? String)?.contains("search(query") == true
            ? """
            {"data":{"search":{"issueCount":1,"nodes":[{"id":"fresh-\(token)","title":"Slam","number":1,"url":"https://github.com/acme/app/pull/1","mergedAt":"\(mergedAt)","repository":{"id":"r1","nameWithOwner":"acme/app","isPrivate":false,"ownerKind":{"__typename":"User"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
            """
            : """
            {"data":{"viewer":{"repositories":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """).utf8)
      }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class GistProtocol: URLProtocol, @unchecked Sendable {
  struct Stored {
    let token: String
    var description = SyncedSettings.description
    var content: String?
    var version: Int
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var stored: [String: Stored] = [:]
  nonisolated(unsafe) private static var clock = 0

  static var gists: [String: Stored] { lock.withLock { stored } }

  static func settings(for token: String) -> SyncedSettings? {
    let gist = gists.values.first {
      $0.token == token && $0.description == SyncedSettings.description && $0.content != nil
    }
    return gist.flatMap {
      try? JSONDecoder().decode(SyncedSettings.self, from: Data($0.content!.utf8))
    }
  }

  static func publish(_ settings: SyncedSettings, for token: String) {
    publish(String(decoding: try! JSONEncoder().encode(settings), as: UTF8.self), for: token)
  }

  @discardableResult
  static func publish(
    _ content: String, for token: String, description: String = SyncedSettings.description
  ) -> String {
    lock.withLock {
      let id =
        stored.first { $0.value.token == token && $0.value.description == description }?.key
        ?? UUID().uuidString
      clock += 1
      stored[id] = Stored(
        token: token, description: description, content: content, version: clock)
      return id
    }
  }

  static func emptyFiles(for token: String) {
    lock.withLock {
      for (id, gist) in stored where gist.token == token { stored[id]?.content = nil }
    }
  }

  static func delete(for token: String) {
    lock.withLock { stored = stored.filter { $0.value.token != token } }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let token =
      request.value(forHTTPHeaderField: "Authorization")?.split(separator: " ").last
      .map(String.init) ?? ""
    let path = request.url!.path()
    let (status, body, etag): (Int, Any, String?) = Self.lock.withLock {
      switch (request.httpMethod ?? "GET", path) {
      case ("GET", "/gists"):
        return (200, Self.stored.filter { $0.value.token == token }.map(Self.summary), nil)
      case ("POST", "/gists"):
        let id = UUID().uuidString
        Self.clock += 1
        Self.stored[id] = Stored(token: token, content: content(), version: Self.clock)
        return (201, Self.json(id), nil)
      case ("PATCH", _):
        let id = String(path.dropFirst("/gists/".count))
        Self.clock += 1
        Self.stored[id]?.content = content()
        Self.stored[id]?.version = Self.clock
        return (200, Self.json(id), nil)
      default:
        let id = String(path.dropFirst("/gists/".count))
        guard let gist = Self.stored[id] else { return (404, [:], nil) }
        let etag = "\"\(gist.version)\""
        if request.value(forHTTPHeaderField: "If-None-Match") == etag { return (304, [:], etag) }
        return (200, Self.json(id), etag)
      }
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: etag.map { ["ETag": $0] })!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private func content() -> String {
    let files = try! requestBody(request)["files"] as! [String: [String: String]]
    return files[SyncedSettings.file]!["content"]!
  }

  private static func summary(_ gist: (key: String, value: Stored)) -> [String: Any] {
    [
      "id": gist.key, "description": gist.value.description,
      "updated_at": timestamp(gist.value.version),
      "files": gist.value.content == nil
        ? [:] : [SyncedSettings.file: ["filename": SyncedSettings.file]],
    ]
  }

  private static func json(_ id: String) -> [String: Any] {
    let gist = stored[id]!
    return [
      "id": id, "updated_at": timestamp(gist.version),
      "files": gist.content.map { [SyncedSettings.file: ["content": $0]] } ?? [:],
    ]
  }

  private static func timestamp(_ version: Int) -> String {
    ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: 1_700_000_000 + Double(version)))
  }
}
