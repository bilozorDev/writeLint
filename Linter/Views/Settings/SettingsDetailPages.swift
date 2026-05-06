import SwiftUI

// MARK: - Shortcuts & behavior page

/// Right-pane content for the "Shortcuts & behavior" sidebar entry.
/// Houses the global summon hotkey recorder and the auto-hide-after-copy
/// toggle. (A diff-style picker existed in the design but was dropped
/// because `DiffView` only renders the stacked layout — exposing a choice
/// that does nothing would be misleading. Reintroduce when there's an
/// actual second style to pick.)
struct ShortcutsBehaviorPage: View {
    @Binding var autoHide: Bool
    let dark: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow(
                        icon: "keyboard",
                        title: "Summon Linter",
                        subtitle: "Opens the floating window anywhere on macOS, focused and ready."
                    ) {
                        ShortcutRecorderView(dark: dark)
                    }
                    Rectangle().fill(Palette.divider(dark)).frame(height: 1)

                    settingRow(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Auto-hide after copy",
                        subtitle: "Copy the corrected text and dismiss the panel when you accept."
                    ) {
                        Toggle("", isOn: $autoHide)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcuts & behavior")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
            Text("System-wide shortcut and how Linter behaves after a polish.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.sub(dark))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 22))
    }

    @ViewBuilder
    private func settingRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.surface(dark))
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.sub(dark))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.sub(dark))
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

// MARK: - AI Provider page

/// Right-pane content for the "AI provider" sidebar entry. Three cards
/// (Apple, Claude, OpenAI), an API-key form for the editing provider, a
/// model picker once a key is saved, and an info card when Apple is active.
///
/// Click semantics distinguish *configuring* a provider from *activating*
/// it (matches the design's expectation that clicking a not-yet-keyed
/// provider doesn't break the active backend):
///   - **Apple** card click → `selectedBackend = .onDevice` immediately.
///   - **Claude / OpenAI** card click → if a key is saved, flip
///     `selectedBackend` to that provider; otherwise just highlight the card
///     (sets local `editingProvider`) and show the key form.
///
/// `editingProvider` defaults to whichever provider has a key saved (so a
/// returning user lands on their configured provider's form), or `nil` when
/// Apple is active and neither cloud has a key.
struct AIProviderPage: View {
    @Bindable var store: PromptStore
    let dark: Bool

    /// Which cloud provider's config form is currently rendered. Nil when
    /// Apple is active and no key is on file. Local UI state — never
    /// persisted; resets every time the page re-mounts.
    @State private var editingProvider: CloudProvider?

    /// Local draft for an unsaved API key. Cleared on Save / Remove and on
    /// `editingProvider` changes so a half-typed Claude key doesn't bleed
    /// over to the OpenAI tab.
    @State private var keyDraft: String = ""

    /// Show the key in plain text (vs. dots) — toggled via the eye button.
    @State private var revealKey = false

    /// Surface for SecItem errors during save / remove.
    @State private var keyError: String?

    /// Confirmation gate before destructively wiping a saved key.
    @State private var confirmingRemove = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    providerCards
                    if let editing = editingProvider {
                        providerKeyForm(editing)
                    } else {
                        appleInfoCard
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 22, bottom: 24, trailing: 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { resetEditingProvider() }
        .onChange(of: store.selectedBackend) { _, _ in resetEditingProvider() }
        .onChange(of: editingProvider) { _, _ in
            keyDraft = ""
            revealKey = false
            keyError = nil
        }
        .alert("Remove \(editingProvider?.displayName ?? "API") key?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                guard let editing = editingProvider else { return }
                do {
                    switch editing {
                    case .claude: try store.clearClaudeKey()
                    case .openai: try store.clearOpenAIKey()
                    }
                    keyDraft = ""
                    revealKey = false
                    keyError = nil
                } catch {
                    keyError = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't remove the API key from Keychain."
                }
            }
        } message: {
            Text("The key will be deleted from your Mac's Keychain and lints will fall back to the on-device model. You'll need to paste the key again to re-enable this backend.")
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI provider")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
            Text("By default Linter runs entirely on your Mac via Apple Intelligence. Bring your own API key to route through Claude or OpenAI.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.sub(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 22))
    }

    // MARK: Provider cards

    @ViewBuilder
    private var providerCards: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            providerCard(.apple)
            providerCard(.claude)
            providerCard(.openai)
        }
    }

    /// Lightweight enum local to the cards row — covers Apple plus the two
    /// cloud `CloudProvider` values without changing the persisted enum.
    private enum CardKind {
        case apple, claude, openai

        var name: String {
            switch self {
            case .apple: return "Apple Intelligence"
            case .claude: return "Claude"
            case .openai: return "OpenAI"
            }
        }
        var subtitle: String {
            switch self {
            case .apple: return "On-device · Private"
            case .claude: return "Anthropic · API key"
            case .openai: return "OpenAI · API key"
            }
        }
        var icon: String {
            switch self {
            case .apple: return "cpu.fill"
            case .claude: return "sparkles"
            case .openai: return "circle.hexagongrid.fill"
            }
        }
        var requiresKey: Bool {
            switch self {
            case .apple: return false
            case .claude, .openai: return true
            }
        }
    }

    @ViewBuilder
    private func providerCard(_ kind: CardKind) -> some View {
        let active = isActive(kind)
        let hasKey = providerHasKey(kind)
        Button {
            handleCardTap(kind)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                providerSwatch(kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text(dark))
                    Text(kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.sub(dark))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Palette.accent.opacity(dark ? 0.14 : 0.08) : Palette.surface(dark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Palette.accent : Palette.divider(dark), lineWidth: active ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if !kind.requiresKey {
                    Text("FREE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Palette.added)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.added.opacity(0.12))
                        )
                        .padding(12)
                } else if hasKey {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.added)
                        .padding(12)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.name)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func providerSwatch(_ kind: CardKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(swatchFill(kind))
            Image(systemName: kind.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }

    private func swatchFill(_ kind: CardKind) -> AnyShapeStyle {
        switch kind {
        case .apple:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: "#555555"), Color(hex: "#222222")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .claude:
            return AnyShapeStyle(Color(hex: "#D97757"))
        case .openai:
            return AnyShapeStyle(Color(hex: "#10A37F"))
        }
    }

    private func isActive(_ kind: CardKind) -> Bool {
        switch (kind, store.selectedBackend) {
        case (.apple, .onDevice): return true
        case (.claude, .claude): return true
        case (.openai, .openai): return true
        default: return false
        }
    }

    private func providerHasKey(_ kind: CardKind) -> Bool {
        switch kind {
        case .apple: return false
        case .claude: return store.hasClaudeKey
        case .openai: return store.hasOpenAIKey
        }
    }

    private func handleCardTap(_ kind: CardKind) {
        switch kind {
        case .apple:
            store.selectedBackend = .onDevice
            editingProvider = nil
        case .claude:
            if store.hasClaudeKey {
                store.selectedBackend = .claude
            }
            editingProvider = .claude
        case .openai:
            if store.hasOpenAIKey {
                store.selectedBackend = .openai
            }
            editingProvider = .openai
        }
    }

    /// On mount or whenever `selectedBackend` changes, settle
    /// `editingProvider` to match the active backend: a cloud backend
    /// surfaces its config form; Apple surfaces the on-device info card
    /// (editingProvider = nil). The "land on a keyed provider" affordance
    /// is reserved for explicit card taps — after the user clicks Apple,
    /// the form must clear, even if a cloud key happens to be on file.
    private func resetEditingProvider() {
        switch store.selectedBackend {
        case .claude:
            editingProvider = .claude
        case .openai:
            editingProvider = .openai
        case .onDevice:
            editingProvider = nil
        }
    }

    // MARK: Key form + model picker

    @ViewBuilder
    private func providerKeyForm(_ provider: CloudProvider) -> some View {
        let hasKey = (provider == .claude) ? store.hasClaudeKey : store.hasOpenAIKey
        let savedKey: String? = (provider == .claude) ? store.currentClaudeKey() : store.currentOpenAIKey()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("API KEY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Palette.sub(dark))
                Spacer()
                if hasKey {
                    HStack(spacing: 4) {
                        Image(systemName: "lock")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Saved in Keychain")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.added)
                }
            }

            if hasKey, let savedKey {
                savedKeyRow(savedKey)
            } else {
                emptyKeyRow(provider: provider)
            }

            // Help line + "Where do I get a key?" link as a single
            // attributed-style line (Text concatenation lets us style
            // the link span without an HStack break in mid-paragraph).
            (
                Text("Your key is stored locally in macOS Keychain. We never send it anywhere except the provider's API.")
                    .foregroundStyle(Palette.sub(dark).opacity(0.85))
                + Text(" ")
                + Text("Where do I get a key? →")
                    .foregroundStyle(Palette.accent)
            )
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)

            if let keyError {
                Text(keyError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.removed)
            }

            if hasKey {
                modelPicker(provider)
                    .padding(.top, 14)
            }
        }
    }

    @ViewBuilder
    private func savedKeyRow(_ savedKey: String) -> some View {
        let masked: String = {
            let count = savedKey.count
            if count > 24 {
                return String(repeating: "•", count: 24) + "…" + savedKey.suffix(4)
            }
            return String(repeating: "•", count: count)
        }()
        HStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 14))
                .foregroundStyle(Palette.sub(dark))
            Text(revealKey ? savedKey : masked)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Palette.text(dark))
                .tracking(0.5)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                revealKey.toggle()
            } label: {
                Image(systemName: revealKey ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.sub(dark))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealKey ? "Hide API key" : "Show API key")
            Button {
                confirmingRemove = true
            } label: {
                Text("Remove")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.removed)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surface(dark)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.divider(dark), lineWidth: 0.5))
    }

    @ViewBuilder
    private func emptyKeyRow(provider: CloudProvider) -> some View {
        let placeholder = (provider == .claude) ? "sk-ant-…" : "sk-…"
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave = !trimmed.isEmpty
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 14))
                .foregroundStyle(Palette.sub(dark))
                .padding(.leading, 5)
            Group {
                if revealKey {
                    TextField(placeholder, text: $keyDraft)
                        .textFieldStyle(.plain)
                } else {
                    SecureField(placeholder, text: $keyDraft)
                        .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(Palette.text(dark))
            .onSubmit { saveKey(provider: provider) }

            Button {
                revealKey.toggle()
            } label: {
                Image(systemName: revealKey ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.sub(dark))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealKey ? "Hide API key" : "Show API key")

            Button {
                saveKey(provider: provider)
            } label: {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSave ? Color.white : Palette.sub(dark))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(canSave ? Palette.accent : Palette.surface(dark))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surface(dark)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.divider(dark), lineWidth: 0.5))
    }

    private func saveKey(provider: CloudProvider) {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            switch provider {
            case .claude: try store.setClaudeKey(trimmed)
            case .openai: try store.setOpenAIKey(trimmed)
            }
            keyDraft = ""
            revealKey = false
            keyError = nil
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't save the API key to Keychain."
        }
    }

    // MARK: Model picker

    @ViewBuilder
    private func modelPicker(_ provider: CloudProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MODEL")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Palette.sub(dark))
            VStack(spacing: 6) {
                switch provider {
                case .claude:
                    ForEach(Array(ClaudeModel.allCases.enumerated()), id: \.element.id) { idx, model in
                        modelRow(
                            isActive: store.selectedClaudeModel == model,
                            label: model.displayName,
                            recommended: idx == 0
                        ) {
                            store.selectedClaudeModel = model
                        }
                    }
                case .openai:
                    ForEach(Array(OpenAIModel.allCases.enumerated()), id: \.element.id) { idx, model in
                        modelRow(
                            isActive: store.selectedOpenAIModel == model,
                            label: model.displayName,
                            recommended: idx == 0
                        ) {
                            store.selectedOpenAIModel = model
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(isActive: Bool, label: String, recommended: Bool, onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isActive ? Color.clear : Palette.sub(dark).opacity(0.5),
                            lineWidth: 1.5
                        )
                        .background(
                            Circle().fill(isActive ? Palette.accent : Color.clear)
                        )
                    if isActive {
                        Circle().fill(Color.white).frame(width: 5, height: 5)
                    }
                }
                .frame(width: 14, height: 14)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text(dark))
                Spacer()
                if recommended {
                    Text("RECOMMENDED")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Palette.sub(dark))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.surface(dark))
                        )
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Palette.accent.opacity(dark ? 0.14 : 0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Palette.accent : Palette.divider(dark), lineWidth: isActive ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: On-device info card

    @ViewBuilder
    private var appleInfoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16))
                .foregroundStyle(Palette.added)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your text never leaves this Mac.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                Text("Apple Intelligence runs Foundation Models entirely on-device. No API key, no network requests, no logs. Free forever.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.sub(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface(dark)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.divider(dark), lineWidth: 0.5))
    }
}
