import SwiftUI
import Testing

@testable import GitHubMaxxer

@MainActor
struct SegmentMeterTests {
  private let shares = [
    MeterShare(id: "personal", title: "Personal", count: 2, target: 1, color: .red),
    MeterShare(id: "org", title: "Org", count: 1, target: 1, color: .blue),
  ]

  @Test func sharedMeterTurnsGreenOnceReached() {
    let meter = SegmentMeter(count: 3, target: 2, isReached: true, shares: shares)
    #expect(meter.color(end: 1) == Palette.reached)
    #expect(meter.color(end: 2) == Palette.reached)
    #expect(meter.color(end: 3) == Palette.over)
  }

  @Test func sharedMeterShowsSharesUntilReached() {
    let meter = SegmentMeter(count: 3, target: 2, isReached: false, shares: shares)
    #expect(meter.color(end: 1) == .red)
    #expect(meter.color(end: 3) == .blue)
  }

  @Test func sharedMeterLeavesUnmergedSegmentsEmpty() {
    let meter = SegmentMeter(count: 3, target: 4, isReached: false, shares: shares)
    #expect(meter.color(end: 4) == Palette.empty)
  }
}

@MainActor
struct LineChangesTests {
  private func fills(_ additions: Int, _ deletions: Int) -> [Color] {
    (0..<5).map { LineChanges(additions: additions, deletions: deletions).fill($0) }
  }

  @Test func barGrowsWithTheSizeOfTheChange() {
    #expect(fills(0, 0) == Array(repeating: Palette.empty, count: 5))
    #expect(fills(2, 1) == [Palette.added] + Array(repeating: Palette.empty, count: 4))
    #expect(
      fills(1_240, 388) == Array(repeating: Palette.added, count: 4) + [Palette.deleted])
  }

  @Test func barSplitsBetweenAddedAndDeletedLines() {
    #expect(fills(12, 604) == Array(repeating: Palette.deleted, count: 5))
    #expect(
      fills(64, 9) == [Palette.added, Palette.added, Palette.added, Palette.empty, Palette.empty])
  }
}
