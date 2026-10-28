import Foundation
import Testing

@testable import GitHubMaxxerCore

struct ActivityTests {
  @Test func dailyGoalHasSafeBoundsForDerivedTargets() {
    #expect(Goals(clamping: -1).daily == 0)
    #expect(Goals(clamping: Int.max).daily == 10_000)
    #expect(Goals(clamping: Int.max).weekly == 50_000)
    #expect(Goals(clamping: Int.max).monthly == 200_000)
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  private func pull(
    _ id: String, _ merged: String, repo: String = "acme/app",
    ownerKind: RepositoryOwnerKind? = nil
  ) -> MergedPullRequest {
    MergedPullRequest(
      id: id, title: "Improve search", number: 42,
      url: URL(string: "https://github.com/\(repo)/pull/42")!,
      mergedAt: date(merged),
      repository: Repository(id: repo, nameWithOwner: repo, isPrivate: false, ownerKind: ownerKind)
    )
  }

  @Test func newAccountsCountOwnersTheyMergedIntoAndThemselves() {
    let scope = RepositoryScope.active(
      in: [pull("work", "2026-09-29T12:00:00Z", repo: "acme/app")], login: "me")
    #expect(scope == RepositoryScope(allRepositories: false, owners: ["acme", "me"]))
  }

  @Test func stopCountingAnOwnerWhileTrackingEverythingKeepsTheOthers() {
    let available = ["acme/app", "beta/app", "beta/tools", "me/dotfiles"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false)
    }
    let scope = RepositoryScope().counting("BETA", false, among: available)
    #expect(!scope.allRepositories)
    #expect(scope.owners == ["acme", "me"])
    #expect(RepositoryScope().counting("beta", true, among: available) == RepositoryScope())
    #expect(scope.counting("beta", true, among: available).owners == ["acme", "beta", "me"])
  }

  @Test func stopCountingAnOwnerDropsItsIndividuallyTrackedRepositories() {
    let available = ["acme/app", "beta/app"].map {
      Repository(id: $0, nameWithOwner: $0, isPrivate: false)
    }
    let scope = RepositoryScope(allRepositories: false, repositories: ["acme/app", "beta/app"])
    #expect(scope.counting("beta", false, among: available).repositories == ["acme/app"])
  }

  @Test func refreshResumesShortlyBeforeTheLastFetch() {
    let now = date("2026-09-30T12:00:00Z")
    let recent = GitHubSnapshot(
      repositories: [], pullRequests: [], fetchedAt: date("2026-09-30T11:59:00Z"))
    #expect(recent.refreshInterval(endingAt: now).start == date("2026-09-30T10:59:00Z"))
    let stale = GitHubSnapshot(
      repositories: [], pullRequests: [], fetchedAt: date("2026-01-01T00:00:00Z"))
    #expect(
      stale.refreshInterval(endingAt: now).start == Activity.historyInterval(endingAt: now).start)
  }

  @Test func recordNeverDropsAPullRequestTheRefreshOmits() {
    var snapshot = GitHubSnapshot(
      repositories: [],
      pullRequests: [
        pull("expired", "2026-01-01T00:00:00Z"),
        pull("kept", "2026-09-20T00:00:00Z"),
        pull("omitted", "2026-09-30T11:30:00Z"),
      ],
      fetchedAt: date("2026-09-30T11:59:00Z"))
    let interval = DateInterval(
      start: date("2026-09-30T10:59:00Z"), end: date("2026-09-30T12:00:00Z"))

    snapshot.record([pull("fresh", "2026-09-30T11:45:00Z")], mergedIn: interval)

    #expect(snapshot.pullRequests.map(\.id) == ["fresh", "kept", "omitted"])
    #expect(snapshot.fetchedAt == interval.end)
  }

  @Test func localMidnightAndFutureMerges() {
    let now = date("2026-09-30T12:00:00Z")
    let pulls = [
      pull("before", "2026-09-29T22:59:59Z"),
      pull("today", "2026-09-29T23:00:00Z"),
      pull("future", "2026-09-30T13:00:00Z"),
    ]
    #expect(GoalPeriod.day.count(in: pulls, now: now, calendar: calendar) == 1)
  }

  @Test func daysBucketByLocalDateAndTheBusiestPrefersTheLatestTie() {
    let now = date("2026-09-30T12:00:00Z")
    let pulls = [
      pull("old", "2026-09-26T10:00:00Z"),
      pull("early-a", "2026-09-28T10:00:00Z"),
      pull("early-b", "2026-09-28T11:00:00Z"),
      pull("late-a", "2026-09-29T22:59:59Z"),
      pull("late-b", "2026-09-29T08:00:00Z"),
      pull("today", "2026-09-29T23:00:00Z"),
      pull("future", "2026-09-30T13:00:00Z"),
    ]
    let days = Activity.days(3, of: pulls, endingAt: now, calendar: calendar)
    #expect(days.map(\.count) == [2, 2, 1])
    #expect(days.last?.pullRequests.map(\.id) == ["today"])
    #expect(days.busiest?.date == days[1].date)
    #expect([ActivityDay]().busiest == nil)
    #expect(Activity.days(2, of: [], endingAt: now, calendar: calendar).busiest == nil)
  }

  @Test func weeksBeginMondayRegardlessOfLocale() {
    let now = date("2026-09-28T12:00:00Z")
    let pulls = [
      pull("sunday", "2026-09-27T22:59:59Z"),
      pull("monday", "2026-09-27T23:00:00Z"),
    ]
    #expect(GoalPeriod.week.count(in: pulls, now: now, calendar: calendar) == 1)
  }

  @Test func calendarWeekListExcludesPreviousWeekAndFutureMerges() {
    let now = date("2026-10-01T12:00:00Z")
    let pulls = [
      pull("now", "2026-10-01T12:00:00Z"),
      pull("monday", "2026-09-27T23:00:00Z"),
      pull("sunday", "2026-09-27T22:59:59Z"),
      pull("friday", "2026-09-25T12:00:00Z"),
      pull("future", "2026-10-01T13:00:00Z"),
    ]
    let selected = GoalPeriod.week.pullRequests(in: pulls, now: now, calendar: calendar)
    #expect(selected.map(\.id) == ["now", "monday"])
    #expect(selected.count == GoalPeriod.week.count(in: pulls, now: now, calendar: calendar))
  }

  @Test func monthUsesLocalCalendarBoundary() {
    let now = date("2026-10-01T12:00:00Z")
    let pulls = [
      pull("september", "2026-09-30T22:59:59Z"),
      pull("october", "2026-09-30T23:00:00Z"),
    ]
    #expect(GoalPeriod.month.count(in: pulls, now: now, calendar: calendar) == 1)
  }

  @Test func deduplicatesOverlappingConnectionsAfterFiltering() {
    let shared = pull("shared", "2026-09-30T10:00:00Z")
    let selected = RepositoryScope(allRepositories: false, owners: ["ACME"])
    let pulls = Activity.mergedPullRequests(from: [
      ScopedActivity(pullRequests: [shared], scope: RepositoryScope(allRepositories: false)),
      ScopedActivity(pullRequests: [shared, shared], scope: selected),
    ])
    #expect(pulls.map(\.id) == ["shared"])
  }

  @Test func activityFiltersSeparatePersonalAndOrganizationRepositories() {
    let personal = pull("personal", "2026-09-30T10:00:00Z", repo: "alex/tools")
    let work = pull("work", "2026-09-30T11:00:00Z", repo: "acme/app", ownerKind: .organization)
    let collaborator = pull("collaborator", "2026-09-30T12:00:00Z", repo: "someone/project")
    let pulls = [personal, work, collaborator]
    let personalLogins: Set<String> = ["Alex"]
    #expect(
      ActivityFilter.personal.pullRequests(in: pulls, personalLogins: personalLogins).map(\.id) == [
        "personal"
      ])
    #expect(
      ActivityFilter.organization("ACME").pullRequests(in: pulls, personalLogins: personalLogins)
        .map(\.id) == ["work"])
    #expect(
      ActivityFilter.organization("someone").pullRequests(in: pulls, personalLogins: personalLogins)
        .map(\.id) == ["collaborator"])
    #expect(ActivityFilter.all.pullRequests(in: pulls, personalLogins: personalLogins).count == 3)
  }

  @Test func selectedOwnersIncludeNewRepositories() {
    let scope = RepositoryScope(
      allRepositories: false, owners: ["acme"], repositories: ["tools"])
    #expect(scope.includes(Repository(id: "new", nameWithOwner: "acme/new", isPrivate: true)))
    #expect(scope.includes(Repository(id: "tools", nameWithOwner: "other/tools", isPrivate: false)))
    #expect(!scope.includes(Repository(id: "no", nameWithOwner: "other/app", isPrivate: false)))
  }

  @Test func allRepositoriesAndEmptySelectionDiffer() {
    let repo = Repository(id: "1", nameWithOwner: "acme/app", isPrivate: true)
    #expect(RepositoryScope().includes(repo))
    #expect(!RepositoryScope(allRepositories: false).includes(repo))
  }

  @Test func repositorySelectionSurvivesRename() {
    let scope = RepositoryScope(allRepositories: false, repositories: ["stable-id"])
    #expect(
      scope.includes(
        Repository(id: "stable-id", nameWithOwner: "new-owner/new-name", isPrivate: true)))
  }

  @Test func historyCoversNinetyLocalCalendarDays() {
    let now = date("2026-09-30T12:00:00Z")
    let interval = Activity.historyInterval(endingAt: now, calendar: calendar)
    #expect(
      calendar.dateComponents([.day], from: interval.start, to: calendar.startOfDay(for: now)).day
        == 89)
    #expect(!interval.contains(now.addingTimeInterval(1)))
  }

  @Test func paceCountsElapsedWorkdays() {
    let friday = date("2026-10-02T12:00:00Z")
    let wednesday = date("2026-09-30T12:00:00Z")
    #expect(GoalPeriod.month.pace(target: 60, now: friday, calendar: calendar) == 5)
    #expect(GoalPeriod.week.pace(target: 15, now: friday, calendar: calendar) == 15)
    #expect(GoalPeriod.week.pace(target: 15, now: wednesday, calendar: calendar) == 9)
    #expect(GoalPeriod.day.pace(target: 3, now: friday, calendar: calendar) == 3)
  }

  @Test func pagesStepBackSevenLocalDaysAndCoverHistory() {
    let now = date("2026-10-02T12:00:00Z")
    let latest = Activity.page(0, endingAt: now, calendar: calendar)
    #expect(latest.start == date("2026-09-25T23:00:00Z"))
    #expect(latest.end == date("2026-10-02T23:00:00Z"))
    #expect(latest.contains(now))
    let previous = Activity.page(1, endingAt: now, calendar: calendar)
    #expect(previous.end == latest.start)
    let oldest = Activity.page(Activity.pageCount - 1, endingAt: now, calendar: calendar)
    #expect(oldest.start <= Activity.historyInterval(endingAt: now, calendar: calendar).start)
  }

  @Test func progressCapsAtOneAndRetainsExcessCount() {
    #expect(GoalProgress(count: 7, target: 5).fraction == 1)
    #expect(GoalProgress(count: 7, target: 5).remaining == 0)
    #expect(GoalProgress(count: 7, target: 5).count == 7)
    #expect(GoalProgress(count: 0, target: 0).fraction == 0)
  }
}
