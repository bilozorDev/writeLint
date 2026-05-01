import SwiftUI
import AppKit

@main
struct LinterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Show Write Lint  \(HotkeyStore.shared.current.display)") {
                PanelController.shared.show()
            }
            Divider()
            Button("Quit Write Lint") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: Hotkey = HotkeyStore.shared.current
    private var store: PromptStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = PromptStore()
        let storeRef = store!

        // Build the floating panel + its SwiftUI root.
        PanelController.shared.makePanel {
            LinterRoot(store: storeRef)
        }

        // Install Carbon hotkey handler and register the saved chord.
        GlobalHotkey.shared.install {
            PanelController.shared.toggle()
        }
        GlobalHotkey.shared.setHotkey(HotkeyStore.shared.current)

        // Pre-load the on-device model so the first lint after the user
        // summons the panel doesn't pay the 100–300 ms cold-start tax.
        FoundationModelService.shared.prewarm()

        // Show on first launch so the user sees the app immediately.
        PanelController.shared.show()
    }
}

/// Wraps `LinterWindow` so the @State `hotkey` lives in a stable place and
/// drives both the UI and the global Carbon registration.
struct LinterRoot: View {
    @Bindable var store: PromptStore
    @State private var hotkey: Hotkey = HotkeyStore.shared.current

    var body: some View {
        LinterWindow(store: store, hotkey: $hotkey)
            .onChange(of: hotkey) { _, new in
                HotkeyStore.shared.set(new)
            }
    }
}
