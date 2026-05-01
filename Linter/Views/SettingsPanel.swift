import SwiftUI

struct SettingsPanel: View {
    @Bindable var store: PromptStore
    @Binding var hotkey: Hotkey
    @Binding var autoHide: Bool
    let dark: Bool

    /// Set to true while the revert confirmation dialog is on screen.
    @State private var confirmingRevert = false

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
                    ShortcutRecorderView(hotkey: $hotkey, dark: dark)
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

            // Footer
            HStack(spacing: 6) {
                Image(systemName: "apple.logo").font(.system(size: 11))
                Text("Running on Apple Foundation Models · On-device · Private")
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

            // The on-device model receives this string verbatim as its
            // system message. Examples are part of the prompt — they're
            // not injected separately — so editing them here changes
            // exactly what the model sees.
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
