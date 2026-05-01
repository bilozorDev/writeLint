import AppKit
import SwiftUI
import Observation

/// Compute the panel origin so the panel sits Spotlight-style — horizontally
/// centered on the given screen, slightly above center vertically. Pure
/// function over its inputs; testable without an NSPanel. Used by
/// `PanelController.centerOnActiveScreen()`.
func panelOrigin(for screenFrame: NSRect, panelSize: NSSize) -> NSPoint {
    let x = screenFrame.midX - panelSize.width / 2
    let y = screenFrame.midY + panelSize.height * 0.2 - panelSize.height / 2
    return NSPoint(x: x, y: y)
}

@MainActor
@Observable
final class PanelController {
    static let shared = PanelController()

    private var panel: FloatingPanel?
    /// Seed width for the panel's content rect. SwiftUI's
    /// `.preferredContentSize` overrides this once the hosting controller lays
    /// out, but a seed close to the final width avoids a visible 1-frame
    /// resize on first show. Must stay in lock-step with `LinterWindow.pageWidth`.
    private let panelWidth: CGFloat = 660

    /// Set by `LinterWindow` so summon can re-focus the input field.
    var requestFocus: () -> Void = {}
    /// Set by `LinterWindow` so panel-hide can reset transient state
    /// (input text, result, settings open, etc.).
    var onHide: () -> Void = {}
    /// Set by `LinterWindow` so summon can re-read state that may have
    /// changed while the panel was hidden (e.g. Apple Intelligence
    /// availability flipping from .unavailable to .available).
    var onShow: () -> Void = {}

    /// Stamp incremented on every `show()`. The deferred onHide closure
    /// captures the value at hide-time and only clears state if no new
    /// session has started since — guards against the user re-summoning
    /// faster than the runloop turn that fires onHide. Read by views that
    /// schedule deferred work tied to a session (e.g. autoHide-after-accept)
    /// so the work no-ops if a fresh session has begun.
    private(set) var sessionStamp: Int = 0

    private init() {}

    func makePanel<Content: View>(@ViewBuilder content: () -> Content) {
        guard panel == nil else { return }
        let p = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 60),
            content: content
        )
        self.panel = p
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }
        sessionStamp &+= 1
        centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onShow()
        // Focus on next runloop turn so the SwiftUI view has installed.
        DispatchQueue.main.async { [weak self] in
            self?.requestFocus()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        // Defer the state-clearing closure to the next runloop turn so it
        // never re-enters AppKit/SwiftUI mid-update if `hide()` was called
        // from inside a layout pass or event handler. Skip if the user
        // re-summoned in the meantime (sessionStamp changed).
        let cb = onHide
        let stamp = sessionStamp
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionStamp == stamp else { return }
            cb()
        }
    }

    private func centerOnActiveScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        // Force the hosting controller to load its view so SwiftUI computes its
        // intrinsic size and `.preferredContentSize` propagates to the panel
        // BEFORE we read `panel.frame.size` for centering. Without this the
        // first show() centers using the seed contentRect (e.g. 580x60) and the
        // panel ends up offset.
        panel.contentViewController?.loadViewIfNeeded()
        panel.layoutIfNeeded()
        // Disable the top-anchor on the very first placement so we honor the
        // user's chosen origin (Spotlight-ish above-center) instead of pinning
        // to whatever the previous frame's top edge was.
        let wasAnchoring = panel.anchorsTopEdge
        panel.anchorsTopEdge = false
        defer { panel.anchorsTopEdge = wasAnchoring }
        panel.setFrameOrigin(panelOrigin(for: screen.visibleFrame, panelSize: panel.frame.size))
    }
}
