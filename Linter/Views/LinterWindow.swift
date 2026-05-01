import SwiftUI
import AppKit

struct LinterWindow: View {
    @Bindable var store: PromptStore

    @AppStorage("autoHide.v1")  private var autoHide: Bool = true

    @State private var text: String = ""
    @State private var settingsOpen = false
    @State private var historyOpen = false
    @State private var thinking = false
    @State private var result: LintResult?
    @State private var copied = false
    @State private var availability: ModelAvailability = .available
    @State private var lintTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var history = PromptHistory.shared

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
        .onAppear {
            availability = FoundationModelService.shared.availability
            inputFocused = true
            PanelController.shared.requestFocus = { inputFocused = true }
            PanelController.shared.onShow = {
                // Re-read availability on every summon. Apple Intelligence
                // can flip from .unavailable → .available between launch and
                // first summon (e.g. background download finishes), and
                // without this the InlineErrorBar would persist forever.
                availability = FoundationModelService.shared.availability
            }
            PanelController.shared.onHide = {
                text = ""
                result = nil
                settingsOpen = false
                slideOffset = 0
                historyOpen = false
                cancelLint()
            }
        }
        .background(
            CommandKeyMonitor(
                inputFocused: inputFocused,
                onSubmit: { submit() },
                onHistory: {
                    setSettingsOpen(false)
                    historyOpen.toggle()
                },
                onEscape: {
                    if historyOpen { historyOpen = false }
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

            if case .unavailable(let reason, let installing) = availability {
                InlineErrorBar(message: reason, isInstalling: installing, dark: dark)
            }

            if historyOpen {
                HistoryView(
                    entries: history.entries,
                    dark: dark,
                    onPick: { entry in
                        text = entry.text
                        historyOpen = false
                        result = nil
                    },
                    onClear: { history.clear() },
                    onClose: { historyOpen = false }
                )
            } else if thinking {
                ThinkingBar(dark: dark)
            } else if let r = result {
                if r.stats.added == 0 && r.stats.removed == 0 {
                    CleanBar(
                        latencyMs: r.latencyMs,
                        copied: copied,
                        dark: dark,
                        onCopy: handleCopy
                    )
                } else {
                    Divider().background(Palette.divider(dark))
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
                        dark: dark,
                        onCopy: handleCopy,
                        onReject: { result = nil },
                        onAccept: handleAccept
                    )
                }
            } else {
                FooterHint(dark: dark, hotkey: HotkeyStore.shared.current)
            }
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
        guard case .available = availability else { return }
        cancelLint()
        history.record(text: text)
        let instructions = store.instructions
        let toLint = text
        thinking = true
        result = nil
        copied = false
        lintTask = Task {
            do {
                let r = try await FoundationModelService.shared.lint(text: toLint, instructions: instructions)
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

/// Compact "no changes needed" bar shown in place of the diff view when the
/// model returns the input unchanged. Stays visible until the user dismisses
/// (Esc / click-away) — no Accept/Reject because there's nothing to commit.
/// Includes a Copy button so the user can still grab the (already-clean) text.
private struct CleanBar: View {
    let latencyMs: Int
    let copied: Bool
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
                HStack(spacing: 3) {
                    Image(systemName: "apple.logo").font(.system(size: 10))
                    Text("on-device").font(.system(size: 11))
                }
                .foregroundStyle(Palette.sub(dark))
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
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Private · on-device")
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
