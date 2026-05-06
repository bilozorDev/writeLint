import SwiftUI

/// In-progress new-template state. Held in `LinterWindow` and bound
/// down into `SettingsPanel` so the settings-page back button (which
/// lives in `LinterWindow`) can read it for the draft-discard alert.
/// `hasContent` drives "is there anything to discard?" — both name and
/// instructions are checked because the user might type a name first
/// or paste a body first.
struct TemplateDraft: Equatable {
    var name: String = ""
    var instructions: String = ""

    var hasContent: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Save button stays disabled until BOTH name and instructions have
    /// non-whitespace content. Saving with an empty body would
    /// reproduce exactly the empty-prompt-freelancing bug we just
    /// fixed; saving with an empty name leaves the user with an
    /// unidentifiable row in the templates list.
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Sentinel used by `.focused(...)` for the draft editor's name field.
/// `@FocusState` requires a Hashable key; the regular per-template
/// focus uses `UUID?`, so we use a dedicated draft-marker UUID to
/// avoid colliding with any real template ID.
private let draftNameFocusKey = UUID()

struct SettingsPanel: View {
    @Bindable var store: PromptStore
    @Binding var autoHide: Bool
    @Binding var draft: TemplateDraft?
    let dark: Bool

    /// Closure provided by `LinterWindow` that runs `action` only after
    /// the user has resolved any unsaved draft (immediately if nothing
    /// to discard, after Discard confirmation otherwise). Used for
    /// in-panel navigation (clicking another template row, clicking
    /// "+ New template" again while a draft is active).
    let attemptDiscardingDraft: (@escaping () -> Void) -> Void

    /// Set to true while the revert confirmation dialog is on screen.
    @State private var confirmingRevert = false

    /// Set to true while the delete-template confirmation dialog is on
    /// screen. Same destructive-action pattern as the revert and
    /// remove-key alerts.
    @State private var confirmingDelete = false

    /// Drives focus on a template's name field after `+ New template`
    /// fires. The view binds each name field to `.focused($nameFieldFocus,
    /// equals: template.id)`, and the Add action sets `nameFieldFocus =
    /// newID` so the user can immediately rename the template they just
    /// created.
    @FocusState private var nameFieldFocus: UUID?

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
        // — it overwrites whatever's in the editor with the factory text
        // for the *currently active* template — so the user has to
        // explicitly confirm. Only enabled for templates with a non-nil
        // `factoryInstructions` (i.e. built-ins).
        .alert("Revert prompt to default?", isPresented: $confirmingRevert) {
            Button("Cancel", role: .cancel) { }
            Button("Revert", role: .destructive) {
                store.revertTemplateToFactory(id: store.selectedTemplateID)
            }
        } message: {
            Text("Your customizations to this template's prompt will be deleted and replaced with the factory default. This can't be undone.")
        }
        // Confirmation dialog for template delete. Only reachable when
        // there are at least two templates (the Delete button is hidden
        // when only one remains, and the store no-ops on the last
        // template anyway as defense-in-depth).
        .alert("Delete template?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                store.deleteTemplate(id: store.selectedTemplateID)
            }
        } message: {
            Text("\"\(store.activeTemplate.name)\" will be removed. This can't be undone.")
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
        VStack(alignment: .leading, spacing: 12) {
            templatesList
            // When a draft is active, render the draft editor in place
            // of the per-template editor. Existing templates are still
            // visible and clickable in the list above (clicks go
            // through `attemptDiscardingDraft`), but the editor area is
            // dedicated to the draft until Save or Cancel resolves it.
            if draft != nil {
                draftEditor
            } else {
                templateEditor
            }
            cloudBackendSection
        }
    }

    /// Templates list — one row per template, each showing the name and
    /// (for the first 9) the `⌘N` shortcut hint. Tapping a row makes that
    /// template active. The "+ New template" button below appends a new
    /// user-created template with an auto-numbered name and immediately
    /// pulls focus to its name field for rename.
    @ViewBuilder
    private var templatesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Templates").padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(Array(store.templates.enumerated()), id: \.element.id) { idx, template in
                    templateRow(idx: idx, template: template)
                }
            }
            .padding(.horizontal, 4)

            HStack {
                Button {
                    // Starting a new draft while another draft has
                    // unsaved content prompts the discard alert; an
                    // empty (or absent) draft is replaced silently.
                    attemptDiscardingDraft {
                        draft = TemplateDraft()
                        nameFieldFocus = draftNameFocusKey
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("New template")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Palette.text(dark))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func templateRow(idx: Int, template: Template) -> some View {
        let isSelected = template.id == store.selectedTemplateID
        HStack {
            Text(template.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text(dark))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if idx < 9 {
                Text("⌘\(idx + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.sub(dark))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Palette.surfaceStrong(dark) : Palette.surface(dark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            // Switching to an existing template while a draft has
            // unsaved content prompts the discard alert.
            attemptDiscardingDraft {
                store.selectTemplate(id: template.id)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: template, idx: idx))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private func accessibilityLabel(for template: Template, idx: Int) -> String {
        let position = "template \(idx + 1) of \(store.templates.count)"
        if idx < 9 {
            return "\(template.name), \(position), shortcut Command \(idx + 1)"
        }
        return "\(template.name), \(position)"
    }

    /// Per-active-template editor: name field, Revert (built-ins only),
    /// Delete (hidden on the last remaining template), and the body
    /// TextEditor that the legacy `$store.instructions` binding still
    /// drives — the writable computed routes the binding through
    /// `setInstructions(_:for:)` keyed on `selectedTemplateID`.
    @ViewBuilder
    private var templateEditor: some View {
        let active = store.activeTemplate
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Template name", text: nameBinding(for: active.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    .focused($nameFieldFocus, equals: active.id)
                Spacer()
                if active.factoryInstructions != nil {
                    Button {
                        confirmingRevert = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Revert")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(active.isAtFactory ? Palette.sub(dark) : Palette.removed)
                    }
                    .buttonStyle(.plain)
                    .disabled(active.isAtFactory)
                }
                if store.templates.count > 1 {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.removed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete template")
                }
            }
            .padding(.leading, 4)

            // The model receives this string verbatim as its system message.
            // Examples are part of the prompt — they're not injected
            // separately — so editing them here changes exactly what the
            // model sees, regardless of which backend is active. The
            // writable computed `instructions` routes per-keystroke writes
            // to `setInstructions(_:for: selectedTemplateID)` synchronously
            // on the main actor, so a mid-keystroke ⌘N switch lands
            // subsequent writes on the new template without mixing them
            // into the previous one's body.
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
        }
    }

    /// Two-way binding for a template's name. Reads the current value
    /// from `templates`; writes route through `renameTemplate(id:to:)`
    /// which trims whitespace and rejects empty names. SwiftUI invokes
    /// the setter on every keystroke, so empty/whitespace-only states
    /// during typing are handled gracefully — the rejected write is a
    /// no-op and the get returns the previous value on the next read.
    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.templates.first(where: { $0.id == id })?.name ?? "" },
            set: { store.renameTemplate(id: id, to: $0) }
        )
    }

    /// Per-keystroke binding for the draft name. Writes pass through
    /// raw — no trim, no reject — so the user sees what they typed in
    /// real time. The trim-and-reject step happens at Save time.
    private var draftNameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { newValue in
                guard draft != nil else { return }
                draft?.name = newValue
            }
        )
    }

    /// Per-keystroke binding for the draft body. Same shape as
    /// `draftNameBinding` — raw passthrough until Save.
    private var draftInstructionsBinding: Binding<String> {
        Binding(
            get: { draft?.instructions ?? "" },
            set: { newValue in
                guard draft != nil else { return }
                draft?.instructions = newValue
            }
        )
    }

    /// New-template editor. Replaces `templateEditor` while a draft is
    /// active. The draft is local UI state — nothing is added to
    /// `store.templates` until the user clicks Save. Cancel discards
    /// without confirmation (the user explicitly chose to discard);
    /// any *navigation* away from the draft (Back, row tap, "+ New"
    /// again) routes through `attemptDiscardingDraft` which raises
    /// the confirmation alert in `LinterWindow`.
    @ViewBuilder
    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Template name", text: draftNameBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    .focused($nameFieldFocus, equals: draftNameFocusKey)
                Spacer()
                // Cancel discards the draft outright. Acceptable without
                // confirmation because the user explicitly chose to
                // discard — the confirmation alert is for *implicit*
                // navigation away (closing Settings, switching template).
                Button {
                    draft = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.sub(dark))
                }
                .buttonStyle(.plain)
                Button {
                    saveDraft()
                } label: {
                    Text("Save")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle((draft?.canSave ?? false) ? Palette.accent : Palette.sub(dark))
                }
                .buttonStyle(.plain)
                .disabled(!(draft?.canSave ?? false))
            }
            .padding(.leading, 4)

            // Same TextEditor styling as the per-template editor — keeps
            // the visual continuity between drafting and editing a
            // saved template.
            TextEditor(text: draftInstructionsBinding)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.text(dark))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))

            Text("Write the entire system prompt the model should receive — examples included. Save to add the template; Cancel to discard.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.sub(dark))
                .padding(.leading, 4)
        }
    }

    /// Commit the draft to the store and clear it. Trims whitespace
    /// from name and body; the `canSave` gate ensures both are
    /// non-empty before this is reachable.
    private func saveDraft() {
        guard let d = draft, d.canSave else { return }
        let trimmedName = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = d.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.addTemplate(name: trimmedName, instructions: trimmedBody)
        draft = nil
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
