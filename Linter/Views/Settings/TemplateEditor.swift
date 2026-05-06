import SwiftUI

/// Right-pane editor for an existing template. Uses a batch-on-Save pattern
/// (matching the design): edits accumulate in a local `draft` and only land
/// in `store.templates` when the user clicks **Save changes**. The dirty
/// computed compares the entire `Template` value, so name / color / icon /
/// instructions all contribute to the Save enabled-state.
///
/// Resync rule: when the parent navigates between templates (the sidebar
/// row changes the routed `id`), `.onChange(of: id)` reloads `draft` from
/// the store's canonical record. That's also the recovery path for an
/// upstream mutation (e.g. ⌘N tab switch via the slash popup) — the editor
/// always reflects the user-visible state of the routed template.
struct TemplateEditor: View {
    @Bindable var store: PromptStore
    /// The id of the template this editor is bound to. Driven by
    /// `SettingsRoute.template(UUID)` in the parent. The editor reloads
    /// its local `draft` whenever this changes.
    let id: UUID
    let dark: Bool
    /// Called by the sidebar / parent so a Delete confirmation can route
    /// the active page to the next remaining template after the row is
    /// removed (the design's "navigate to first remaining template"
    /// semantics — handled in the parent because route ownership lives there).
    var onDeleted: (UUID) -> Void

    @State private var draft: Template
    @State private var confirmingRevert = false
    @State private var confirmingDelete = false

    /// Initialize with the canonical template — falls back to a synthetic
    /// placeholder if the id has been removed underneath us (extremely rare,
    /// but `Template` has no nil-able default; prefer a render that won't
    /// crash over an `if let` cascade in the parent).
    init(store: PromptStore, id: UUID, dark: Bool, onDeleted: @escaping (UUID) -> Void) {
        self.store = store
        self.id = id
        self.dark = dark
        self.onDeleted = onDeleted
        let canonical = store.templates.first(where: { $0.id == id })
            ?? Template(
                id: id,
                name: "",
                instructions: "",
                factoryInstructions: nil,
                colorHex: "#0A84FF",
                iconName: "pencil"
            )
        _draft = State(initialValue: canonical)
    }

    private var canonical: Template? {
        store.templates.first(where: { $0.id == id })
    }

    private var dirty: Bool {
        guard let canonical else { return false }
        return draft.name != canonical.name
            || draft.instructions != canonical.instructions
            || draft.colorHex != canonical.colorHex
            || draft.iconName != canonical.iconName
    }

    /// Position-among-templates index used for the `⌘N` pill in the editor
    /// header. Returns the display number (1-based) clamped to 9 — the design
    /// shows the pill for any position; 10+ just won't have a working ⌘N
    /// shortcut (consistent with `selectTemplate(at:)`'s no-op).
    private var headerShortcutNumber: Int? {
        guard let idx = store.templates.firstIndex(where: { $0.id == id }), idx < 9 else { return nil }
        return idx + 1
    }

    /// True when the canonical template carries a non-nil
    /// `factoryInstructions` AND the current draft (or saved state, on
    /// non-dirty editor) diverges from it. The Revert button only shows for
    /// built-ins that have actually drifted — matches the v1 SettingsPanel
    /// semantics where "Revert at-factory" is a no-op masked behind a
    /// disabled button.
    private var canRevert: Bool {
        guard let canonical, let factory = canonical.factoryInstructions else { return false }
        return draft.instructions != factory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pickersRow
                    promptSection
                    actionRow
                }
                .padding(EdgeInsets(top: 18, leading: 22, bottom: 22, trailing: 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: id) { _, _ in
            if let canonical { draft = canonical }
        }
        // Re-pull when the canonical template body changes from outside
        // (e.g. ⌘1..⌘9 switches don't change `id` here because parent
        // SettingsRoute holds steady, but a save from another path or
        // delete-and-recreate can mutate the canonical record).
        .onChange(of: canonical) { _, newCanonical in
            // Only resync when not dirty — otherwise we'd silently throw
            // away the user's in-progress edits the moment any other field
            // on the canonical record changes (reordering, rename via slash
            // popup, etc.). Dirty editor wins until the user clicks Save
            // or the parent navigates away.
            if !dirty, let newCanonical { draft = newCanonical }
        }
        .alert("Revert prompt to default?", isPresented: $confirmingRevert) {
            Button("Cancel", role: .cancel) { }
            Button("Revert", role: .destructive) {
                if let factory = canonical?.factoryInstructions {
                    draft.instructions = factory
                }
            }
        } message: {
            Text("Your customizations to this template's prompt will be replaced with the factory default. You can still click Cancel — the change isn't saved until you press Save.")
        }
        .alert("Delete template?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let toDelete = id
                store.deleteTemplate(id: toDelete)
                onDeleted(toDelete)
            }
        } message: {
            Text("\"\(canonical?.name ?? draft.name)\" will be removed. This can't be undone.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            // 44pt color-tinted icon. Uses `.shadow` for the soft glow
            // beneath the tile (matches the design's `boxShadow:
            // 0 4px 14px ${color}40`).
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(hex: draft.colorHex))
                Image(systemName: TemplateIcon(rawValue: draft.iconName)?.systemName ?? "pencil")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: Color(hex: draft.colorHex).opacity(0.25), radius: 8, y: 3)

            TextField("Template name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.text(dark))

            if let n = headerShortcutNumber {
                HStack(spacing: 4) {
                    Text("⌘")
                    Text("\(n)")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.sub(dark))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Palette.surface(dark))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Palette.divider(dark), lineWidth: 0.5)
                        )
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Pickers

    @ViewBuilder
    private var pickersRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Color")
                HStack(spacing: 8) {
                    ForEach(Palette.swatches, id: \.self) { hex in
                        colorSwatch(hex: hex)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Icon")
                HStack(spacing: 6) {
                    ForEach(TemplateIcon.allCases) { icon in
                        iconButton(icon: icon)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func colorSwatch(hex: String) -> some View {
        let isSelected = draft.colorHex == hex
        Button {
            draft.colorHex = hex
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: hex))
                .frame(width: 22, height: 22)
                .overlay(
                    // Inner ring for unselected: subtle dark hairline so
                    // light swatches are still legible on light surfaces.
                    Group {
                        if !isSelected {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.black.opacity(0.10), lineWidth: 1)
                        }
                    }
                )
                .padding(2)
                .overlay {
                    // Selected gets a 2pt halo at the 4pt outer ring
                    // (background-color first, swatch-color second).
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: hex), lineWidth: 2)
                            .frame(width: 28, height: 28)
                    }
                }
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func iconButton(icon: TemplateIcon) -> some View {
        let isSelected = draft.iconName == icon.rawValue
        Button {
            draft.iconName = icon.rawValue
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color(hex: draft.colorHex) : Palette.surface(dark))
                Image(systemName: icon.systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Palette.sub(dark))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Prompt

    @ViewBuilder
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("System Prompt")
            Text("The exact instructions sent to the model. Be specific about what to fix and what to leave alone.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.sub(dark).opacity(0.85))
                .padding(.bottom, 2)

            TextEditor(text: $draft.instructions)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Palette.text(dark))
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                .frame(minHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Palette.surface(dark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Palette.divider(dark), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if store.templates.count > 1 {
                Button {
                    confirmingDelete = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Delete template")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.removed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete template")
            }
            Spacer()
            if canRevert {
                Button {
                    confirmingRevert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Revert")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.sub(dark))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                save()
            } label: {
                Text("Save changes")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(dirty ? Color.white : Palette.sub(dark))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(dirty ? Palette.accent : Palette.surface(dark))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!dirty)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func save() {
        guard dirty else { return }
        // Trim the name at save-time so the in-editor field can briefly hold
        // whitespace while the user is typing — `saveTemplate` rejects the
        // write entirely on whitespace-only names, so guard locally too.
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var toSave = draft
        toSave.name = trimmed
        store.saveTemplate(toSave)
        // Resync from canonical so future dirty-checks are exact (the
        // store may have applied additional invariants — e.g. trim).
        if let canonical { draft = canonical }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Palette.sub(dark))
    }
}
