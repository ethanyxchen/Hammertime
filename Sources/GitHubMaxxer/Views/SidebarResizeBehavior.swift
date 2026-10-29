import AppKit
import SwiftUI

struct SidebarResizeBehavior: NSViewRepresentable {
  var minimumWidthWithSidebar: CGFloat

  func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }

  func updateNSView(_ nsView: ConfigurationView, context: Context) {
    nsView.minimumWidthWithSidebar = minimumWidthWithSidebar
    nsView.configure()
  }

  final class ConfigurationView: NSView {
    var minimumWidthWithSidebar: CGFloat = 0 {
      didSet { minimumWidth?.constant = minimumWidthWithSidebar }
    }
    private var observation: NSKeyValueObservation?
    private var minimumWidth: NSLayoutConstraint?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      guard newWindow !== window else { return }
      observation?.invalidate()
      observation = nil
      minimumWidth?.isActive = false
      minimumWidth = nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configure()
    }

    func configure() {
      guard let sidebar = enclosingSplitView?.sidebarItem, let contentView = window?.contentView
      else { return }
      if sidebar.collapseBehavior != .useConstraints { sidebar.collapseBehavior = .useConstraints }
      guard observation == nil else { return }
      let minimumWidth = contentView.widthAnchor.constraint(
        greaterThanOrEqualToConstant: minimumWidthWithSidebar)
      minimumWidth.priority = .defaultHigh
      self.minimumWidth = minimumWidth
      observation = sidebar.observe(\.isCollapsed, options: [.initial, .new]) {
        [weak self] item, _ in
        let collapsed = item.isCollapsed
        MainActor.assumeIsolated { self?.minimumWidth?.isActive = !collapsed }
      }
    }
  }
}
