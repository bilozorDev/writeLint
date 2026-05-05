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
            // Custom logo asset, marked Template Image in Assets.xcassets
            // so macOS auto-tints it (white in dark mode, black in light,
            // accent-colored when the menu is open). Explicit frame because
            // SVG assets render at their intrinsic viewBox size by default,
            // which for this logo is 640pt — needs to be constrained to the
            // standard 18pt menu-bar icon size.
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        // Suppressed under XCTest: the unit/integration tests use Linter.app
        // as a test host, so without this gate every `xcodebuild test`
        // summons the floating panel — the dim material + drop shadow read
        // as the screen briefly going dark. The host process's `userInfo`
        // dictionary contains `XCTestConfigurationFilePath` only during a
        // test run, never in normal launches.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            PanelController.shared.show()
        }
    }
}

/// Thin wrapper kept for symmetry with how `MenuBarExtra`'s content is
/// constructed. The hotkey is read directly from the `@Observable`
/// `HotkeyStore` singleton everywhere it's needed, so no @State snapshot
/// here — that previously caused two sources of truth (LinterRoot's @State
/// vs. HotkeyStore.shared) that only stayed in sync because writes went
/// through ShortcutRecorderView.
struct LinterRoot: View {
    @Bindable var store: PromptStore

    var body: some View {
        LinterWindow(store: store)
    }
}
