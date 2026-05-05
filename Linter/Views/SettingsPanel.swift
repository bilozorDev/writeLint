import SwiftUI

struct SettingsPanel: View {
    @Bindable var store: PromptStore
    @Binding var autoHide: Bool
    let dark: Bool

    /// Set to true while the revert confirmation dialog is on screen.
    @State private var confirmingRevert = false

    /// Local buffer for the API key SecureField. Cleared once the key is
    /// committed to the Keychain — we don't keep it in @State after that, so
    /// re-rendering Settings can't surface it back into the field.
    @State private var keyDraft: String = ""

    /// Set when SecItem returns an error during set/clear. Surfaced inline
    /// below the field so the user knows the action didn't take effect.
    @State private var keyError: String?

    /// Set to true while the API-key removal confirmation alert is on
    /// screen. Mirrors the confirming-revert pattern — a destructive
    /// one-click action gets a confirmation gate so the user doesn't
    /// accidentally wipe a key that was tedious to retrieve.
    @State private var confirmingRemoveKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Shortcut
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Global Shortcut").padding(.leading, 4)
                HStack {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.sub(dark))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Summon Write Lint")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.text(dark))
                        Text("Opens with focus, ready to type")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.sub(dark))
                    }
                    Spacer()
                    ShortcutRecorderView(dark: dark)
                }
                .padding(.horizontal, 4)
            }

            divider

            // Auto-hide after accept
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.sub(dark))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-hide after accept")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text(dark))
                    Text("Dismiss the panel after copying the corrected text")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(dark))
                }
                Spacer()
                Toggle("", isOn: $autoHide)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 4)

            divider

            // Advanced mode toggle. Off by default; flipping it on reveals
            // the prompt editor + Revert button below.
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.sub(dark))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Advanced mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text(dark))
                    Text("Edit the prompt sent to the on-device model")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(dark))
                }
                Spacer()
                Toggle("", isOn: $store.advancedMode)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 4)

            if store.advancedMode {
                advancedSection
            }

            // Footer — reflects which backend will service the next lint.
            HStack(spacing: 6) {
                Image(systemName: store.activeBackend == .claude ? "cloud" : "apple.logo")
                    .font(.system(size: 11))
                Text(footerCopy)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Palette.sub(dark))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(14)
        // Confirmation dialog for revert. The "Revert" button is destructive
        // — it overwrites whatever's in the editor with `defaultInstructions`
        // — so the user has to explicitly confirm.
        .alert("Revert prompt to default?", isPresented: $confirmingRevert) {
            Button("Cancel", role: .cancel) { }
            Button("Revert", role: .destructive) {
                store.revertToDefault()
            }
        } message: {
            Text("Your customizations to the prompt will be deleted and replaced with the factory default. This can't be undone.")
        }
        // Same confirmation pattern as Revert — destructive, one-click,
        // expensive to recover from (user has to find their API key
        // again). The actual Keychain delete still throws on error;
        // surface that via `keyError` like the inline path. Dispatches
        // to whichever provider the user is currently configuring so a
        // single alert + state pair covers both backends.
        .alert("Remove \(store.selectedProvider.displayName) API key?", isPresented: $confirmingRemoveKey) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                do {
                    // The store handles falling `selectedBackend` back
                    // to .onDevice if the cleared key was the active
                    // one — single source of truth in PromptStore.
                    switch store.selectedProvider {
                    case .claude: try store.clearClaudeKey()
                    case .openai: try store.clearOpenAIKey()
                    }
                    keyDraft = ""
                    keyError = nil
                } catch {
                    keyError = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't remove the API key from Keychain."
                }
            }
        } message: {
            Text("The key will be deleted from your Mac's Keychain and lints will fall back to the on-device model. You'll need to paste the key again to re-enable the cloud backend.")
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Prompt")
                Spacer()
                Button {
                    confirmingRevert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Revert to default")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(store.isAtDefault ? Palette.sub(dark) : Palette.removed)
                }
                .buttonStyle(.plain)
                .disabled(store.isAtDefault)
            }
            .padding(.leading, 4)

            // The model receives this string verbatim as its system message.
            // Examples are part of the prompt — they're not injected
            // separately — so editing them here changes exactly what the
            // model sees, regardless of which backend is active.
            TextEditor(text: $store.instructions)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.text(dark))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))

            Text("This is the entire system prompt sent to the model — examples included.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.sub(dark))
                .padding(.leading, 4)

            cloudBackendSection
        }
    }

    /// Cloud backend opt-in. Lives inside Advanced Mode so it's hidden from
    /// the default user. The user picks a provider (Claude / OpenAI),
    /// enters that provider's API key, and the active backend flips to
    /// match. The two providers share UI scaffolding (key field, Saved
    /// indicator, model picker, error surface) — only the placeholder,
    /// model picker contents, and underlying store calls differ.
    @ViewBuilder
    private var cloudBackendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Cloud backend")
                .padding(.leading, 4)
                .padding(.top, 12)

            Text("Pick a provider and paste an API key to route lints through that provider's model. Without a key, polishing runs entirely on this Mac via Apple Intelligence.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.sub(dark))
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)

            // Provider picker — segmented control sits at the top so the
            // user picks which provider they're configuring before
            // entering credentials. Switching providers preserves the
            // other provider's stored key (separate Keychain account
            // namespaces).
            Picker("Provider", selection: $store.selectedProvider) {
                ForEach(CloudProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 4)
            // Reset the inline draft + error whenever the user toggles
            // providers — otherwise a half-typed Claude key would persist
            // when they switch to the OpenAI field, which is confusing.
            .onChange(of: store.selectedProvider) { _, _ in
                keyDraft = ""
                keyError = nil
            }

            switch store.selectedProvider {
            case .claude:
                providerKeySection(
                    hasKey: store.hasClaudeKey,
                    placeholder: "sk-ant-…"
                ) {
                    Picker("Claude model", selection: $store.selectedClaudeModel) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                }
            case .openai:
                providerKeySection(
                    hasKey: store.hasOpenAIKey,
                    placeholder: "sk-…"
                ) {
                    Picker("OpenAI model", selection: $store.selectedOpenAIModel) {
                        ForEach(OpenAIModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                }
            }

            if let keyError {
                Text(keyError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.removed)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Shared key-entry layout used by both Claude and OpenAI sections.
    /// The model picker is built inline by the caller via the
    /// `@ViewBuilder` closure — keeps SwiftUI's view-tree introspection
    /// intact (an `AnyView` wrapper would defeat compile-time
    /// optimization). The actions (Save / Remove) route through
    /// `saveKey()` / `confirmingRemoveKey`, both of which look at
    /// `store.selectedProvider` to dispatch to the right backend.
    @ViewBuilder
    private func providerKeySection<Picker: View>(
        hasKey: Bool,
        placeholder: String,
        @ViewBuilder modelPicker: () -> Picker
    ) -> some View {
        if hasKey {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.added)
                Text("API key saved in Keychain")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text(dark))
                Spacer()
                Button("Remove") { confirmingRemoveKey = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.removed)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 4)

            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.sub(dark))
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text(dark))
                Spacer()
                modelPicker()
                    .labelsHidden()
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 4)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub(dark))
                SecureField(placeholder, text: $keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    .onSubmit { saveKey() }
                Button("Save") { saveKey() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.sub(dark) : Palette.text(dark))
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 4)
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            // The store auto-switches `selectedBackend` for us — only
            // when the user was on .onDevice, so adding a backup key
            // while another cloud is active doesn't silently flip them.
            switch store.selectedProvider {
            case .claude: try store.setClaudeKey(trimmed)
            case .openai: try store.setOpenAIKey(trimmed)
            }
            keyDraft = ""
            keyError = nil
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't save the API key to Keychain."
        }
    }

    /// Footer copy under Settings — names the active backend honestly so
    /// the user can never miss which path their text is taking.
    private var footerCopy: String {
        switch store.activeBackend {
        case .onDevice:
            return "Running on Apple Foundation Models · On-device · Private"
        case .claude:
            return "Running on \(store.selectedClaudeModel.displayName) · Cloud"
        case .openai:
            return "Running on \(store.selectedOpenAIModel.displayName) · Cloud"
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.divider(dark)).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .tracking(0.6)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Palette.sub(dark))
    }

}
