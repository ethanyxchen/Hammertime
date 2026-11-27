import AppKit
import GitHubMaxxerCore
import SwiftUI
import os

@MainActor
final class MergeBanner {
  static let card = CGSize(width: 380, height: 68)
  fileprivate static let stage = CGSize(width: 640, height: 420)
  fileprivate static let overscan = 2.0
  private static let canvas = CGSize(
    width: stage.width * overscan, height: stage.height * overscan)
  fileprivate static let margin = 12.0
  private static let lifetime = 8.0
  fileprivate static let exit = 0.35
  private let model: AppModel
  private var panel: NSPanel?
  private var occlusion: (any NSObjectProtocol)?
  private var shown: Date?

  init(model: AppModel) {
    self.model = model
    observe()
  }

  private func makePanel(frame: CGRect, canvasOrigin: CGPoint) -> NSPanel {
    let panel = NSPanel.overlay(
      frame: frame, level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1))
    let canvas = NSHostingView(
      rootView: BannerStage(dismiss: model.releaseBanner).environment(model)
        .frame(width: Self.canvas.width, height: Self.canvas.height))
    canvas.frame = CGRect(origin: canvasOrigin, size: Self.canvas)
    panel.contentView = NSView()
    panel.contentView?.addSubview(canvas)
    return panel
  }

  private func dismantle() {
    occlusion.map(NotificationCenter.default.removeObserver)
    occlusion = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private func logState(_ moment: String, of panel: NSPanel) {
    Logger.merges.log(
      "Banner \(moment, privacy: .public): visible \(panel.occlusionState.contains(.visible)), ordered in \(panel.isVisible), on active space \(panel.isOnActiveSpace), screen \(panel.screen?.localizedName ?? "none", privacy: .public), app active \(NSApp.isActive), app hidden \(NSApp.isHidden), app occlusion visible \(NSApp.occlusionState.contains(.visible))"
    )
  }

  static func placement(frame: CGRect, visible: CGRect) -> (panel: CGRect, canvas: CGPoint) {
    let card = CGPoint(
      x: visible.maxX - margin - card.width / 2, y: visible.maxY - margin - card.height / 2)
    let canvas = CGRect(
      origin: CGPoint(
        x: card.x - canvas.width / 2,
        y: card.y - canvas.height / 2 + stage.height * (Slam.impactHeight - 0.5)),
      size: canvas)
    let panel = canvas.intersection(frame)
    return (panel, CGPoint(x: canvas.minX - panel.minX, y: canvas.minY - panel.minY))
  }

  private func observe() {
    let banner = withObservationTracking {
      model.banner
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    present(banner)
  }

  private func present(_ banner: Landing?) {
    guard let banner else {
      shown = nil
      guard let departing = panel else { return }
      Task {
        try? await Task.sleep(for: .seconds(Self.exit))
        guard shown == nil, panel === departing else { return }
        dismantle()
        Logger.merges.log("Hid banner")
      }
      return
    }
    let pointer = NSEvent.mouseLocation
    let pointed = NSScreen.screens.first { $0.frame.contains(pointer) }
    guard banner.date != shown else { return }
    guard let screen = pointed ?? NSScreen.main else {
      Logger.merges.error("No screen for the banner")
      return
    }
    shown = banner.date
    dismantle()
    let placement = Self.placement(frame: screen.frame, visible: screen.visibleFrame)
    let panel = makePanel(frame: placement.panel, canvasOrigin: placement.canvas)
    self.panel = panel
    occlusion = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
    ) { [weak self, weak panel] _ in
      MainActor.assumeIsolated {
        guard let panel else { return }
        self?.logState("occlusion changed", of: panel)
      }
    }
    panel.orderFrontRegardless()
    Logger.merges.log(
      "Showed banner on \(screen.localizedName, privacy: .public) at \(String(describing: panel.frame), privacy: .public)"
    )
    logState("shown", of: panel)
    Task {
      try? await Task.sleep(for: .seconds(Slam.impact))
      logState("at impact", of: panel)
      try? await Task.sleep(for: .seconds(Self.lifetime - Slam.impact))
      if shown == banner.date { model.releaseBanner() }
    }
  }
}

private struct BannerStage: View {
  let dismiss: () -> Void
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  @State private var isHovering = false

  private static let offstage = MergeBanner.card.width + MergeBanner.margin

  var body: some View {
    ZStack {
      if let banner = model.banner {
        Choreography(start: banner.date, duration: Slam.settle) { time in
          BannerCard(pulls: model.pullRequests(in: banner), landing: banner)
            .onTapGesture {
              openWindow(id: "main")
              NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .overlay(alignment: .topLeading) {
              Button("Close", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 20, height: 20)
                .background(Palette.panel, in: .circle)
                .overlay { Circle().strokeBorder(Palette.rule) }
                .offset(x: -7, y: -7)
                .opacity(isHovering ? 1 : 0)
            }
            .onHover { isHovering = $0 }
            .position(
              x: MergeBanner.stage.width / 2, y: MergeBanner.stage.height * Slam.impactHeight
            )
            .offset(x: Self.offstage * (1 - UnitCurve.easeOut.value(at: time / Slam.settle)))
        }
        .transition(
          .asymmetric(
            insertion: .identity,
            removal: .offset(x: Self.offstage).combined(with: .opacity)))
        HammerSwing(slam: model.hammer(for: banner), overscan: MergeBanner.overscan)
          .transition(.identity)
      }
    }
    .frame(width: MergeBanner.stage.width, height: MergeBanner.stage.height)
    .animation(.easeIn(duration: MergeBanner.exit), value: model.banner == nil)
  }
}

private struct BannerCard: View {
  let pulls: [MergedPullRequest]
  let landing: Landing
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 12) {
      Image(
        nsImage: repository.flatMap { model.icons[$0.id] }
          ?? NSApplication.shared.applicationIconImage
      )
      .resizable()
      .frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
        HStack(spacing: 8) {
          Text(detail).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.secondary)
          if model.showsLineChanges {
            LineChanges(
              additions: pulls.map(\.additions).reduce(0, +),
              deletions: pulls.map(\.deletions).reduce(0, +), showsBar: false)
          }
        }
      }
      .lineLimit(1)
      Spacer(minLength: 8)
      MergedStamp(landing: landing).frame(height: 24)
    }
    .padding(.horizontal, 14)
    .frame(width: MergeBanner.card.width, height: MergeBanner.card.height)
    .background(Palette.panel, in: .rect(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.rule) }
    .overlay { HammerShatter(landing: landing).clipShape(.rect(cornerRadius: 18)) }
    .contentShape(.rect(cornerRadius: 18))
    .accessibilityElement(children: .combine)
  }

  private var repository: Repository? {
    Set(pulls.map(\.repository.id)).count == 1 ? pulls.first?.repository : nil
  }

  private var title: String {
    pulls.count == 1 ? pulls[0].title : "\(pulls.count) PRs merged"
  }

  private var detail: String {
    guard pulls.count == 1 else {
      return Set(pulls.map(\.repository.name)).sorted().joined(separator: ", ")
    }
    return "#\(String(pulls[0].number)) · \(pulls[0].repository.name)"
  }
}

extension NSPanel {
  static func overlay(frame: CGRect, level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = level
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.canHide = false
    return panel
  }
}
