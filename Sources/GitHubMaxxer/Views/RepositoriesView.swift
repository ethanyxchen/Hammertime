import GitHubMaxxerCore
import SwiftUI

struct RepositoriesView: View {
  @Environment(AppModel.self) private var model
  let search: String
  @State private var selectedConnection: UUID?

  private var account: AccountConnection? {
    model.connections.first { $0.id == selectedConnection } ?? model.connections.first
  }

  private var repositories: [Repository] {
    (account?.snapshot.visibleRepositories ?? []).filter {
      search.isEmpty || $0.nameWithOwner.localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    Group {
      if let account {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              if model.connections.count > 1 {
                Picker(
                  "Connection",
                  selection: Binding(
                    get: { self.account?.id ?? account.id }, set: { selectedConnection = $0 }
                  )
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
                "\(repositories.filter { account.scope.includes($0) }.count) of \(repositories.count) tracked"
              )
              .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
              Toggle(
                "Track all accessible repositories",
                isOn: Binding(
                  get: { account.scope.allRepositories },
                  set: { value in
                    var scope = account.scope
                    scope.allRepositories = value
                    model.setScope(scope, for: account.id)
                  }
                ))
              Spacer()
              Menu("Count repositories from") {
                ForEach(owners(of: account), id: \.self) { owner in
                  Toggle(model.displayName(for: owner), isOn: ownerBinding(owner, account: account))
                }
              }
              .fixedSize()
            }
            Text(
              "Only PRs you author count. Counting an organisation or account includes all of its repositories, now and in future. Organisations you count appear in the sidebar."
            )
            .font(.callout).foregroundStyle(.secondary)
          }
          .padding(20)
          if repositories.isEmpty {
            ContentUnavailableView.search(text: search)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            Table(repositories) {
              TableColumn("Track") { repository in
                Toggle(
                  "Track \(repository.nameWithOwner)",
                  isOn: repositoryBinding(repository, account: account)
                )
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(
                  account.scope.allRepositories || account.scope.includesOwner(repository.owner)
                )
                .padding(.vertical, 7)
              }
              .width(55)
              TableColumn("Repository") { repository in
                Label(repository.name, systemImage: "book.closed").lineLimit(1)
              }
              .width(min: 180, ideal: 330)
              TableColumn("Owner") { repository in
                Text(repository.owner).foregroundStyle(.secondary)
              }
              .width(min: 130, ideal: 180)
              TableColumn("Visibility") { repository in
                Text(repository.isPrivate ? "Private" : "Public").foregroundStyle(.secondary)
              }
              .width(80)
            }
          }
          Text(
            "Missing a work repository? Check this credential's access and SSO authorization, or add another connection."
          )
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.vertical, 14)
        }
      } else {
        ContentUnavailableView(
          "No repositories yet", systemImage: "folder",
          description: Text(
            "Connect GitHub to choose which repositories count toward your targets."))
      }
    }
    .task { await model.refreshRepositories() }
  }

  private func owners(of account: AccountConnection) -> [String] {
    Dictionary(account.snapshot.visibleRepositories.map { ($0.owner.lowercased(), $0.owner) }) {
      first, _ in first
    }
    .values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private func ownerBinding(_ owner: String, account: AccountConnection) -> Binding<Bool> {
    Binding {
      account.scope.allRepositories || account.scope.includesOwner(owner)
    } set: {
      model.setCounted($0, owner: owner, for: account.id)
    }
  }

  private func repositoryBinding(_ repository: Repository, account: AccountConnection) -> Binding<
    Bool
  > {
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
    }
  }
}
