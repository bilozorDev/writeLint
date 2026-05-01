import Testing
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Linter

/// SwiftUI snapshot tests. Reference images would live in
/// `LinterTests/__Snapshots__/` (the default `swift-snapshot-testing` path).
///
/// **Currently disabled** — see suite trait below. The Linter app has
/// `ENABLE_APP_SANDBOX = YES`, and the test bundle inherits that sandbox from
/// the host app's process, so writes outside the sandbox container are
/// blocked (including the source-tree `__Snapshots__/` directory). The
/// `assertSnapshot` API exposes `file:` as `StaticString`, not `String`, so
/// the snapshot directory cannot be redirected at runtime.
///
/// To enable: set `ENABLE_APP_SANDBOX = NO` on the **Linter** target's
/// **Debug** configuration only (Release stays sandboxed and ships
/// unchanged). After that, remove the `.disabled` trait below and run the
/// suite once with `withSnapshotTesting(record: .missing) { ... }` wrapping
/// each test, or set `SNAPSHOT_TESTING_RECORD=true` in the scheme's env, to
/// generate the reference images. Then commit `LinterTests/__Snapshots__/`.
///
/// Host-dependence: `swift-snapshot-testing` renders against the host's font
/// metrics and Retina scale, so cross-machine drift is expected. Convention:
/// first committer wins; others regenerate locally with `record: true` if a
/// divergence is intentional. CI is pinned to arm64 for stability.
@Suite(
    "SwiftUI snapshots — InputRow, DiffView, ResultActions, etc.",
    .disabled("App Sandbox blocks writes to LinterTests/__Snapshots__/. Disable sandbox on the Linter Debug build to enable.")
)
@MainActor
struct SnapshotTests {

    // MARK: helpers

    private static let pageWidth: CGFloat = 660

    /// Wrap a SwiftUI view in an `NSHostingView` sized at the panel's
    /// canonical width so SnapshotTesting can render it via the macOS
    /// `NSView -> NSImage` strategy. Uses `.idealHeight()` semantics by
    /// laying out at the requested height; pass enough vertical space.
    private func host<V: View>(_ view: V, height: CGFloat, dark: Bool) -> NSView {
        let scheme: ColorScheme = dark ? .dark : .light
        let wrapped = view.preferredColorScheme(scheme)
        let host = NSHostingView(rootView: wrapped)
        host.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: height)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: InputRow — idle (empty text)

    @Test func inputRowIdleLight() {
        let v = host(InputRowSnapshotHarness(text: "", dark: false), height: 80, dark: false)
        assertSnapshot(of: v, as: .image, named: "input-row-idle-light")
    }

    @Test func inputRowIdleDark() {
        let v = host(InputRowSnapshotHarness(text: "", dark: true), height: 80, dark: true)
        assertSnapshot(of: v, as: .image, named: "input-row-idle-dark")
    }

    @Test func inputRowWithTextLight() {
        let v = host(InputRowSnapshotHarness(text: "i has went to the store", dark: false), height: 80, dark: false)
        assertSnapshot(of: v, as: .image, named: "input-row-with-text-light")
    }

    // MARK: DiffView — sample diff in both color schemes

    @Test func diffViewSampleLight() {
        let ops = Diff.diff(
            "i has went to the store yesterday",
            "I have gone to the store yesterday."
        )
        let v = host(DiffView(ops: ops, dark: false), height: 220, dark: false)
        assertSnapshot(of: v, as: .image, named: "diff-view-sample-light")
    }

    @Test func diffViewSampleDark() {
        let ops = Diff.diff(
            "i has went to the store yesterday",
            "I have gone to the store yesterday."
        )
        let v = host(DiffView(ops: ops, dark: true), height: 220, dark: true)
        assertSnapshot(of: v, as: .image, named: "diff-view-sample-dark")
    }

    // MARK: ResultActions — footer with stats + buttons

    @Test func resultActionsLight() {
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: false,
            dark: false,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: false)
        assertSnapshot(of: v, as: .image, named: "result-actions-light")
    }

    @Test func resultActionsDark() {
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: false,
            dark: true,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: true)
        assertSnapshot(of: v, as: .image, named: "result-actions-dark")
    }

    @Test func resultActionsAfterCopy() {
        // The "Copied" pulse state — verifies the post-click visual.
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: true,
            dark: false,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: false)
        assertSnapshot(of: v, as: .image, named: "result-actions-copied")
    }

    // MARK: SettingsPanel — advanced mode off vs on

    @Test func settingsPanelAdvancedModeOff() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        store.advancedMode = false
        let view = SettingsPanelHarness(store: store, dark: false)
        let v = host(view, height: 300, dark: false)
        assertSnapshot(of: v, as: .image, named: "settings-panel-advanced-off")
    }

    @Test func settingsPanelAdvancedModeOn() {
        // Advanced mode reveals the prompt editor — the slide-page layout is
        // invariant-load-bearing per CLAUDE.md, so a snapshot here catches
        // accidental changes to the editor's height contribution.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        store.advancedMode = true
        let view = SettingsPanelHarness(store: store, dark: false)
        let v = host(view, height: 540, dark: false)
        assertSnapshot(of: v, as: .image, named: "settings-panel-advanced-on")
    }

    // MARK: HistoryView — empty + populated

    @Test func historyViewEmpty() {
        let view = HistoryView(
            entries: [],
            dark: false,
            onPick: { _ in },
            onClear: {},
            onClose: {}
        )
        let v = host(view, height: 100, dark: false)
        assertSnapshot(of: v, as: .image, named: "history-empty")
    }

    @Test func historyViewPopulated() {
        // Three sample entries — cap is 10, so this exercises the typical
        // mid-state. Use stable UUIDs and dates so the snapshot is reproducible
        // (otherwise re-rendering produces a fresh UUID each run).
        let entries = [
            PromptEntry(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, text: "fix this typo", date: Date(timeIntervalSince1970: 770_000_000)),
            PromptEntry(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, text: "make this more concise", date: Date(timeIntervalSince1970: 769_000_000)),
            PromptEntry(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, text: "polish the greeting", date: Date(timeIntervalSince1970: 768_000_000)),
        ]
        let view = HistoryView(
            entries: entries,
            dark: false,
            onPick: { _ in },
            onClear: {},
            onClose: {}
        )
        let v = host(view, height: 240, dark: false)
        assertSnapshot(of: v, as: .image, named: "history-populated")
    }

    // MARK: ThinkingBar — in-progress state

    @Test func thinkingBarLight() {
        let v = host(ThinkingBar(dark: false), height: 60, dark: false)
        assertSnapshot(of: v, as: .image, named: "thinking-bar-light")
    }
}

// MARK: - InputRow harness
// InputRow takes a `FocusState<Bool>.Binding`, which can't be constructed
// outside a `@FocusState`-bearing parent. This harness wraps it.

struct InputRowSnapshotHarness: View {
    let text: String
    let dark: Bool

    @FocusState private var focused: Bool

    var body: some View {
        InputRow(
            text: .constant(text),
            dark: dark,
            settingsOpen: false,
            isFocused: $focused,
            onSubmit: {},
            onToggleSettings: {}
        )
        .frame(width: 660)
        .background(Color(white: dark ? 0.1 : 0.97))
    }
}

// MARK: - SettingsPanel harness
// SettingsPanel needs an `@Bindable` store and a `Binding<Bool>` for autoHide;
// this harness wires up a local @State so the view can be rendered in
// isolation without LinterWindow.

struct SettingsPanelHarness: View {
    @Bindable var store: PromptStore
    let dark: Bool
    @State private var autoHide: Bool = true

    var body: some View {
        SettingsPanel(store: store, autoHide: $autoHide, dark: dark)
            .frame(width: 660)
    }
}
