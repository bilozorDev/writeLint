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

    /// Mouse-down monitors installed while the panel is visible to dismiss
    /// on click-outside (Spotlight-style). Local monitor lets clicks on the
    /// panel and its attached sheets through; everything else triggers hide.
    /// Global monitor catches clicks in other apps and the system menu bar.
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    /// Set by `LinterWindow` so summon can re-focus the input field.
    var requestFocus: () -> Void = {}
    /// Set by `LinterWindow` so panel-hide can reset transient state
    /// (input text, result, settings open, etc.).
    var onHide: () -> Void = {}
    /// Set by `LinterWindow` so summon can re-read state that may have
    /// changed while the panel was hidden (e.g. Apple Intelligence
    /// availability flipping from .unavailable to .available).
    var onShow: () -> Void = {}
    /// Set by `LinterWindow`. Returns whether a click outside the panel
    /// should dismiss the panel. Returns `false` while Settings is open
    /// so the user can copy/paste between the template editor and
    /// another app without losing in-progress edits. Closure form (not
    /// a Bool) so the dismiss monitors evaluate it at click time —
    /// mutating an observed Bool from `LinterWindow` would race with
    /// the @State reference captured at `.onAppear` time.
    var shouldDismissOnClickOutside: () -> Bool = { true }

    /// Stamp incremented on every `show()`. The deferred onHide closure
    /// captures the value at hide-time and only clears state if no new
    /// session has started since — guards against the user re-summoning
    /// faster than the runloop turn that fires onHide. Read by views that
    /// schedule deferred work tied to a session (e.g. autoHide-after-accept)
    /// so the work no-ops if a fresh session has begun.
    private(set) var sessionStamp: Int = 0

    /// App that was frontmost when the panel was summoned by hotkey,
    /// captured before `NSApp.activate` steals focus. Reactivated on
    /// dismiss so the user can ⌘V into wherever they were typing without
    /// clicking back. Nil when summoned via the menu-bar item or first-launch
    /// (those paths don't capture). Cleared synchronously in
    /// `restorePreviousApp()` so a rapid dismiss/re-summon can't double-
    /// activate or stomp on a fresh capture.
    private var previousApp: NSRunningApplication?

    private init() {}

    func makePanel<Content: View>(@ViewBuilder content: () -> Content) {
        guard panel == nil else { return }
        let p = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 60),
            content: content
        )
        self.panel = p
    }

    func toggle(captureFrontmost: Bool = false) {
        guard let panel else { return }
        if panel.isVisible {
            hide()
        } else {
            show(captureFrontmost: captureFrontmost)
        }
    }

    func show(captureFrontmost: Bool = false) {
        guard let panel else { return }
        // Already visible → no-op. Without this, a redundant show() (e.g.
        // tapping the menu-bar "Show Write Lint" item while the panel is
        // somehow already on screen) would re-run installDismissMonitors and
        // leak the previous monitor pair.
        if panel.isVisible { return }
        // Capture the current frontmost app BEFORE `NSApp.activate` below
        // steals focus, but AFTER the isVisible early-return so a redundant
        // show() can't overwrite a valid capture with stale state. Skip when
        // Linter itself is already frontmost (defensive against re-summon
        // edge cases — restoring "self" would be a no-op anyway).
        if captureFrontmost {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = frontmost
            }
        }
        sessionStamp &+= 1
        centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
        onShow()
        // Focus on next runloop turn so the SwiftUI view has installed.
        DispatchQueue.main.async { [weak self] in
            self?.requestFocus()
        }
    }

    func hide() {
        removeDismissMonitors()
        // Hand focus back BEFORE ordering out so the focus change lands while
        // the panel is still visible — matches the toast-time path
        // (`LinterWindow.handleAccept`), where activation precedes the
        // deferred `hide()`. No-op when `previousApp` is nil, which happens
        // for non-hotkey summons or when the global mouse monitor / toast-
        // time call already cleared it.
        restorePreviousApp()
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

    /// Reactivate the app that was frontmost before the panel was summoned,
    /// then clear the capture. Called from `hide()` for the standard dismiss
    /// paths (Esc, hotkey toggle-off, accept-without-autoHide). Called
    /// directly from `LinterWindow.handleAccept` on the autoHide path so
    /// focus returns at toast-show time — that lets the user ⌘V immediately
    /// while the "Copied" toast is still visible briefly over the restored
    /// app. Synchronous clear; second invocation is a no-op.
    func restorePreviousApp() {
        // `activate()` (no-arg, macOS 14+) returns false silently if the app
        // has quit or refuses cooperative activation — both are correct
        // failure modes for "user came back to a now-gone window".
        previousApp?.activate()
        previousApp = nil
    }

    private func installDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self, self.shouldDismissOnClickOutside() else { return }
            // The user clicked into another app deliberately — focus is
            // already where they want it. Drop the capture so `hide()` won't
            // yank them back to the previously-focused app.
            self.previousApp = nil
            self.hide()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // Pass through clicks on the panel and on any sheet attached to it
            // — SwiftUI `.alert` (e.g. SettingsPanel's Revert confirmation)
            // renders as a window-modal sheet whose `sheetParent === panel`.
            if event.window === panel || event.window?.sheetParent === panel {
                return event
            }
            // Suppress click-outside dismiss while Settings is open
            // (`shouldDismissOnClickOutside` returns false in that case).
            // The user can still close via Back / Esc / clicking the gear.
            if !self.shouldDismissOnClickOutside() {
                return event
            }
            self.hide()
            return event
        }
    }

    private func removeDismissMonitors() {
        if let t = localMouseMonitor  { NSEvent.removeMonitor(t); localMouseMonitor  = nil }
        if let t = globalMouseMonitor { NSEvent.removeMonitor(t); globalMouseMonitor = nil }
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
