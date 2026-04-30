import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class PanelController {
    static let shared = PanelController()

    private var panel: FloatingPanel?
    private let panelWidth: CGFloat = 580

    /// Set by `LinterWindow` so summon can re-focus the input field.
    var requestFocus: () -> Void = {}
    /// Set by `LinterWindow` so panel-hide can reset transient state
    /// (input text, result, settings open, etc.).
    var onHide: () -> Void = {}

    /// Stamp incremented on every `show()`. The deferred onHide closure
    /// captures the value at hide-time and only clears state if no new
    /// session has started since — guards against the user re-summoning
    /// faster than the runloop turn that fires onHide.
    private var sessionStamp: Int = 0

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
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        // Place a bit above center, like Spotlight.
        let y = visible.midY + size.height * 0.2 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
