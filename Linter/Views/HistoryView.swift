import SwiftUI

struct HistoryView: View {
    let entries: [PromptEntry]
    let dark: Bool
    let onPick: (PromptEntry) -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT PROMPTS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.sub(dark))
                Spacer()
                if !entries.isEmpty {
                    if confirmingClear {
                        HStack(spacing: 6) {
                            Text("Clear all?")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.sub(dark))
                            Button("Cancel") { confirmingClear = false }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.sub(dark))
                            Button("Clear all") {
                                onClear()
                                confirmingClear = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.removed)
                        }
                    } else {
                        Button("Clear") { confirmingClear = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.sub(dark))
                    }
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.sub(dark))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close history")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No history yet — your last 10 prompts will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.sub(dark))
                        .multilineTextAlignment(.center)
                    Text("History is stored locally on this Mac in plain text.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.sub(dark))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            HistoryRow(
                                entry: entry,
                                dark: dark,
                                onPick: { onPick(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(maxHeight: 280)
                Text("Stored locally on this Mac in plain text.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.sub(dark))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }
}

/// Read-only detail view for a single history entry. Shows a back-button
/// header with the entry's date + backend + edit counts, a `DiffView` of
/// the original → polished transform, and a "Use again" action that loads
/// the original back into the input field.
struct HistoryDetailView: View {
    let entry: PromptEntry
    let dark: Bool
    let onBack: () -> Void
    let onUseAgain: () -> Void

    /// Diff ops + change stats are computed once in `.task` and cached.
    /// SwiftUI re-evaluates `body` on parent layout/dark-mode changes;
    /// without this cache, `Diff.diff` (LCS, O(n·m) over word tokens) would
    /// re-run every time. For typical history entries it's microseconds,
    /// but a long entry could cause a perceptible hitch on each redraw.
    @State private var ops: [DiffOp] = []
    @State private var stats: (added: Int, removed: Int) = (0, 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: back chevron + date/backend/stats chip + "Use again"
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("History")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Palette.surface(dark))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Palette.divider(dark), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    // Edit-count badges mirror the live ResultActions row
                    // so the user gets parity context across both paths.
                    HStack(spacing: 3) {
                        Circle().fill(Palette.added).frame(width: 5, height: 5)
                        Text("+\(stats.added)")
                    }
                    HStack(spacing: 3) {
                        Circle().fill(Palette.removed).frame(width: 5, height: 5)
                        Text("−\(stats.removed)")
                    }
                    Text("·")
                    Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text("·")
                    Text(entry.backendLabel)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub(dark))

                Spacer()

                Button(action: onUseAgain) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Use again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Palette.surface(dark))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Palette.divider(dark), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            }

            // Diff. Capped height matches the live-result diff scroll
            // (LinterWindow.swift `frame(maxHeight: 360)`), so a long
            // history entry doesn't grow the panel beyond what a fresh
            // lint would.
            ScrollView {
                DiffView(ops: ops, dark: dark)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
        // Compute the diff once on appear. `.task` is keyed on entry.id so
        // navigating between different history entries (without dismissing
        // the detail view) recomputes for the new entry rather than reusing
        // a stale cache from the previous one.
        .task(id: entry.id) {
            let computed = Diff.diff(entry.original, entry.polished)
            ops = computed
            stats = Diff.countChanges(computed)
        }
    }
}

private struct HistoryRow: View {
    let entry: PromptEntry
    let dark: Bool
    let onPick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: 10) {
                // Static grammar badge — single-template app, so every
                // history row is a grammar polish.
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: "#0A84FF"))
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.original)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text(dark))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(entry.date, format: .relative(presentation: .numeric))
                        Text("·")
                        Text(entry.backendLabel)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.sub(dark))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.sub(dark).opacity(hover ? 1 : 0.5))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hover ? Palette.surface(dark) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
