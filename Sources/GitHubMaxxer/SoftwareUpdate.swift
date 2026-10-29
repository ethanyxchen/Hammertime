import Sparkle

@MainActor @Observable
final class SoftwareUpdate {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  private var observation: NSKeyValueObservation?

  private(set) var canCheck = false

  var checksAutomatically: Bool {
    didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
  }

  init() {
    checksAutomatically = controller.updater.automaticallyChecksForUpdates
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
    }
  }

  func check() { controller.checkForUpdates(nil) }
}
