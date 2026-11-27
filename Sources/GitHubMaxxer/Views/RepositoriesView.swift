import GitHubMaxxerCore
import SwiftUI

struct RepositoriesView: View {
  @Environment(AppModel.self) private var model
  let search: String
  @State private var selectedConnection: UUID?
  @State private var picking: [String: Set<String>] = [:]

  private var account: AccountConnection? {
    model.connections.first { $0.id == selectedConnection } ?? model.connections.first
  }

  var body: some View {
    Group {
      if let account {
        let owners = owners(of: account)
        let hidden = hiddenOrganizations(of: account)
        VStack(alignment: .leading, spacing: 0) {
          header(account).padding(20)
          List {
            ForEach(owners, id: \.self) { owner in ownerRow(owner, account: account) }
            ForEach(hidden, id: \.self) { owner in hiddenRow(owner, account: account) }
          }
          .overlay {
            if owners.isEmpty && hidden.isEmpty { ContentUnavailableView.search(text: search) }
          }
        }
      } else {
        ContentUnavailableView(
          "No repositories yet", systemImage: "folder",
          description: Text(
            "Connect GitHub to choose which repositories count toward your targets."))
      }
    }
  }

  private func header(_ account: AccountConnection) -> some View {
    let repositories = account.snapshot.visibleRepositories
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        if model.connections.count > 1 {
          Picker(
            "Connection",
            selection: Binding(
              get: { self.account?.id ?? account.id }, set: { selectedConnection = $0 })
          ) {
            ForEach(model.connections) { connection in
              Text("\(connection.label) · @\(connection.profile.login)").tag(connection.id)
            }
          }
          .frame(width: 340)
        } else {
          Text("\(account.label) · @\(account.profile.login)").font(.headline)
        }
        Spacer()
        Text(
          "\(repositories.count(where: account.scope.includes)) of \(repositories.count) tracked"
        )
        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
      }
      Text(
        "Choose whose repositories count. Only PRs you author count, and organizations you count appear in the sidebar."
      )
      .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func ownerRow(_ owner: String, account: AccountConnection) -> some View {
    let repositories = account.snapshot.visibleRepositories.owned(by: owner)
    let coverage = coverage(of: owner, account: account)
    let summary = repositories.count == 1 ? "1 repository" : "\(repositories.count) repositories"
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: model.isPerson(owner) ? "person" : "building.2")
          .foregroundStyle(.secondary).frame(width: 18)
        Text(model.displayName(for: owner))
        Text(isYou(owner, account: account) ? "you · \(summary)" : summary)
          .foregroundStyle(.secondary)
        Spacer()
        coveragePicker(owner, selection: coverage, account: account)
      }
      if coverage == .some {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(
            repositories.filter(matches).sorted {
              $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
          ) { repository in
            Toggle(isOn: repositoryBinding(repository, account: account)) {
              HStack {
                Text(repository.name).lineLimit(1)
                Spacer()
                Text(repository.isPrivate ? "Private" : "Public").foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
        .padding(.leading, 28)
      }
    }
    .padding(.vertical, 6)
  }

  private func hiddenRow(_ owner: String, account: AccountConnection) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "lock").foregroundStyle(.orange).frame(width: 18)
      Text(model.displayName(for: owner))
      Text("Hidden by single sign-on").foregroundStyle(.secondary)
      Spacer()
      Button("Authorize") {
        model.connectionDraft = ConnectionDraft(existing: account, signsIn: true)
      }
      .accessibilityLabel("Authorize \(model.displayName(for: owner))")
      coveragePicker(
        owner, selection: account.scope.counts(owner) ? .all : .none, account: account,
        options: [.all, .none])
    }
    .padding(.vertical, 6)
  }

  private func coveragePicker(
    _ owner: String, selection: RepositoryScope.Coverage, account: AccountConnection,
    options: [RepositoryScope.Coverage] = RepositoryScope.Coverage.allCases
  ) -> some View {
    Picker(
      "Count \(model.displayName(for: owner))",
      selection: Binding(
        get: { selection },
        set: { coverage in
          model.setCoverage(coverage, owner: owner, for: account.id)
          let scope = model.connections.first { $0.id == account.id }?.scope
          picking[pickingKey(owner, account: account)] =
            coverage == .some ? scope.map { checked(owner, in: $0, account: account) } : nil
        })
    ) {
      ForEach(options, id: \.self) { coverage in Text(coverage.title).tag(coverage) }
    }
    .pickerStyle(.segmented).labelsHidden().fixedSize()
  }

  private func coverage(of owner: String, account: AccountConnection) -> RepositoryScope.Coverage {
    let coverage = account.scope.coverage(of: owner, among: account.snapshot.visibleRepositories)
    return coverage == .none && picking[pickingKey(owner, account: account)] == []
      ? .some : coverage
  }

  private func checked(_ owner: String, in scope: RepositoryScope, account: AccountConnection)
    -> Set<String>
  {
    Set(account.snapshot.visibleRepositories.owned(by: owner).map(\.id))
      .intersection(scope.repositories)
  }

  private func pickingKey(_ owner: String, account: AccountConnection) -> String {
    "\(account.id)/\(OrganizationPreferences.key(owner))"
  }

  private func owners(of account: AccountConnection) -> [String] {
    let repositories = account.snapshot.visibleRepositories
    let rank = { (owner: String) in
      isYou(owner, account: account) ? 0 : model.isPerson(owner) ? 2 : 1
    }
    return Dictionary(repositories.map { (OrganizationPreferences.key($0.owner), $0.owner) }) {
      first, _ in first
    }
    .values
    .filter { owner in
      named(owner) || repositories.owned(by: owner).contains(where: matches)
    }
    .sorted { first, second in
      rank(first) != rank(second)
        ? rank(first) < rank(second)
        : first.localizedStandardCompare(second) == .orderedAscending
    }
  }

  private func hiddenOrganizations(of account: AccountConnection) -> [String] {
    let visible = Set(
      account.snapshot.visibleRepositories.map { OrganizationPreferences.key($0.owner) })
    return model.hiddenOrganizations(of: account.id).filter {
      !visible.contains(OrganizationPreferences.key($0))
        && named($0)
    }
  }

  private func isYou(_ owner: String, account: AccountConnection) -> Bool {
    owner.caseInsensitiveCompare(account.profile.login) == .orderedSame
  }

  private func named(_ owner: String) -> Bool {
    search.isEmpty || owner.localizedCaseInsensitiveContains(search)
      || model.displayName(for: owner).localizedCaseInsensitiveContains(search)
  }

  private func matches(_ repository: Repository) -> Bool {
    search.isEmpty || repository.nameWithOwner.localizedCaseInsensitiveContains(search)
  }

  private func repositoryBinding(_ repository: Repository, account: AccountConnection)
    -> Binding<Bool>
  {
    Binding {
      account.scope.includes(repository)
    } set: { selected in
      var scope = account.scope
      if selected {
        scope.repositories.insert(repository.id)
      } else {
        scope.repositories.remove(repository.id)
      }
      model.setScope(scope, for: account.id)
      picking[pickingKey(repository.owner, account: account)] =
        checked(repository.owner, in: scope, account: account)
    }
  }
}

extension RepositoryScope.Coverage {
  fileprivate var title: String {
    switch self {
    case .all: "All"
    case .some: "Some"
    case .none: "None"
    }
  }
}
