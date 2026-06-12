//
//  HUDController.swift
//  Burrow
//
//  Hosts the menu-bar HUD (PopupView) so it can NEVER run off the bottom
//  of the screen, without a width-stealing scrollbar:
//
//    * The popover is capped to the visible screen height
//      (preferredContentSize), so however tall the content gets, the
//      dropdown stops at the screen edge.
//    * The content lives in a scroll view with FORCED overlay scrollers
//      (`scrollerStyle = .overlay`, auto-hiding). Overlay scrollers float
//      over the content and take no layout width — even when the system
//      "Show scroll bars" preference is set to "Always" (which is what
//      pushed the content left before). When the content fits, nothing
//      scrolls and no scroller shows at all.
//

import AppKit
import SwiftUI

final class HUDController: NSViewController {
    private let hosting: NSHostingView<PopupView>

    init(root: PopupView) {
        self.hosting = NSHostingView(rootView: root)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var maxHeight: CGFloat {
        max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 28)
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        // No scroller object at all → no scrollbar can ever appear (not
        // even with "Show scroll bars: Always"). Overflow still scrolls via
        // trackpad/wheel; in practice the panel is capped to the screen so
        // it rarely needs to.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false

        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hosting.widthAnchor.constraint(equalToConstant: 334),
        ])
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The hosting view's height floats on its SwiftUI intrinsic size
        // (only top/leading/width are pinned). A document-view frame change
        // does NOT relayout the enclosing scroll view, so viewDidLayout
        // alone misses content growing or shrinking while the popover is
        // open — Activity cards appearing, the battery card mounting after
        // the first sample. Watch the frame directly and resize the popover
        // to match, so its height always tracks the content.
        hosting.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: hosting)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentFrameChanged(_ note: Notification) {
        syncPopoverHeight()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncPopoverHeight()
    }

    /// Popover height = content height, capped to the visible screen;
    /// beyond the cap the internal scroll view takes over.
    private func syncPopoverHeight() {
        var contentH = hosting.intrinsicContentSize.height
        if contentH <= 0 { contentH = hosting.fittingSize.height }
        let target = NSSize(width: 334, height: min(max(contentH, 1), maxHeight))
        if abs(preferredContentSize.height - target.height) > 0.5 || preferredContentSize.width != target.width {
            preferredContentSize = target
        }
    }
}
