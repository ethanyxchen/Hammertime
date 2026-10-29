import AppKit
import SwiftUI

struct SidebarResizeBehavior: NSViewRepresentable {
  var onCollapse: @MainActor (Bool) -> Void = { _ in }

  func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }

  func updateNSView(_ nsView: ConfigurationView, context: Context) {
    nsView.callback.onCollapse = onCollapse
    nsView.configure()
  }

  @MainActor
  final class Callback {
    var onCollapse: @MainActor (Bool) -> Void = { _ in }
  }

  final class ConfigurationView: NSView {
    let callback = Callback()
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configure()
    }

    func configure() {
      let splitView =
        sequence(first: self as NSView, next: { $0.superview })
        .first { $0 is NSSplitView } as? NSSplitView
      guard let controller = splitView?.delegate as? NSSplitViewController,
        let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar })
      else { return }
      if sidebar.collapseBehavior != .useConstraints { sidebar.collapseBehavior = .useConstraints }
      guard observation == nil else { return }
      let callback = callback
      observation = sidebar.observe(\.isCollapsed, options: [.initial, .old, .new]) {
        item, change in
        let collapsed = item.isCollapsed
        if change.oldValue == nil {
          DispatchQueue.main.async { MainActor.assumeIsolated { callback.onCollapse(collapsed) } }
        } else {
          MainActor.assumeIsolated { callback.onCollapse(collapsed) }
        }
      }
    }
  }
}
