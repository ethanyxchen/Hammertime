import AppKit
import SwiftUI
import os

@MainActor
final class ScreenSmash {
  private let model: AppModel
  private var panel: NSPanel?
  private var shown: Date?

  init(model: AppModel) {
    self.model = model
    observe()
  }

  private func observe() {
    let slam = withObservationTracking {
      model.smash
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    guard let slam, slam != shown else { return }
    shown = slam
    smash(slam)
  }

  private func smash(_ slam: Date) {
    let pointer = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    else { return }
    panel?.orderOut(nil)
    let panel = NSPanel.overlay(frame: screen.frame, level: .screenSaver)
    panel.ignoresMouseEvents = true
    panel.contentView = NSHostingView(
      rootView: ScreenCracks(slam: slam)
        .frame(width: screen.frame.width, height: screen.frame.height))
    panel.orderFrontRegardless()
    Logger.merges.log(
      "Cracked \(screen.localizedName, privacy: .public) at \(String(describing: panel.frame), privacy: .public)"
    )
    self.panel = panel
    Task {
      let remaining = slam.addingTimeInterval(ScreenCracks.duration).timeIntervalSinceNow
      try? await Task.sleep(for: .seconds(max(0, remaining)))
      guard self.panel === panel else { return }
      panel.orderOut(nil)
      self.panel = nil
    }
  }
}
