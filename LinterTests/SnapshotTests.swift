import Testing
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Write_Lint

/// SwiftUI snapshot tests. Reference images live in
/// `LinterTests/__Snapshots__/` (the default `swift-snapshot-testing` path).
///
/// Sandbox is disabled on the **Write Lint** target's Debug configuration
/// only (Release stays sandboxed and ships unchanged), which lets the test
/// bundle write reference PNGs into the source tree. The `assertSnapshot`
/// API exposes `file:` as `StaticString`, so the snapshot directory can't
/// be redirected at runtime — disabling sandbox is the only path.
///
/// Record mode: every call passes `record: .missing`. The first run writes
/// any missing reference, subsequent runs verify against it. To
/// intentionally re-record after a UI change, delete the matching
/// `__Snapshots__/<name>.png` and run the suite once.
///
/// Host-dependence: `swift-snapshot-testing` renders against the host's
/// font metrics and Retina scale, so references are pinned to whichever
/// machine — and *display configuration* — recorded them. Plugging in /
/// unplugging an external monitor between record and verify can flip the
/// effective backing scale (1x ↔ 2x) and invalidate every reference.
/// When that happens the fix is the same workflow as a deliberate UI
/// change: delete the affected `__Snapshots__/<name>.png` files, run the
/// suite once, commit. Single-developer project: not a serious concern.
@Suite("SwiftUI snapshots — InputRow, DiffView, ResultActions, etc.")
@MainActor
struct SnapshotTests {

    // MARK: helpers

    private static let pageWidth: CGFloat = 660

    /// Build a `PromptStore` for snapshot test fixtures. With
    /// `advancedMode == false` (the init default) the store's
    /// `activeBackend` is `.onDevice`, which is what every snapshot
    /// captures — these tests verify the on-device rendering path. Uses a
    /// per-test isolated Keychain service so we never read the
    /// developer's real saved keys (which would flip `hasClaudeKey` and
    /// change the rendered Settings panel state).
    private func snapshotStore() -> PromptStore {
        let scratch = ScratchDefaults.make()
        return PromptStore(
            defaults: scratch.defaults,
            keychainService: "linter.tests.snapshot.\(UUID().uuidString)",
            claudeAccount: "snap-claude",
            openaiAccount: "snap-openai"
        )
    }

    /// Wrap a SwiftUI view in an `NSHostingView` sized at the panel's
    /// canonical width so SnapshotTesting can render it via the macOS
    /// `NSView -> NSImage` strategy. Uses `.idealHeight()` semantics by
    /// laying out at the requested height; pass enough vertical space.
    private func host<V: View>(_ view: V, height: CGFloat, dark: Bool) -> NSView {
        let scheme: ColorScheme = dark ? .dark : .light
        // Panel backdrop. Without this, views with translucent backgrounds
        // (e.g. `Palette.footerBg = .black.opacity(0.18)`, or any unset
        // background that defaults to clear) composite against the test
        // runner's default white surface — which makes dark-mode snapshots
        // look washed out and turns white text invisible. The real app
        // sits on top of `.thickMaterial`, which renders as ~`#262626` in
        // dark mode and ~`#ECECEC` in light. Using a flat solid in those
        // tones gets us a close enough approximation for visual review,
        // and snapshot determinism doesn't require pixel-exact material
        // rendering.
        let backdrop = dark
            ? Color(.sRGB, red: 0.15, green: 0.15, blue: 0.16, opacity: 1)
            : Color(.sRGB, red: 0.93, green: 0.93, blue: 0.93, opacity: 1)
        let wrapped = ZStack {
            backdrop
            view
        }
        .preferredColorScheme(scheme)
        let host = NSHostingView(rootView: wrapped)
        host.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: height)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: InputRow — idle (empty text)

    @Test func inputRowIdleLight() {
        let v = host(InputRowSnapshotHarness(text: "", dark: false), height: 80, dark: false)
        assertSnapshot(of: v, as: .image, named: "input-row-idle-light", record: .missing)
    }

    @Test func inputRowIdleDark() {
        let v = host(InputRowSnapshotHarness(text: "", dark: true), height: 80, dark: true)
        assertSnapshot(of: v, as: .image, named: "input-row-idle-dark", record: .missing)
    }

    @Test func inputRowWithTextLight() {
        let v = host(InputRowSnapshotHarness(text: "i has went to the store", dark: false), height: 80, dark: false)
        assertSnapshot(of: v, as: .image, named: "input-row-with-text-light", record: .missing)
    }

    // MARK: DiffView — sample diff in both color schemes

    @Test func diffViewSampleLight() {
        let ops = Diff.diff(
            "i has went to the store yesterday",
            "I have gone to the store yesterday."
        )
        let v = host(DiffView(ops: ops, dark: false), height: 220, dark: false)
        assertSnapshot(of: v, as: .image, named: "diff-view-sample-light", record: .missing)
    }

    @Test func diffViewSampleDark() {
        let ops = Diff.diff(
            "i has went to the store yesterday",
            "I have gone to the store yesterday."
        )
        let v = host(DiffView(ops: ops, dark: true), height: 220, dark: true)
        assertSnapshot(of: v, as: .image, named: "diff-view-sample-dark", record: .missing)
    }

    // MARK: ResultActions — footer with stats + buttons

    @Test func resultActionsLight() {
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: false,
            store: snapshotStore(),
            dark: false,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: false)
        assertSnapshot(of: v, as: .image, named: "result-actions-light", record: .missing)
    }

    @Test func resultActionsDark() {
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: false,
            store: snapshotStore(),
            dark: true,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: true)
        assertSnapshot(of: v, as: .image, named: "result-actions-dark", record: .missing)
    }

    @Test func resultActionsAfterCopy() {
        // The "Copied" pulse state — verifies the post-click visual.
        let view = ResultActions(
            stats: (added: 3, removed: 1),
            latencyMs: 421,
            copied: true,
            store: snapshotStore(),
            dark: false,
            onCopy: {},
            onReject: {},
            onAccept: {}
        )
        let v = host(view, height: 50, dark: false)
        assertSnapshot(of: v, as: .image, named: "result-actions-copied", record: .missing)
    }

    // MARK: SettingsPanel — advanced mode off vs on

    @Test func settingsPanelAdvancedModeOff() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        store.advancedMode = false
        let view = SettingsPanelHarness(store: store, dark: false)
        let v = host(view, height: 300, dark: false)
        assertSnapshot(of: v, as: .image, named: "settings-panel-advanced-off", record: .missing)
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
        assertSnapshot(of: v, as: .image, named: "settings-panel-advanced-on", record: .missing)
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
        assertSnapshot(of: v, as: .image, named: "history-empty", record: .missing)
    }

    @Test func historyViewPopulated() {
        // Three sample entries — cap is 10, so this exercises the typical
        // mid-state. Use stable UUIDs and dates so the snapshot is reproducible
        // (otherwise re-rendering produces a fresh UUID each run).
        let entries = [
            PromptEntry(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                original: "fix this typo",
                polished: "Fix this typo.",
                backendLabel: "on-device",
                date: Date(timeIntervalSince1970: 770_000_000)
            ),
            PromptEntry(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                original: "make this more concise",
                polished: "Make this more concise.",
                backendLabel: "on-device",
                date: Date(timeIntervalSince1970: 769_000_000)
            ),
            PromptEntry(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                original: "polish the greeting",
                polished: "Polish the greeting.",
                backendLabel: "Claude · Haiku 4.5",
                date: Date(timeIntervalSince1970: 768_000_000)
            ),
        ]
        let view = HistoryView(
            entries: entries,
            dark: false,
            onPick: { _ in },
            onClear: {},
            onClose: {}
        )
        let v = host(view, height: 240, dark: false)
        assertSnapshot(of: v, as: .image, named: "history-populated", record: .missing)
    }

    // MARK: ThinkingBar — in-progress state

    @Test func thinkingBarLight() {
        let v = host(ThinkingBar(dark: false, descriptor: .onDevice), height: 60, dark: false)
        assertSnapshot(of: v, as: .image, named: "thinking-bar-light", record: .missing)
    }

    // MARK: BackendBadge — cloud trigger
    //
    // Every other snapshot uses `snapshotStore()` (no keys → on-device)
    // which only exercises the static-label path. These two tests
    // pre-seed a Claude key in the test-scoped Keychain so the badge
    // renders its Menu trigger — cloud glyph, "Claude · Haiku 4.5" /
    // "Cloud · Haiku 4.5" label, trailing chevron. Locks in the
    // dropdown's *resting* state (the menu popup itself can't be
    // captured — `Menu` only renders the trigger until clicked).

    @Test func backendBadgeCloudCompact() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let service = "linter.tests.snapshot.\(UUID().uuidString)"
        let store = PromptStore(
            defaults: scratch.defaults,
            keychainService: service,
            claudeAccount: "snap-claude",
            openaiAccount: "snap-openai"
        )
        defer { try? store.clearClaudeKey() }
        try store.setClaudeKey("test-key")
        let view = BackendBadge(store: store, style: .compact, dark: false)
        let v = host(view, height: 30, dark: false)
        assertSnapshot(of: v, as: .image, named: "backend-badge-cloud-compact-light", record: .missing)
    }

    @Test func backendBadgeCloudPrivacyFramed() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let service = "linter.tests.snapshot.\(UUID().uuidString)"
        let store = PromptStore(
            defaults: scratch.defaults,
            keychainService: service,
            claudeAccount: "snap-claude",
            openaiAccount: "snap-openai"
        )
        defer { try? store.clearClaudeKey() }
        try store.setClaudeKey("test-key")
        let view = BackendBadge(store: store, style: .privacyFramed, dark: false)
        let v = host(view, height: 30, dark: false)
        assertSnapshot(of: v, as: .image, named: "backend-badge-cloud-privacy-light", record: .missing)
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
    @State private var draft: TemplateDraft? = nil

    var body: some View {
        SettingsPanel(
            store: store,
            autoHide: $autoHide,
            draft: $draft,
            dark: dark,
            attemptDiscardingDraft: { action in action() }
        )
        .frame(width: 660)
    }
}
