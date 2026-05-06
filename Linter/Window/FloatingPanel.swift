import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    /// When true, `setContentSize` keeps the panel's TOP edge and horizontal
    /// CENTER fixed instead of its bottom-left origin (NSWindow's default), so
    /// the visible card stays put as the SwiftUI content grows in any direction
    /// (settings open, result appears, scrollbar shows in "Always" mode).
    var anchorsTopEdge: Bool = true

    init<Content: View>(contentRect: NSRect, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isMovableByWindowBackground = true
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        // SwiftUI view draws its own shadow on the rounded card.
        self.hasShadow = false
        self.backgroundColor = .clear
        self.isOpaque = false

        // NSHostingController with .preferredContentSize lets SwiftUI's
        // intrinsic size drive the window's content size automatically — that's
        // how the panel grows when the settings panel opens, the slash menu
        // appears, or a result is shown, and shrinks when they go away.
        let hc = NSHostingController(rootView: content())
        hc.sizingOptions = [.preferredContentSize]
        self.contentViewController = hc
        // Belt-and-suspenders: ensure no AppKit-side fill paints behind the SwiftUI card.
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Esc closes the panel. Route through PanelController.hide() rather
        // than orderOut(nil) directly so the session-stamp + onHide cleanup
        // runs (cancels in-flight lint, clears text/result/settings state).
        // Today this is normally masked by CommandKeyMonitor consuming Esc
        // first, but if the monitor isn't installed yet (first-frame timing)
        // or focus is in a place the local monitor doesn't catch, AppKit
        // dispatches Esc here — and we don't want a running lint task or
        // populated state surviving the close.
        Task { @MainActor in PanelController.shared.hide() }
    }

    /// Keep the top edge and horizontal center stationary across content-size
    /// changes so the visible card doesn't shift in any direction when the
    /// SwiftUI tree's intrinsic size changes. After the recentre, clamp the
    /// resulting frame inside the screen's `visibleFrame` so that growing
    /// from 660pt to 760pt (Settings open) doesn't push the panel off the
    /// right edge when the user has dragged it close to one. Same on the
    /// vertical axis: a tall settings page can't fall off the bottom of
    /// the screen if the panel was anchored low.
    override func setContentSize(_ size: NSSize) {
        guard anchorsTopEdge, isVisible else {
            super.setContentSize(size)
            return
        }
        let oldTopY = frame.origin.y + frame.size.height
        let oldCenterX = frame.origin.x + frame.size.width / 2
        super.setContentSize(size)
        var newOrigin = frame.origin
        newOrigin.y = oldTopY - frame.size.height
        newOrigin.x = oldCenterX - frame.size.width / 2
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let maxX = max(visible.minX, visible.maxX - frame.size.width)
            let maxY = max(visible.minY, visible.maxY - frame.size.height)
            newOrigin.x = min(max(newOrigin.x, visible.minX), maxX)
            newOrigin.y = min(max(newOrigin.y, visible.minY), maxY)
        }
        setFrameOrigin(newOrigin)
    }
}
