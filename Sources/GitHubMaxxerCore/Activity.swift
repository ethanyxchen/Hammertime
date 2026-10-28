import Foundation

public enum GoalPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
  case day, week, month

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .day: "Today"
    case .week: "This week"
    case .month: "This month"
    }
  }

  public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
    var calendar = calendar
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    let component: Calendar.Component =
      switch self {
      case .day: .day
      case .week: .weekOfYear
      case .month: .month
      }
    return calendar.dateInterval(of: component, for: date)!
  }

  public func count(in pullRequests: [MergedPullRequest], now: Date, calendar: Calendar = .current)
    -> Int
  {
    self.pullRequests(in: pullRequests, now: now, calendar: calendar).count
  }

  public func pullRequests(
    in pullRequests: [MergedPullRequest], now: Date, calendar: Calendar = .current
  ) -> [MergedPullRequest] {
    let interval = interval(containing: now, calendar: calendar)
    return pullRequests.filter {
      $0.mergedAt >= interval.start && $0.mergedAt < interval.end && $0.mergedAt <= now
    }
  }

  public func pace(target: Int, now: Date, calendar: Calendar = .current) -> Int {
    let interval = interval(containing: now, calendar: calendar)
    let workdays = sequence(first: interval.start) {
      calendar.date(byAdding: .day, value: 1, to: $0)
    }
    .prefix { $0 < interval.end }
    .filter { !calendar.isDateInWeekend($0) }
    guard !workdays.isEmpty else { return target }
    return target * workdays.filter { $0 <= now }.count / workdays.count
  }
}

public struct Goals: Codable, Sendable, Equatable {
  public static let dailyRange = 0...10_000
  public let daily: Int
  public var weekly: Int { daily * 5 }
  public var monthly: Int { daily * 20 }

  public init(daily: Int = 1) {
    self.daily = daily
  }

  public init(clamping daily: Int) {
    self.init(daily: daily.clamped(to: Self.dailyRange))
  }

  public subscript(period: GoalPeriod) -> Int {
    switch period {
    case .day: daily
    case .week: weekly
    case .month: monthly
    }
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(range.upperBound, max(range.lowerBound, self))
  }
}

public struct GoalProgress: Sendable {
  public let count: Int
  public let target: Int

  public init(count: Int, target: Int) {
    self.count = count
    self.target = target
  }

  public var fraction: Double { target > 0 ? min(Double(count) / Double(target), 1) : 0 }
  public var remaining: Int { max(target - count, 0) }
  public var isComplete: Bool { target > 0 && count >= target }
}

public struct ScopedActivity: Sendable {
  public let pullRequests: [MergedPullRequest]
  public let scope: RepositoryScope

  public init(pullRequests: [MergedPullRequest], scope: RepositoryScope) {
    self.pullRequests = pullRequests
    self.scope = scope
  }
}

public enum ActivityFilter: Hashable, Sendable {
  case all
  case personal
  case organization(String)

  public var title: String {
    switch self {
    case .all: "All activity"
    case .personal: "Personal"
    case .organization(let owner): owner
    }
  }

  public func pullRequests(
    in pullRequests: [MergedPullRequest], personalLogins: Set<String>
  ) -> [MergedPullRequest] {
    pullRequests.filter { pull in
      switch self {
      case .all: true
      case .personal:
        personalLogins.contains { $0.caseInsensitiveCompare(pull.repository.owner) == .orderedSame }
      case .organization(let owner):
        pull.repository.owner.caseInsensitiveCompare(owner) == .orderedSame
      }
    }
  }
}

public struct ActivityDay: Sendable, Identifiable {
  public let date: Date
  public let pullRequests: [MergedPullRequest]

  public var id: Date { date }
  public var count: Int { pullRequests.count }
}

extension Array where Element == ActivityDay {
  public var busiest: ActivityDay? {
    filter { $0.count > 0 }.max { ($0.count, $0.date) < ($1.count, $1.date) }
  }
}

public enum Activity {
  public static let historyDays = 90
  public static let pageDays = 7
  public static let pageCount = (historyDays + pageDays - 1) / pageDays

  public static func historyInterval(endingAt now: Date, calendar: Calendar = .current)
    -> DateInterval
  {
    let start = calendar.startOfDay(
      for: calendar.date(byAdding: .day, value: 1 - historyDays, to: now)!)
    return DateInterval(start: start, end: now)
  }

  public static func days(
    _ count: Int, of pullRequests: [MergedPullRequest], endingAt now: Date,
    calendar: Calendar = .current
  ) -> [ActivityDay] {
    let today = calendar.startOfDay(for: now)
    let merged = Dictionary(grouping: pullRequests.filter { $0.mergedAt <= now }) {
      calendar.startOfDay(for: $0.mergedAt)
    }
    return (0..<count).reversed().map { offset in
      let date = calendar.startOfDay(
        for: calendar.date(byAdding: .day, value: -offset, to: today)!)
      return ActivityDay(date: date, pullRequests: merged[date] ?? [])
    }
  }

  public static func page(_ index: Int, endingAt now: Date, calendar: Calendar = .current)
    -> DateInterval
  {
    let end = calendar.date(
      byAdding: .day, value: 1 - index * pageDays, to: calendar.startOfDay(for: now))!
    return DateInterval(start: calendar.date(byAdding: .day, value: -pageDays, to: end)!, end: end)
  }

  public static func mergedPullRequests(from sources: [ScopedActivity]) -> [MergedPullRequest] {
    var seen = Set<String>()
    var result: [MergedPullRequest] = []
    for source in sources {
      for pull in source.pullRequests where source.scope.includes(pull.repository) {
        if seen.insert(pull.id).inserted { result.append(pull) }
      }
    }
    return result.sorted {
      $0.mergedAt == $1.mergedAt ? $0.id < $1.id : $0.mergedAt > $1.mergedAt
    }
  }
}
