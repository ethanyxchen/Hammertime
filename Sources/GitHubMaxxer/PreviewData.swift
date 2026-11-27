import Foundation
import GitHubMaxxerCore

enum PreviewData {
  static func connections(now: Date) -> [AccountConnection] {
    let profile = GitHubProfile(
      id: "preview-user", login: "alexmorgan", name: "Alex Morgan",
      avatarUrl: URL(string: "https://github.com/identicons/alexmorgan.png")!
    )
    let repositories = [
      Repository(
        id: "1", nameWithOwner: "northstar/desktop", isPrivate: true,
        ownerKind: .organization),
      Repository(
        id: "2", nameWithOwner: "northstar/platform", isPrivate: true,
        ownerKind: .organization),
      Repository(id: "3", nameWithOwner: "alexmorgan/dotfiles", isPrivate: false),
      Repository(id: "4", nameWithOwner: "alexmorgan/swift-tools", isPrivate: false),
    ]
    let titles = [
      "Keep search selection when results update", "Add keyboard navigation to the sidebar",
      "Simplify token refresh handling", "Improve empty states in the activity view",
      "Fix window restoration on launch", "Remove unused build steps",
      "Add tests for calendar boundaries", "Update Swift toolchain",
    ]
    let pulls = (0..<200).map { index in
      MergedPullRequest(
        id: "preview-pr-\(index)", title: titles[index % titles.count], number: 400 - index,
        url: URL(
          string: "https://github.com/\(repositories[index % 4].nameWithOwner)/pull/\(400 - index)")!,
        mergedAt: now.addingTimeInterval(-(Double(index) * 10.4 + Double(index * 7 % 5)) * 3_600),
        additions: [186, 64, 1_240, 12, 23, 3, 418, 9][index % 8] * (1 + index % 3),
        deletions: [42, 9, 388, 604, 11, 3, 97, 0][index % 8],
        repository: repositories[index % 4]
      )
    }
    let snapshot = GitHubSnapshot(repositories: repositories, pullRequests: pulls, fetchedAt: now)
    return [
      AccountConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, label: "Alex Morgan",
        profile: profile, scope: RepositoryScope(owners: Set(repositories.map(\.owner))),
        snapshot: snapshot
      )
    ]
  }
}
