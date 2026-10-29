import AppKit

extension NSView {
  var enclosingSplitView: NSSplitView? {
    sequence(first: self, next: \.superview).lazy.compactMap { $0 as? NSSplitView }.first
  }
}

extension NSSplitView {
  var sidebarItem: NSSplitViewItem? {
    (delegate as? NSSplitViewController)?.splitViewItems.first { $0.behavior == .sidebar }
  }
}
