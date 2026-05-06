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
    /// Initial color/icon picked when "+ New" fires, mutable so the
    /// pickers in the draft editor work the same as the saved-template
    /// editor. Defaults match the design's "+ New" affordance.
    var colorHex: String = "#BF5AF2"
    var iconName: String = "sparkle"

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

/// Routing state for the new sidebar+detail Settings shell. The active
/// page is one of: a specific template's editor, the system Shortcuts
/// page, or the AI Provider page. Held in `LinterWindow` so the parent
/// can drive route changes from outside (e.g. on Settings open we land
/// on the active template's editor).
enum SettingsRoute: Hashable {
    case template(UUID)
    case shortcuts
    case provider
}

/// Top-level Settings shell. Owns its own 760×540 chrome (header bar +
/// sidebar + detail) so the parent can simply mount/unmount this view
/// when toggling settings — no outer `ScrollView` or panel-side header
/// duplicates the layout. Confirmation alerts (Revert, Delete, Remove
/// key) live with their owning detail views; the `Discard unsaved
/// changes?` alert stays in `LinterWindow` and is invoked through
/// `attemptDiscardingDraft`.
struct SettingsPanel: View {
    @Bindable var store: PromptStore
    @Binding var autoHide: Bool
    @Binding var draft: TemplateDraft?
    @Binding var page: SettingsRoute
    let dark: Bool
    /// Closure provided by `LinterWindow` that runs `action` only after
    /// the user has resolved any unsaved draft (immediately if nothing
    /// to discard, after Discard confirmation otherwise).
    let attemptDiscardingDraft: (@escaping () -> Void) -> Void
    /// Called when the user presses Back / clicks outside / anything that
    /// closes Settings. Owner side decides the animation.
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            HStack(spacing: 0) {
                SettingsSidebar(
                    store: store,
                    page: $page,
                    draft: $draft,
                    dark: dark,
                    attemptDiscardingDraft: attemptDiscardingDraft
                )
                .frame(width: 220)
                Rectangle().fill(Palette.divider(dark)).frame(width: 1)
                SettingsDetail(
                    store: store,
                    autoHide: $autoHide,
                    draft: $draft,
                    page: $page,
                    dark: dark
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 540)
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                attemptDiscardingDraft { onClose() }
            } label: {
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
            // The Esc-cascade in LinterWindow already routes Esc here via
            // the same draft-guard, so we don't double-bind the shortcut
            // (binding it would conflict with TextField focus inside the
            // detail panes).
            Spacer()
            Text("Settings")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
            Spacer()
            Color.clear.frame(width: 70, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }
}

// MARK: - Sidebar

/// 220pt-wide sidebar listing templates (with `⌘N` hints) and the System
/// pages (Shortcuts & behavior, AI provider). Footer summarizes the
/// currently-active backend so the user never has to leave Settings to
/// see what their next lint will run on.
private struct SettingsSidebar: View {
    @Bindable var store: PromptStore
    @Binding var page: SettingsRoute
    @Binding var draft: TemplateDraft?
    let dark: Bool
    let attemptDiscardingDraft: (@escaping () -> Void) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    templatesHeader
                    VStack(spacing: 1) {
                        ForEach(Array(store.templates.enumerated()), id: \.element.id) { idx, template in
                            templateRow(idx: idx, template: template)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                    systemHeader
                    VStack(spacing: 1) {
                        SidebarRow(
                            active: !isDraftEditorVisible && page == .shortcuts,
                            color: nil,
                            icon: "keyboard",
                            label: "Shortcuts & behavior",
                            shortcut: nil,
                            dark: dark
                        ) {
                            attemptDiscardingDraft {
                                page = .shortcuts
                            }
                        }
                        SidebarRow(
                            active: !isDraftEditorVisible && page == .provider,
                            color: nil,
                            icon: "cloud",
                            label: "AI provider",
                            shortcut: store.activeBackend == .onDevice ? nil : "●",
                            dark: dark
                        ) {
                            attemptDiscardingDraft {
                                page = .provider
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.top, 4)
            }

            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            footer
        }
        .background(dark ? Color.black.opacity(0.12) : Color.black.opacity(0.025))
    }

    /// True while the draft editor is the active right-pane view —
    /// suppresses the active highlight on regular sidebar entries while
    /// the user is mid-draft (matches the design's "draft holds the
    /// detail until resolved" semantics).
    private var isDraftEditorVisible: Bool { draft != nil }

    @ViewBuilder
    private var templatesHeader: some View {
        HStack(alignment: .center) {
            Text("TEMPLATES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Palette.sub(dark))
            Spacer()
            Button {
                attemptDiscardingDraft {
                    draft = TemplateDraft()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New template")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var systemHeader: some View {
        Text("SYSTEM")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(Palette.sub(dark))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func templateRow(idx: Int, template: Template) -> some View {
        let isActive: Bool = {
            if isDraftEditorVisible { return false }
            if case .template(let id) = page { return id == template.id }
            return false
        }()
        SidebarRow(
            active: isActive,
            color: Color(hex: template.colorHex),
            icon: TemplateIcon(rawValue: template.iconName)?.systemName ?? "pencil",
            label: template.name,
            shortcut: idx < 9 ? "⌘\(idx + 1)" : nil,
            dark: dark
        ) {
            attemptDiscardingDraft {
                store.selectTemplate(id: template.id)
                page = .template(template.id)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: store.activeBackend == .onDevice ? "cpu" : "cloud")
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub(dark))
            Text(footerLabel)
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub(dark))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footerLabel: String {
        switch store.activeBackend {
        case .onDevice:
            return "On-device · Foundation Models"
        case .claude:
            return "Cloud · \(store.selectedClaudeModel.footerLabel)"
        case .openai:
            return "Cloud · \(store.selectedOpenAIModel.footerLabel)"
        }
    }
}

/// Inline row helper used by both the templates list and the system
/// pages. The optional `color` swatch renders a 20pt tinted square with
/// a white SF Symbol (used for templates); when `color` is nil the icon
/// renders monochrome (used for system pages). `shortcut` is the ⌘N
/// pill (templates) or a dot indicator (e.g. "●" for "non-default
/// backend active").
private struct SidebarRow: View {
    let active: Bool
    let color: Color?
    let icon: String
    let label: String
    let shortcut: String?
    let dark: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let color {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color)
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Palette.sub(dark))
                }
                Text(label)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundStyle(Palette.text(dark))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.sub(dark))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.surface(dark))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(active ? Palette.surfaceStrong(dark) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Detail

/// Right-pane content router. Draft editor wins over any committed-route
/// detail (matches the design — the detail is dedicated to the draft
/// while a draft is active). Otherwise routes by `page`.
private struct SettingsDetail: View {
    @Bindable var store: PromptStore
    @Binding var autoHide: Bool
    @Binding var draft: TemplateDraft?
    @Binding var page: SettingsRoute
    let dark: Bool

    var body: some View {
        ZStack {
            if draft != nil {
                DraftEditor(store: store, draft: $draft, page: $page, dark: dark)
            } else {
                switch page {
                case .template(let id):
                    TemplateEditor(store: store, id: id, dark: dark) { _ in
                        // After a delete, route to the first remaining
                        // template (the active one after `deleteTemplate`
                        // moved selection upstream).
                        page = .template(store.selectedTemplateID)
                    }
                case .shortcuts:
                    ShortcutsBehaviorPage(autoHide: $autoHide, dark: dark)
                case .provider:
                    AIProviderPage(store: store, dark: dark)
                }
            }
        }
        .background(dark ? Color.white.opacity(0.02) : Color.white.opacity(0.5))
    }
}

// MARK: - Draft editor

/// Right-pane editor for the in-progress new-template draft. Mirrors the
/// structural layout of `TemplateEditor` so the user sees a consistent
/// editor regardless of saved-vs-draft, but persists nothing until Save.
/// Cancel discards the draft (the user explicitly chose to discard);
/// any *navigation* away (Back, sidebar tap) routes through
/// `attemptDiscardingDraft` upstream which raises the confirmation alert.
private struct DraftEditor: View {
    @Bindable var store: PromptStore
    @Binding var draft: TemplateDraft?
    @Binding var page: SettingsRoute
    let dark: Bool

    @FocusState private var nameFocused: Bool

    private var draftBinding: Binding<TemplateDraft> {
        Binding(
            get: { draft ?? TemplateDraft() },
            set: { draft = $0 }
        )
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
        .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(hex: draftBinding.wrappedValue.colorHex))
                Image(systemName: TemplateIcon(rawValue: draftBinding.wrappedValue.iconName)?.systemName ?? "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: Color(hex: draftBinding.wrappedValue.colorHex).opacity(0.25), radius: 8, y: 3)

            TextField("Template name", text: draftBinding.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
                .focused($nameFocused)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var pickersRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Color")
                HStack(spacing: 8) {
                    ForEach(Palette.swatches, id: \.self) { hex in
                        let active = draftBinding.wrappedValue.colorHex == hex
                        Button {
                            draftBinding.wrappedValue.colorHex = hex
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if !active {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                                    }
                                }
                                .padding(2)
                                .overlay {
                                    if active {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(hex: hex), lineWidth: 2)
                                            .frame(width: 28, height: 28)
                                    }
                                }
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Icon")
                HStack(spacing: 6) {
                    ForEach(TemplateIcon.allCases) { icon in
                        let active = draftBinding.wrappedValue.iconName == icon.rawValue
                        Button {
                            draftBinding.wrappedValue.iconName = icon.rawValue
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(active ? Color(hex: draftBinding.wrappedValue.colorHex) : Palette.surface(dark))
                                Image(systemName: icon.systemName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(active ? Color.white : Palette.sub(dark))
                            }
                            .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("System Prompt")
            Text("Write the entire system prompt the model should receive — examples included. Save adds the template; Cancel discards.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.sub(dark).opacity(0.85))
                .padding(.bottom, 2)
            TextEditor(text: draftBinding.instructions)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Palette.text(dark))
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11))
                .frame(minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surface(dark)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.divider(dark), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let canSave = draftBinding.wrappedValue.canSave
        HStack(spacing: 8) {
            Spacer()
            Button {
                draft = nil
            } label: {
                Text("Cancel")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.sub(dark))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            Button {
                saveDraft()
            } label: {
                Text("Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canSave ? Color.white : Palette.sub(dark))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(canSave ? Palette.accent : Palette.surface(dark))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func saveDraft() {
        guard let d = draft, d.canSave else { return }
        let trimmedName = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = d.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let newID = store.addTemplate(
            name: trimmedName,
            instructions: trimmedBody,
            colorHex: d.colorHex,
            iconName: d.iconName
        )
        draft = nil
        page = .template(newID)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Palette.sub(dark))
    }
}
