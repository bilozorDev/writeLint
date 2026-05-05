import SwiftUI
import AppKit

struct LinterWindow: View {
    @Bindable var store: PromptStore

    @AppStorage("autoHide.v1")  private var autoHide: Bool = true

    @State private var text: String = ""
    @State private var settingsOpen = false
    @State private var historyOpen = false
    /// Non-nil when the user clicked a history entry to view its diff.
    /// Drives a swap from the list view to `HistoryDetailView` while
    /// `historyOpen` stays true (the back button just nils this out and
    /// returns to the list).
    @State private var viewingHistoryEntry: PromptEntry?
    @State private var thinking = false
    @State private var result: LintResult?
    @State private var copied = false
    @State private var availability: ModelAvailability = .available
    @State private var lintTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var history = PromptHistory.shared
    /// True once the user has submitted a lint in the current session. Drives
    /// the "preserve typed text on dismiss" rule in `onHide` — preservation
    /// only kicks in for sessions that never submitted, so accepted-and-
    /// auto-hidden flows clear (handleAccept nils `result` before hide(),
    /// which would otherwise look like an unsubmitted session).
    @State private var submittedThisSession = false

    /// X-offset of the page group. Animated via `withAnimation` in the
    /// open/close helpers below — kept separate from `settingsOpen` so the
    /// container's height (which derives from settingsOpen) snaps instantly
    /// while only the slide animates. Otherwise the simultaneous height grow
    /// + horizontal slide reads as a diagonal sweep.
    @State private var slideOffset: CGFloat = 0

    /// Hard cap on the scrollable area inside settings — passed to the
    /// settings page so its ScrollView clamps internally.
    private let settingsScrollMax: CGFloat = 540

    /// Width of each page in the slide layout. Single source of truth for
    /// `PageSlideLayout(pageWidth:)` and the settings-open `slideOffset`,
    /// which must stay in lock-step or the inactive page peeks through.
    private let pageWidth: CGFloat = 660

    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        // Both pages are always present in the tree. A custom `PageSlideLayout`
        // proposes unbounded vertical space to both pages (so each computes
        // its true intrinsic height — important for the multi-line TextField
        // on main and the ScrollView/SettingsPanel on settings) and uses the
        // ACTIVE page's intrinsic height as the layout's own size. The
        // inactive page is placed off-screen at x=±pageWidth. Only the
        // layout's .offset is animated — height changes snap so the slide
        // reads as purely horizontal.
        PageSlideLayout(settingsActive: settingsOpen, pageWidth: pageWidth) {
            mainPage
            settingsPage
        }
        .offset(x: slideOffset)
        .clipped()
        .background(
            // Brighter than .regularMaterial: thick material gives a more
            // opaque base, plus a translucent white/black tint on top so it
            // doesn't go bleak against very dark backdrops.
            RoundedRectangle(cornerRadius: 18)
                .fill(.thickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(dark ? .white.opacity(0.14) : .black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .top) {
            if let toast {
                ToastView(text: toast, dark: dark)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
        // Two-layer shadow: tight ambient + soft drop. Lower opacity than the
        // design (which assumed dark wallpapers) so it doesn't read as a heavy
        // gray band when the panel sits over a light surface.
        .shadow(color: .black.opacity(0.12), radius: 4,  y: 2)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .padding(8)
        .padding(28)
        .accessibilityIdentifier("Linter.PanelRoot")
        .onAppear {
            availability = FoundationModelService.shared.availability
            inputFocused = true
            PanelController.shared.requestFocus = {
                inputFocused = true
                // Spotlight-style: when re-summoned with preserved text,
                // select all so overtyping replaces the previous content.
                // Two async hops give SwiftUI's focus pipeline time to
                // install the field editor as first responder before we
                // reach in via the AppKit responder chain. Scope the
                // responder lookup to OUR panel so we don't accidentally
                // selectAll in some other window that briefly grabbed key
                // status during activation.
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        guard let panel = NSApp.keyWindow as? FloatingPanel,
                              let editor = panel.firstResponder as? NSTextView
                        else { return }
                        editor.selectAll(nil)
                    }
                }
            }
            PanelController.shared.onShow = {
                // Re-read availability on every summon. Apple Intelligence
                // can flip from .unavailable → .available between launch and
                // first summon (e.g. background download finishes), and
                // without this the InlineErrorBar would persist forever.
                availability = FoundationModelService.shared.availability
            }
            PanelController.shared.onHide = {
                // Preserve typed text across hide/show (Spotlight-style) when
                // nothing was submitted in this session. Once the user has
                // submitted, the session is "done" and dismissing clears —
                // covers the auto-hide-after-accept path too, where
                // handleAccept nils `result` before hide() and would
                // otherwise look like an unsubmitted session.
                if submittedThisSession { text = "" }
                submittedThisSession = false
                result = nil
                settingsOpen = false
                slideOffset = 0
                historyOpen = false
                viewingHistoryEntry = nil
                cancelLint()
            }
        }
        .background(
            CommandKeyMonitor(
                inputFocused: inputFocused,
                onSubmit: { submit() },
                onHistory: {
                    setSettingsOpen(false)
                    // Always reset the detail view when toggling history
                    // — re-opening should land on the list, not stay
                    // pinned to the previously-viewed entry.
                    viewingHistoryEntry = nil
                    historyOpen.toggle()
                },
                onEscape: {
                    // Cascade Esc: detail-view → history list → close
                    // history → close settings → dismiss result → hide
                    // panel. Each level peels off the most recently
                    // surfaced overlay.
                    if viewingHistoryEntry != nil { viewingHistoryEntry = nil }
                    else if historyOpen { historyOpen = false }
                    else if settingsOpen { setSettingsOpen(false) }
                    else if result != nil { result = nil }
                    else { PanelController.shared.hide() }
                }
            )
        )
    }

    @ViewBuilder
    private var mainPage: some View {
        VStack(spacing: 0) {
            InputRow(
                text: $text,
                dark: dark,
                settingsOpen: settingsOpen,
                isFocused: $inputFocused,
                onSubmit: submit,
                onToggleSettings: { setSettingsOpen(!settingsOpen) }
            )

            // Only surface the on-device-unavailable bar when the on-device
            // backend is actually the active one. With Claude selected, the
            // user has a working backend and Apple Intelligence's state is
            // irrelevant for the in-panel UX.
            if store.activeBackend == .onDevice,
               case .unavailable(let reason, let installing) = availability {
                InlineErrorBar(message: reason, isInstalling: installing, dark: dark)
            }

            if historyOpen {
                if let entry = viewingHistoryEntry {
                    HistoryDetailView(
                        entry: entry,
                        dark: dark,
                        onBack: { viewingHistoryEntry = nil },
                        onUseAgain: {
                            text = entry.original
                            viewingHistoryEntry = nil
                            historyOpen = false
                            result = nil
                            inputFocused = true
                        }
                    )
                } else {
                    HistoryView(
                        entries: history.entries,
                        dark: dark,
                        onPick: { entry in
                            // Click on a row now opens the read-only diff
                            // for that entry; the "Use again" button inside
                            // the detail view handles the load-into-input
                            // path that this callback used to perform.
                            viewingHistoryEntry = entry
                        },
                        onClear: { history.clear() },
                        onClose: {
                            historyOpen = false
                            viewingHistoryEntry = nil
                        }
                    )
                }
            } else if thinking {
                ThinkingBar(dark: dark)
            } else if let r = result {
                if r.stats.added == 0 && r.stats.removed == 0 {
                    if let issue = r.issue {
                        // Fallback fired (hallucination, generation error,
                        // malformed output) — output==input is a *failure*,
                        // not a clean run. Show a warning bar with the reason
                        // instead of the green "already clean" check.
                        IssueBar(
                            issue: issue,
                            latencyMs: r.latencyMs,
                            store: store,
                            dark: dark,
                            onDismiss: { result = nil }
                        )
                    } else {
                        CleanBar(
                            latencyMs: r.latencyMs,
                            copied: copied,
                            store: store,
                            dark: dark,
                            onCopy: handleCopy
                        )
                    }
                } else {
                    Divider().background(Palette.divider(dark))
                    if r.issue != nil {
                        // Partial fallback: at least one chunk fell back to
                        // its original text but other chunks produced real
                        // edits, so the diff below mixes polished and
                        // un-polished sections. Surface a slim notice so the
                        // user knows the polish was incomplete — without it,
                        // the green stats reads as full success.
                        PartialIssueNotice(dark: dark)
                    }
                    ScrollView {
                        DiffView(ops: r.ops, dark: dark)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 360)
                    .background(Palette.footerBg(dark))
                    ResultActions(
                        stats: r.stats,
                        latencyMs: r.latencyMs,
                        copied: copied,
                        store: store,
                        dark: dark,
                        onCopy: handleCopy,
                        onReject: { result = nil },
                        onAccept: handleAccept
                    )
                }
            } else {
                FooterHint(
                    dark: dark,
                    hotkey: HotkeyStore.shared.current,
                    store: store
                )
            }
        }
    }

    /// Compact backend identifier persisted into history when a lint is
    /// accepted. Used only by `handleAccept` now — the per-result bars
    /// and footer render their own labels via `BackendBadge` driven
    /// directly off the store. Reading "what model did this run on" from
    /// history later requires this string to be human-readable.
    private var backendLabel: String {
        switch store.activeBackend {
        case .onDevice:
            return "on-device"
        case .claude:
            return "Claude · \(store.selectedClaudeModel.footerLabel)"
        case .openai:
            return "OpenAI · \(store.selectedOpenAIModel.footerLabel)"
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        VStack(spacing: 0) {
            // Header — back button + title. The back button is the symmetric
            // counterpart to the gear in the input row: it returns the user
            // to the main page with a reverse slide.
            HStack(spacing: 8) {
                Button { setSettingsOpen(false) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Palette.surface(dark))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                Spacer()
                // Width-balance the Back button so the title sits centered.
                Color.clear.frame(width: 70, height: 1)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            }

            ScrollView {
                SettingsPanel(
                    store: store,
                    autoHide: $autoHide,
                    dark: dark
                )
            }
            .frame(maxHeight: settingsScrollMax)
            .background(Palette.footerBg(dark))
        }
    }

    /// Single entry point for opening / closing the settings page. Snaps the
    /// container's height (via settingsOpen) so the panel resizes instantly,
    /// then animates only the X-offset over 0.28s.
    private func setSettingsOpen(_ open: Bool) {
        settingsOpen = open
        withAnimation(.easeInOut(duration: 0.28)) {
            slideOffset = open ? -pageWidth : 0
        }
    }

    /// Hard cap on input length. Below this, the whole pipeline runs comfortably.
    /// Above it, `Diff.diff`'s LCS table allocates `O(n·m)` Ints and crosses into
    /// multi-GB territory (~3.2 GB at 100k chars), and a single chunk can also
    /// exceed the on-device model's 4096-token input window. Reject at the
    /// submit gate rather than silently truncating — running on a clipped
    /// version would surface mysterious incomplete results.
    private static let maxInputCharacters: Int = 10_000

    private func submit() {
        // If the on-screen result is a *failed* polish (issue set, no diff),
        // ⌘⏎ must NOT copy-and-close — the "output" is just the user's
        // original text, and silently shipping it to the clipboard while the
        // panel disappears feels like a successful polish. Treat ⌘⏎ as
        // "dismiss the warning" instead, so the user can edit and resubmit.
        if let r = result, r.issue != nil, r.stats.added == 0, r.stats.removed == 0 {
            result = nil
            return
        }
        // If a result is on screen, ⌘⏎ accepts it (matches the Accept button).
        // Otherwise, kick off a new lint.
        if result != nil {
            handleAccept()
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.count <= Self.maxInputCharacters else {
            showToast("Text is too long (max \(Self.maxInputCharacters.formatted()) characters).")
            return
        }
        // The on-device-availability gate only applies when on-device is
        // the active backend. If the user has opted into a cloud provider
        // in Advanced Mode, we proceed regardless of Apple Intelligence's
        // state — the cloud path doesn't depend on it.
        let backend: BackendChoice = {
            switch store.activeBackend {
            case .claude:
                if let key = store.currentClaudeKey() {
                    return .claude(apiKey: key, model: store.selectedClaudeModel)
                }
            case .openai:
                if let key = store.currentOpenAIKey() {
                    return .openai(apiKey: key, model: store.selectedOpenAIModel)
                }
            case .onDevice:
                break
            }
            return .onDevice
        }()
        if case .onDevice = backend {
            guard case .available = availability else { return }
        }
        cancelLint()
        // History capture moved to handleAccept — we only persist lints the
        // user actually accepted, with the polished output and backend
        // label alongside the original.
        submittedThisSession = true
        let instructions = store.instructions
        let toLint = text
        thinking = true
        result = nil
        copied = false
        lintTask = Task {
            do {
                let r = try await FoundationModelService.shared.lint(
                    text: toLint,
                    instructions: instructions,
                    backend: backend
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    self.thinking = false
                    self.result = r
                }
            } catch is CancellationError {
                return
            } catch LintError.cancelled {
                return
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.thinking = false
                    self.availability = FoundationModelService.shared.availability
                    // Surface the failure so the user knows the lint didn't
                    // silently disappear into the void.
                    let msg = (error as? LocalizedError)?.errorDescription ?? "Linting failed."
                    self.showToast(msg)
                }
            }
        }
    }

    private func showToast(_ text: String, duration: TimeInterval = 2.0) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            // Only clear if the toast hasn't been replaced in the meantime.
            if toast == text { toast = nil }
        }
    }

    private func cancelLint() {
        lintTask?.cancel()
        lintTask = nil
        thinking = false
    }

    private func handleAccept() {
        guard let r = result else { return }
        // Always copy to clipboard on accept — that's the whole point.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r.output, forType: .string)

        // Record this lint in history. Capturing on accept (not on submit)
        // gives us both sides of the diff and means history reflects only
        // the polishes the user actually used.
        history.recordAccepted(
            original: r.input,
            polished: r.output,
            backendLabel: backendLabel
        )

        if autoHide {
            // Replace the input text so the next summon shows the accepted
            // version, then dismiss after the toast briefly shows. One timer
            // does both — clears the toast and hides the panel — so there's
            // no order-of-execution ambiguity between two competing timers.
            // Capture sessionStamp so the deferred body no-ops if the user
            // re-summoned during the toast window — otherwise we'd wipe a
            // freshly-opened session's state.
            text = r.output
            result = nil
            // Resign focus immediately so the input field stops accepting
            // keystrokes during the ~850ms toast window before the panel
            // actually hides. Without this, a user who keeps typing after
            // ⌘⏎ would be editing text that's about to disappear — visibly
            // confusing, and any keystrokes are wasted work.
            inputFocused = false
            toast = "Copied to clipboard"
            let stamp = PanelController.shared.sessionStamp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                guard PanelController.shared.sessionStamp == stamp else { return }
                toast = nil
                PanelController.shared.hide()
            }
        } else {
            // Keep the result on screen so the user can keep iterating /
            // comparing. Just confirm the clipboard write.
            showToast("Copied to clipboard", duration: 1.4)
        }
    }

    private func handleCopy() {
        guard let r = result else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r.output, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Backend identifier rendered into the footer + per-result bars. When
/// only on-device is reachable, it's a static label. When at least one
/// cloud backend has a saved API key, it becomes a `Menu` so the user can
/// switch backends inline. **Switches the backend, not the model** —
/// model picking lives in Settings alongside the API key entry. Reaching
/// for "different backend" (on-device ↔ Claude ↔ OpenAI) is a foreground
/// decision; reaching for "different model within Claude" is a
/// configuration step.
///
/// Available options in the dropdown:
/// - On-device — always shown
/// - Claude · &lt;current model&gt; — only if `hasClaudeKey`
/// - OpenAI · &lt;current model&gt; — only if `hasOpenAIKey`
///
/// Two visual styles for the trigger:
/// - `.compact` — `"Claude · Haiku 4.5"` / `"on-device"`. Used in the
///   per-result bars where space is at a premium and the provider is
///   disambiguated by the cloud glyph.
/// - `.privacyFramed` — `"Cloud · Haiku 4.5"` / `"Private · on-device"`.
///   Used in `FooterHint` where the message frames the privacy posture
///   rather than the brand.
struct BackendBadge: View {
    enum Style { case compact, privacyFramed }
    @Bindable var store: PromptStore
    let style: Style
    let dark: Bool

    /// Backends the user can pick right now. On-device is always present;
    /// cloud options appear only when the matching key is in the
    /// Keychain. The dropdown disappears entirely (collapses to a static
    /// label) when only on-device is available, so the user isn't asked
    /// to "pick" from a list of one.
    private var availableBackends: [LintBackend] {
        var out: [LintBackend] = [.onDevice]
        if store.hasClaudeKey { out.append(.claude) }
        if store.hasOpenAIKey { out.append(.openai) }
        return out
    }

    private var glyph: String {
        switch (store.activeBackend, style) {
        case (.onDevice, .compact):       return "apple.logo"
        case (.onDevice, .privacyFramed): return "lock.fill"
        case (.claude, _), (.openai, _):  return "cloud"
        }
    }

    private var labelText: String {
        switch (store.activeBackend, style) {
        case (.onDevice, .compact):       return "on-device"
        case (.onDevice, .privacyFramed): return "Private · on-device"
        case (.claude, .compact):
            return "Claude · \(store.selectedClaudeModel.footerLabel)"
        case (.claude, .privacyFramed):
            return "Cloud · \(store.selectedClaudeModel.footerLabel)"
        case (.openai, .compact):
            return "OpenAI · \(store.selectedOpenAIModel.footerLabel)"
        case (.openai, .privacyFramed):
            return "Cloud · \(store.selectedOpenAIModel.footerLabel)"
        }
    }

    /// Label shown for each row inside the popped-open menu. Always the
    /// brand-prefixed form (`"Claude · Haiku 4.5"`) regardless of the
    /// trigger's style — inside the menu the user is choosing among
    /// backends, so brand framing is what they want to see.
    private func menuOptionLabel(for backend: LintBackend) -> String {
        switch backend {
        case .onDevice: return "On-device"
        case .claude:   return "Claude · \(store.selectedClaudeModel.footerLabel)"
        case .openai:   return "OpenAI · \(store.selectedOpenAIModel.footerLabel)"
        }
    }

    var body: some View {
        if availableBackends.count > 1 {
            backendMenu
        } else {
            staticLabel
        }
    }

    private var staticLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: glyph).font(.system(size: 10))
            Text(labelText).font(.system(size: 11))
        }
        .foregroundStyle(Palette.sub(dark))
    }

    private var backendMenu: some View {
        Menu {
            // Plain `Button`s instead of a `Picker` — wrapping a Picker
            // (even with `.pickerStyle(.inline)` and an empty title)
            // makes macOS reserve a header row for the title slot, which
            // shows up as an awkward blank gap above the first option.
            // Buttons render flush with the menu's top edge and let us
            // control the checkmark explicitly.
            ForEach(availableBackends) { backend in
                Button {
                    store.selectedBackend = backend
                } label: {
                    if store.selectedBackend == backend {
                        Label(menuOptionLabel(for: backend), systemImage: "checkmark")
                    } else {
                        Text(menuOptionLabel(for: backend))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: glyph).font(.system(size: 10))
                Text(labelText).font(.system(size: 11))
                // Caret signals "click to open". `chevron.down` at 9pt
                // semibold is the smallest size that reads as a clear
                // dropdown indicator at the surrounding text size — any
                // smaller and it disappears; any bigger and it competes
                // with the model name.
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        // `.button` (default) menu style without the system indicator
        // gives us a plain clickable trigger. Avoiding `.borderlessButton`
        // here — that style aggressively styles the label and was
        // suppressing the trailing chevron in the rendered output.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // `.foregroundStyle` *inside* the label loses to the menu's
        // tint chrome — the label can render in the system accent
        // color (blue) instead of the surrounding gray. Lifting both
        // `.foregroundStyle` AND `.tint` to the Menu level wins; their
        // precedence on macOS Menu is version-sensitive, so set both.
        .foregroundStyle(Palette.sub(dark))
        .tint(Palette.sub(dark))
    }
}

/// Compact "no changes needed" bar shown in place of the diff view when the
/// model returns the input unchanged. Stays visible until the user dismisses
/// (Esc / click-away) — no Accept/Reject because there's nothing to commit.
/// Includes a Copy button so the user can still grab the (already-clean) text.
private struct CleanBar: View {
    let latencyMs: Int
    let copied: Bool
    @Bindable var store: PromptStore
    let dark: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.added.opacity(dark ? 0.22 : 0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.added)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Text is already clean")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                Text("Nothing to change.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.sub(dark))
            }
            Spacer()
            HStack(spacing: 10) {
                Text("\(latencyMs)ms")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub(dark))
                BackendBadge(store: store, style: .compact, dark: dark)
            }
            Button(action: onCopy) {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(copied ? Palette.added : Palette.text(dark))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Palette.surface(dark))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }
}

/// Warning bar shown when a polish failed and we returned the user's text
/// untouched. Mirrors `CleanBar`'s structural footprint so the panel resizes
/// the same way, but uses a warning palette and shows the reason. Esc clears
/// the bar (same as `CleanBar`); there's no Copy because the displayed text
/// is identical to what's in the input field above.
private struct IssueBar: View {
    let issue: LintIssue
    let latencyMs: Int
    @Bindable var store: PromptStore
    let dark: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.removed.opacity(dark ? 0.22 : 0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.removed)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(issue.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                Text(issue.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.sub(dark))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text("\(latencyMs)ms")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub(dark))
                BackendBadge(store: store, style: .compact, dark: dark)
            }
            Button(action: onDismiss) {
                Text("Dismiss")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Palette.surface(dark))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }
}

/// Slim warning shown above the diff when some chunks fell back but others
/// produced real edits. Mirrors the `IssueBar` palette but at single-line
/// height so it sits unobtrusively atop the diff scroll view. No actions —
/// the user dismisses by accepting/rejecting the diff itself.
private struct PartialIssueNotice: View {
    let dark: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.removed)
            Text("Some sections couldn't be polished and were kept as-is.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.sub(dark))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Palette.removed.opacity(dark ? 0.10 : 0.06))
    }
}

private struct ToastView: View {
    let text: String
    let dark: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.added)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text(dark))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.thickMaterial)
                .overlay(
                    Capsule().fill(dark ? Color.white.opacity(0.04) : Color.white.opacity(0.5))
                )
        )
        .overlay(Capsule().stroke(Palette.divider(dark), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct FooterHint: View {
    let dark: Bool
    let hotkey: Hotkey
    @Bindable var store: PromptStore
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                KbdLabel(text: "⌘", dark: dark)
                KbdLabel(text: "↩", dark: dark)
                Text("Polish")
            }
            HStack(spacing: 5) {
                KbdLabel(text: "⌘", dark: dark)
                KbdLabel(text: "H", dark: dark)
                Text("History")
            }
            Spacer()
            HStack(spacing: 5) {
                Text("AI makes mistakes, always check results")
                Text("·")
                // BackendBadge renders the lock/cloud glyph + privacy
                // framing ("Private · on-device" / "Cloud · Haiku 4.5"),
                // and on cloud backends becomes a clickable model picker
                // so the user can switch models without leaving the
                // panel.
                BackendBadge(store: store, style: .privacyFramed, dark: dark)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.sub(dark))
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider(dark)).frame(height: 1) }
    }
}

/// Catches ⌘+Return (submit), ⌘+H (history), Esc, and the main input's
/// plain-⏎ → newline at the window level. The plain-⏎ intercept fires only
/// when the main input is focused — settings fields (TextEditor) keep their
/// native behavior because the monitor returns the event unchanged when
/// `inputFocused` is false.
private struct CommandKeyMonitor: NSViewRepresentable {
    var inputFocused: Bool
    var onSubmit: () -> Void
    var onHistory: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.inputFocused = inputFocused
        v.onSubmit = onSubmit
        v.onHistory = onHistory
        v.onEscape = onEscape
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let v = v as? MonitorView else { return }
        v.inputFocused = inputFocused
        v.onSubmit = onSubmit
        v.onHistory = onHistory
        v.onEscape = onEscape
    }
    final class MonitorView: NSView {
        var inputFocused: Bool = false
        var onSubmit: (() -> Void)?
        var onHistory: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    // While the user is recording a new global shortcut, pass
                    // every key event through so the recorder can capture
                    // chords like ⌘+Return that we'd otherwise consume.
                    if HotkeyRecordingState.shared.isRecording {
                        return event
                    }
                    // ⌘+Return / ⌘+NumPad-Enter → submit
                    if (event.keyCode == 36 || event.keyCode == 76),
                       event.modifierFlags.contains(.command) {
                        self.onSubmit?()
                        return nil
                    }
                    // Plain ⏎ in the main input → insert newline at the cursor.
                    // SwiftUI TextField(axis: .vertical) on macOS treats plain
                    // Enter as "submit", which manifests as a select-all of the
                    // current value instead of a newline. We force the
                    // newline via the field editor so cursor position is
                    // preserved. Gated on `inputFocused` so the settings
                    // panel's TextEditor / TextField keep native behavior, and
                    // on `event.window === self.window` so we never inject
                    // newlines into another window's field editor if the app
                    // ever gains a second window (sheet, secondary panel).
                    if (event.keyCode == 36 || event.keyCode == 76),
                       self.inputFocused,
                       event.modifierFlags
                        .intersection([.command, .shift, .option, .control])
                        .isEmpty,
                       let win = event.window, win === self.window,
                       let editor = win.firstResponder as? NSTextView {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return nil
                    }
                    if event.keyCode == 53 /* esc */ {
                        self.onEscape?(); return nil
                    }
                    // ⌘+H → toggle history. Match by character (layout-aware)
                    // rather than keyCode 4 — keyCode 4 isn't "H" on Dvorak/
                    // Colemak/QWERTZ layouts.
                    if event.modifierFlags.contains(.command),
                       !event.modifierFlags.contains(.shift),
                       !event.modifierFlags.contains(.option),
                       !event.modifierFlags.contains(.control),
                       event.charactersIgnoringModifiers?.lowercased() == "h" {
                        self.onHistory?(); return nil
                    }
                    return event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m); monitor = nil
            }
        }
        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

/// Two-page side-by-side layout for the slide transition.
///
/// Both pages are always laid out (no conditional rendering, no rebuild
/// during animation). Each gets an unbounded vertical proposal so the
/// TextField axis-vertical and the SettingsPanel ScrollView can compute
/// their true intrinsic heights. The layout's own size is taken from the
/// active page only, so the panel resizes to whichever page is current.
private struct PageSlideLayout: Layout {
    var settingsActive: Bool
    var pageWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let unbounded = ProposedViewSize(width: pageWidth, height: nil)
        let activeIdx = settingsActive ? 1 : 0
        guard subviews.indices.contains(activeIdx) else {
            return CGSize(width: pageWidth, height: 0)
        }
        let size = subviews[activeIdx].sizeThatFits(unbounded)
        return CGSize(width: pageWidth, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unbounded = ProposedViewSize(width: pageWidth, height: nil)
        for (idx, sv) in subviews.enumerated() {
            let xOffset: CGFloat = (idx == 0) ? 0 : pageWidth
            sv.place(
                at: CGPoint(x: bounds.minX + xOffset, y: bounds.minY),
                proposal: unbounded
            )
        }
    }
}
