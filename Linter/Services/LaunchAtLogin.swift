import AppKit
import ServiceManagement
import os

/// Pure mapping from the system's login-item registration status to the two
/// flags the UI cares about. Kept as a free `internal` function (no I/O, no
/// logging) so it's a deterministic unit-test seam — same convention as
/// `panelOrigin(for:panelSize:)` in `Window/PanelController.swift`. The
/// `.notFound` breadcrumb is logged by the caller (`refresh()`), not here,
/// so this stays pure.
// `nonisolated` (the project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor):
// keeps the type's synthesized `Equatable` and this pure mapping usable from
// any isolation — it's the cross-actor unit-test seam, and the conformance
// would otherwise be MainActor-isolated (a Swift 6 error).
nonisolated struct LoginItemState: Equatable {
    var isEnabled: Bool
    var requiresApproval: Bool
}

nonisolated func loginItemState(for status: SMAppService.Status) -> LoginItemState {
    switch status {
    case .enabled:
        return LoginItemState(isEnabled: true, requiresApproval: false)
    case .requiresApproval:
        // register() "succeeds" but the OS won't actually launch us until
        // the user re-enables the item under System Settings > Login Items.
        return LoginItemState(isEnabled: false, requiresApproval: true)
    case .notRegistered:
        return LoginItemState(isEnabled: false, requiresApproval: false)
    case .notFound:
        // Corrupt/missing registration — treat as off; caller logs it.
        return LoginItemState(isEnabled: false, requiresApproval: false)
    @unknown default:
        return LoginItemState(isEnabled: false, requiresApproval: false)
    }
}

/// Owns the app's "launch at login" state. The **system** is the source of
/// truth (`SMAppService.mainApp.status`), not UserDefaults — so the toggle
/// never drifts from a change the user makes directly in System Settings.
/// Shape mirrors `HotkeyStore` (`@MainActor @Observable` singleton).
@MainActor
@Observable
final class LaunchAtLoginStore {
    @ObservationIgnored
    static let shared = LaunchAtLoginStore()

    @ObservationIgnored
    private let log = Logger(subsystem: "Hexaget.WriteLint", category: "launch")

    /// Observer tokens. The singleton lives for the whole process, so these
    /// are never removed — held only to keep ownership explicit.
    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    /// Registered AND approved as a login item.
    private(set) var isEnabled: Bool = false
    /// User disabled the item under System Settings > Login Items; the
    /// in-app toggle alone can't override that. Drives the inline hint.
    private(set) var requiresApproval: Bool = false

    private init() {
        // The Settings page lives inside the single non-activating
        // FloatingPanel (LinterWindow → SettingsPanel via PageSlideLayout),
        // not a separate window. The panel `canBecomeKey` (its TextField
        // needs first responder), so didBecomeKey genuinely fires when the
        // user returns focus to it after a System Settings detour. The page
        // `.onAppear` refresh remains the guaranteed path on re-summon;
        // these observers cover "panel stayed open across the detour".
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { LaunchAtLoginStore.shared.refresh() } }
        )
        observers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil, queue: .main
            ) { note in
                guard note.object is FloatingPanel else { return }
                MainActor.assumeIsolated { LaunchAtLoginStore.shared.refresh() }
            }
        )
        refresh()
    }

    /// Re-reads the system status into the observable flags. Cheap; safe to
    /// call often (init, page `.onAppear`, app/panel reactivation).
    func refresh() {
        let status = SMAppService.mainApp.status
        if status == .notFound {
            log.error("login-item status .notFound (corrupt/missing registration)")
        }
        let state = loginItemState(for: status)
        isEnabled = state.isEnabled
        requiresApproval = state.requiresApproval
    }

    /// Registers/unregisters the main app as a login item, then refreshes.
    /// Returns whether the desired state was actually reached (e.g. turning
    /// on while `requiresApproval` returns false — the caller's toggle then
    /// snaps back and the inline hint appears).
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("login-item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            refresh()
            return false
        }
        refresh()
        return on ? isEnabled : !isEnabled
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
