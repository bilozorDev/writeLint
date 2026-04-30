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
        if let hc = panel.contentViewController as? NSHostingController<AnyView> {
            hc.loadViewIfNeeded()
        } else {
            panel.contentViewController?.loadViewIfNeeded()
        }
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
