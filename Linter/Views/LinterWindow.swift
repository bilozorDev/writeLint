import SwiftUI
import AppKit

struct LinterWindow: View {
    @Bindable var store: TemplateStore
    @Binding var hotkey: Hotkey

    @AppStorage("diffStyle.v1") private var diffStyleRaw: String = DiffStyle.stacked.rawValue
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

    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    private var diffStyle: Binding<DiffStyle> {
        Binding(
            get: { DiffStyle(rawValue: diffStyleRaw) ?? .stacked },
            set: { diffStyleRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            TemplateTabs(
                templates: store.templates,
                selectedID: store.selectedID,
                dark: dark,
                onSelect: { id in
                    store.selectedID = id
                    result = nil
                    cancelLint()
                }
            )

            ZStack(alignment: .top) {
                InputRow(
                    template: store.selected,
                    text: $text,
                    dark: dark,
                    thinking: thinking,
                    hasResult: result != nil,
                    settingsOpen: settingsOpen,
                    isFocused: $inputFocused,
                    onSubmit: submit,
                    onToggleSettings: { settingsOpen.toggle() }
                )

                // Slash command popover
                if let q = slashQuery {
                    SlashMenu(
                        templates: store.templates,
                        query: q,
                        dark: dark,
                        onPick: { tpl in
                            store.selectedID = tpl.id
                            text = ""
                            inputFocused = true
                        }
                    )
                    .padding(.top, 52)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
                    .zIndex(2)
                }
            }

            if case .unavailable(let reason, let installing) = availability {
                InlineErrorBar(message: reason, isInstalling: installing, dark: dark)
            }

            if historyOpen {
                HistoryView(
                    entries: history.entries,
                    templates: store.templates,
                    dark: dark,
                    onPick: { entry in
                        text = entry.text
                        if store.templates.contains(where: { $0.id == entry.templateID }) {
                            store.selectedID = entry.templateID
                        }
                        historyOpen = false
                        result = nil
                    },
                    onClear: { history.clear() },
                    onClose: { historyOpen = false }
                )
            } else if settingsOpen {
                Divider().background(Palette.divider(dark))
                ScrollView {
                    SettingsPanel(
                        store: store,
                        hotkey: $hotkey,
                        diffStyle: diffStyle,
                        autoHide: $autoHide,
                        dark: dark
                    )
                }
                .frame(maxHeight: 540)
                .background(Palette.footerBg(dark))
            }

            // Result + footer chain — gated on !historyOpen so the history
            // popover doesn't render alongside them in the same panel.
            if !historyOpen {
                if thinking {
                    ThinkingBar(dark: dark)
                } else if let r = result {
                    Divider().background(Palette.divider(dark))
                    ScrollView {
                        DiffView(ops: r.ops, style: diffStyle.wrappedValue, dark: dark)
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
                } else if !settingsOpen {
                    FooterHint(dark: dark, hotkey: hotkey)
                }
            }
        }
        .frame(width: 660)
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
            PanelController.shared.onHide = {
                text = ""
                result = nil
                settingsOpen = false
                historyOpen = false
                cancelLint()
            }
        }
        .background(
            CommandKeyMonitor(
                onSubmit: { submit() },
                onHistory: {
                    settingsOpen = false
                    historyOpen.toggle()
                },
                onNumber: { idx in
                    store.selectByIndex(idx)
                    result = nil
                },
                onEscape: {
                    if historyOpen { historyOpen = false }
                    else if settingsOpen { settingsOpen = false }
                    else if result != nil { result = nil }
                    else { PanelController.shared.hide() }
                }
            )
        )
    }

    private var slashQuery: String? {
        let trimmed = text
        guard trimmed.first == "/" else { return nil }
        // only show when no spaces have been typed yet
        let rest = String(trimmed.dropFirst())
        if rest.contains(where: { $0.isWhitespace }) { return nil }
        return rest
    }

    private func submit() {
        // If a result is on screen, ⌘⏎ accepts it (matches the Accept button).
        // Otherwise, kick off a new lint.
        if result != nil {
            handleAccept()
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard case .available = availability else { return }
        cancelLint()
        history.record(text: text, templateID: store.selectedID)
        let template = store.selected
        let toLint = text
        thinking = true
        result = nil
        copied = false
        lintTask = Task {
            do {
                let r = try await FoundationModelService.shared.lint(text: toLint, template: template)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.result = r
                    self.thinking = false
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
            text = r.output
            result = nil
            toast = "Copied to clipboard"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
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
                Text("Lint")
            }
            HStack(spacing: 5) {
                KbdLabel(text: "⌘", dark: dark)
                KbdLabel(text: "1–9", dark: dark)
                Text("Templates")
            }
            HStack(spacing: 5) {
                KbdLabel(text: "/", dark: dark)
                Text("Search")
            }
            HStack(spacing: 5) {
                KbdLabel(text: "⌘", dark: dark)
                KbdLabel(text: "H", dark: dark)
                Text("History")
            }
            Spacer()
            HStack(spacing: 5) {
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

/// Catches ⌘+Return (submit), ⌘1..9 (template switch), and Esc at the window
/// level — runs BEFORE the focused TextField sees the keyDown, so plain ⏎
/// still falls through to the field for newline insertion.
private struct CommandKeyMonitor: NSViewRepresentable {
    var onSubmit: () -> Void
    var onHistory: () -> Void
    var onNumber: (Int) -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onSubmit = onSubmit
        v.onHistory = onHistory
        v.onNumber = onNumber
        v.onEscape = onEscape
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let v = v as? MonitorView else { return }
        v.onSubmit = onSubmit
        v.onHistory = onHistory
        v.onNumber = onNumber
        v.onEscape = onEscape
    }
    final class MonitorView: NSView {
        var onSubmit: (() -> Void)?
        var onHistory: (() -> Void)?
        var onNumber: ((Int) -> Void)?
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
                    if event.modifierFlags.contains(.command),
                       let chars = event.charactersIgnoringModifiers,
                       chars.count == 1,
                       let n = Int(chars), n >= 1, n <= 9 {
                        self.onNumber?(n - 1); return nil
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
