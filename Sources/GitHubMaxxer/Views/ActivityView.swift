import GitHubMaxxerCore
import SwiftUI

struct ActivityView: View {
  @Environment(AppModel.self) private var model
  let filter: ActivityFilter
  let title: String
  let search: String
  @State private var page = 0

  private var interval: DateInterval { Activity.page(page, endingAt: model.now) }

  private func days(in pulls: [MergedPullRequest]) -> [(day: Date, pulls: [MergedPullRequest])] {
    let interval = interval
    let pulls = pulls.filter { pull in
      guard !search.isEmpty else {
        return pull.mergedAt >= interval.start && pull.mergedAt < interval.end
      }
      return pull.title.localizedCaseInsensitiveContains(search)
        || pull.repository.nameWithOwner.localizedCaseInsensitiveContains(search)
        || "#\(pull.number)".contains(search)
    }
    return Dictionary(grouping: pulls) { Calendar.current.startOfDay(for: $0.mergedAt) }
      .sorted { $0.key > $1.key }
      .map { (day: $0.key, pulls: $0.value) }
  }

  var body: some View {
    let pulls = model.pullRequests(for: filter)
    return GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            PageTitle(title).padding(.top, 28)
            progress(pulls).padding(.top, 24).padding(.bottom, 32)
            log(days(in: pulls)).padding(.vertical, 20).id("log")
            Spacer(minLength: 0)
            if search.isEmpty { pager(proxy).padding(.bottom, 28) }
          }
          .padding(.horizontal, 40)
          .frame(maxWidth: model.countsOnly ? 860 : 960, minHeight: viewport.size.height)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .background(Palette.panel)
    .foregroundStyle(Palette.ink)
  }

  @ViewBuilder
  private func progress(_ pulls: [MergedPullRequest]) -> some View {
    if model.countsOnly { tally(pulls) } else { targets(pulls) }
  }

  private func targets(_ pulls: [MergedPullRequest]) -> some View {
    HStack(alignment: .top, spacing: 48) {
      today(standing(.day, in: pulls)).frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 28) {
        ForEach([GoalPeriod.week, .month]) { period in
          self.period(period, standing(period, in: pulls))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func tally(_ pulls: [MergedPullRequest]) -> some View {
    let days = Activity.days(Activity.historyDays, of: pulls, endingAt: model.now)
    let best = Array(days.suffix(30)).busiest
    let today = dayTally("Today", days.last)
    let mostProductive = dayTally(
      best.map { "Most productive · \(dayLabel($0.date))" } ?? "Most productive", best)
    let heatmap = tallyColumn("Last \(days.count) days") { Heatmap(days: days, best: best?.date) }
    return ViewThatFits(in: .horizontal) {
      TallyLayout {
        today
        Rule(vertical: true)
        mostProductive
        Rule(vertical: true)
        heatmap
      }
      VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .top, spacing: 32) {
          today
          Rule(vertical: true)
          mostProductive
        }
        .fixedSize(horizontal: false, vertical: true)
        heatmap.frame(maxWidth: 360, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func dayTally(_ title: String, _ day: ActivityDay?) -> some View {
    let count = day?.count ?? 0
    let split = day.map { filter == .all ? self.split($0.pullRequests) : [] } ?? []
    return tallyColumn(title) {
      HStack(alignment: .lastTextBaseline, spacing: 14) {
        Text(padded(count)).font(.readout(56))
        if !split.isEmpty {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            ForEach(Array(split.enumerated()), id: \.offset) { _, row in
              GridRow {
                Text(row.title)
                Text(String(row.count)).gridColumnAlignment(.trailing)
              }
            }
          }
          .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.secondary)
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(title): \(count) merged \(count == 1 ? "PR" : "PRs")"
        + split.map { ". \($0.title): \($0.count)" }.joined())
  }

  private func tallyColumn(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Eyebrow(title)
      Spacer(minLength: 16)
      content()
    }
  }

  private func split(_ pulls: [MergedPullRequest]) -> [(title: String, count: Int)] {
    let rows = model.workspaces.map {
      (title: model.title(for: $0), count: model.pullRequests(for: $0, in: pulls).count)
    }
    let other = pulls.count - rows.map(\.count).reduce(0, +)
    let split = rows + (other > 0 ? [(title: "Other", count: other)] : [])
    return split.count > 1 ? split : []
  }

  private func standing(_ period: GoalPeriod, in pulls: [MergedPullRequest]) -> Standing {
    let current = period.pullRequests(in: pulls, now: model.now)
    return Standing(
      progress: GoalProgress(count: current.count, target: model.goals(for: filter)[period]),
      shares: shares(period, in: pulls),
      isReached: model.isReached(period, in: current, filter: filter))
  }

  private func shares(_ period: GoalPeriod, in pulls: [MergedPullRequest]) -> [MeterShare] {
    guard filter == .all else { return [] }
    let workspaces = model.workspaces.map { workspace in
      MeterShare(
        id: workspace, title: model.title(for: workspace),
        count: period.count(in: model.pullRequests(for: workspace), now: model.now),
        target: model.goals(for: workspace)[period],
        color: Palette.colour(model.colour(for: workspace)))
    }
    let other = period.count(in: pulls, now: model.now) - workspaces.map(\.count).reduce(0, +)
    return
      (workspaces
      + [MeterShare(id: "other", title: "Other", count: other, target: 0, color: Palette.secondary)])
      .filter { $0.count > 0 || $0.target > 0 }
  }

  private func pace(_ period: GoalPeriod, _ progress: GoalProgress) -> Int? {
    period == .day || progress.isComplete || progress.target == 0
      ? nil : period.pace(target: progress.target, now: model.now)
  }

  private func today(_ standing: Standing) -> some View {
    let progress = standing.progress
    return VStack(alignment: .leading, spacing: 16) {
      Eyebrow("Today")
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(padded(progress.count)).font(.readout(64))
        Text("/ \(padded(progress.target))").font(.readout(22)).foregroundStyle(Palette.secondary)
      }
      SegmentMeter(
        count: progress.count, target: progress.target, isReached: standing.isReached,
        tint: Palette.colour(model.colour(for: filter)), shares: standing.shares)
      HStack(spacing: 8) {
        Lamp(isOn: standing.isReached)
        Text(status(standing)).font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Palette.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Today: \(progress.count) merged PRs, target \(progress.target). \(status(standing))\(breakdown(standing.shares))"
    )
  }

  private func period(_ period: GoalPeriod, _ standing: Standing) -> some View {
    let progress = standing.progress
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(period.title).fontWeight(.semibold)
        Text(periodDateLabel(period, now: model.now)).font(.caption)
          .foregroundStyle(Palette.secondary)
        Spacer()
        Text("\(padded(progress.count)) / \(padded(progress.target))").font(.readout(14))
      }
      SegmentMeter(
        count: progress.count, target: progress.target, isReached: standing.isReached,
        pace: pace(period, progress), tint: Palette.colour(model.colour(for: filter)),
        shares: standing.shares, height: 14)
      Text(note(period, standing)).font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.secondary).padding(.top, 4)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(period.title): \(progress.count) merged PRs, target \(progress.target). \(note(period, standing))\(breakdown(standing.shares))"
    )
  }

  @ViewBuilder
  private func log(_ days: [(day: Date, pulls: [MergedPullRequest])]) -> some View {
    if days.isEmpty {
      if search.isEmpty {
        ContentUnavailableView { Text("Quiet week — no PRs merged") }
      } else {
        ContentUnavailableView.search(text: search)
      }
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(days, id: \.day) { entry in
          Section {
            ForEach(entry.pulls) { pull in
              PullRequestRow(pull: pull, landing: landing(pull)).padding(.vertical, 9)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
          } header: {
            dayHeader(entry.day, pulls: entry.pulls)
          }
        }
      }
      .animation(.spring(duration: 0.5, bounce: 0.3), value: model.now)
    }
  }

  private func landing(_ pull: MergedPullRequest) -> Landing? {
    model.landing.flatMap { $0.pullRequests.contains(pull.id) ? $0 : nil }
  }

  private func pager(_ proxy: ScrollViewProxy) -> some View {
    let last = interval.end.addingTimeInterval(-1)
    let range =
      "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
    return HStack {
      Button {
        turn(1, proxy)
      } label: {
        Label("Older", systemImage: "chevron.left")
      }
      .disabled(page == Activity.pageCount - 1)
      .opacity(page == Activity.pageCount - 1 ? 0.3 : 1)
      Spacer()
      Text(page == 0 ? "Last 7 days · \(range)" : range).font(.readout(12))
        .foregroundStyle(Palette.secondary)
      Spacer()
      Button {
        turn(-1, proxy)
      } label: {
        HStack(spacing: 4) {
          Text("Newer")
          Image(systemName: "chevron.right")
        }
      }
      .disabled(page == 0)
      .opacity(page == 0 ? 0.3 : 1)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 12, weight: .medium, design: .monospaced))
  }

  private func turn(_ offset: Int, _ proxy: ScrollViewProxy) {
    page += offset
    proxy.scrollTo("log", anchor: .top)
  }

  private func dayHeader(_ day: Date, pulls: [MergedPullRequest]) -> some View {
    HStack {
      Eyebrow(dayName(day))
      Spacer()
      Text(
        model.countsOnly
          ? padded(pulls.count)
          : "\(padded(pulls.count)) / \(padded(model.goals(for: filter).daily))"
      )
      .font(.readout(11))
      .foregroundStyle(
        model.isReached(.day, in: pulls, filter: filter) ? Palette.reached : Palette.secondary)
    }
    .padding(.top, 18).padding(.bottom, 8)
    .overlay(alignment: .bottom) { Rule() }
  }

  private func dayName(_ day: Date) -> String {
    if Calendar.current.isDateInToday(day) { return "Today" }
    if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
    return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
  }

  private func behind(_ shares: [MeterShare]) -> String {
    shares.filter { $0.count < $0.target }
      .map { "\($0.title) \($0.target - $0.count) to go" }
      .joined(separator: " · ")
  }

  private func breakdown(_ shares: [MeterShare]) -> String {
    shares.map { ". \($0.title): \($0.count) of \($0.target)" }.joined()
  }

  private func status(_ standing: Standing) -> String {
    let progress = standing.progress
    if progress.target == 0 { return "No target" }
    guard progress.isComplete else { return "\(progress.remaining) to go" }
    guard standing.isReached else { return behind(standing.shares) }
    let over = progress.count - progress.target
    return over > 0 ? "Target reached · \(over) over" : "Target reached"
  }

  private func note(_ period: GoalPeriod, _ standing: Standing) -> String {
    let progress = standing.progress
    if progress.target == 0 { return "No target" }
    if standing.isReached { return "Target reached" }
    if progress.isComplete { return behind(standing.shares) }
    let delta = progress.count - period.pace(target: progress.target, now: model.now)
    if delta > 0 { return "\(delta) ahead of pace" }
    if delta < 0 { return "\(-delta) behind pace" }
    return "On pace"
  }
}

private struct Standing {
  let progress: GoalProgress
  let shares: [MeterShare]
  let isReached: Bool
}

private func padded(_ value: Int) -> String {
  value < 10 ? "0\(value)" : String(value)
}

private func dayLabel(_ date: Date) -> String {
  date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

private struct TallyLayout: Layout {
  var heatmapShare: CGFloat = 0.4
  var minimumGap: CGFloat = 24
  var minimumHeatmap: CGFloat = 220

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let columns = columns(width: proposal.width, subviews: subviews)
    return CGSize(width: columns.width, height: columns.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let columns = columns(width: bounds.width, subviews: subviews)
    var x = bounds.minX
    for (subview, width) in zip(subviews, columns.widths) {
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        proposal: ProposedViewSize(width: width, height: columns.height))
      x += width + columns.gap
    }
  }

  private func columns(width: CGFloat?, subviews: Subviews) -> (
    widths: [CGFloat], gap: CGFloat, width: CGFloat, height: CGFloat
  ) {
    var widths = subviews.dropLast().map { $0.sizeThatFits(.unspecified).width }
    let fixed = widths.reduce(0, +)
    let gaps = CGFloat(max(subviews.count - 1, 1))
    let available = width ?? 0
    widths.append(
      max(minimumHeatmap, min(available * heatmapShare, available - fixed - gaps * minimumGap)))
    let width = max(available, widths.reduce(0, +) + gaps * minimumGap)
    let height =
      zip(subviews, widths).map {
        $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height
      }.max() ?? 0
    return (widths, (width - widths.reduce(0, +)) / gaps, width, height)
  }
}

private struct Heatmap: View {
  let days: [ActivityDay]
  let best: Date?
  private static let columns = 18

  var body: some View {
    let total = days.map(\.count).reduce(0, +)
    return VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(stride(from: 0, to: days.count, by: Self.columns)), id: \.self) { start in
        HStack(spacing: 4) {
          ForEach(days[start..<min(start + Self.columns, days.count)]) { square($0) }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Last \(days.count) days: \(total) merged \(total == 1 ? "PR" : "PRs")")
  }

  private func square(_ day: ActivityDay) -> some View {
    RoundedRectangle(cornerRadius: 3).fill(Palette.heat(day.count))
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let ring = ring(day) {
          RoundedRectangle(cornerRadius: 4.5).strokeBorder(ring, lineWidth: 1.5).padding(-3)
        }
      }
      .help("\(dayLabel(day.date)) · \(day.count) \(day.count == 1 ? "PR" : "PRs")")
  }

  private func ring(_ day: ActivityDay) -> Color? {
    if day.id == days.last?.id { return Palette.ink }
    return day.date == best ? Palette.secondary : nil
  }
}

private func periodDateLabel(_ period: GoalPeriod, now: Date) -> String {
  guard period == .week else { return now.formatted(.dateTime.month(.wide).year()) }
  let interval = period.interval(containing: now)
  let last = interval.end.addingTimeInterval(-1)
  return
    "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
}

private struct PullRequestRow: View {
  let pull: MergedPullRequest
  let landing: Landing?

  var body: some View {
    Link(destination: pull.url) {
      content
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    .contextMenu {
      Link("Open on GitHub", destination: pull.url)
      Button("Copy link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pull.url.absoluteString, forType: .string)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)

  private var content: some View {
    HStack(alignment: landing == nil ? .firstTextBaseline : .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(pull.title).font(Font(Self.titleFont)).foregroundStyle(Palette.ink).lineLimit(1)
          .help(pull.title)
        Text("#\(String(pull.number)) · \(pull.repository.nameWithOwner)")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      HStack(spacing: 12) {
        if let landing { MergedStamp(landing: landing) }
        Text(pull.mergedAt, format: .dateTime.hour().minute())
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
          .help(pull.mergedAt.formatted(date: .complete, time: .shortened))
      }
      .padding(.top, landing == nil ? 0 : Self.titleFont.ascender - Self.titleFont.capHeight)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
