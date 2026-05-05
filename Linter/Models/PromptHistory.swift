import Foundation
import Observation

struct PromptEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// Text the user submitted (trimmed of leading/trailing whitespace).
    var original: String
    /// Polished output as accepted by the user. Stored verbatim so the diff
    /// view can recompute the same edit set later.
    var polished: String
    /// Human-readable label of the backend that produced this polish — e.g.
    /// `"on-device"` or `"Claude · Haiku 4.5"`. Shown in the history-detail
    /// header so the user can tell at a glance which model handled it.
    var backendLabel: String
    var date: Date
}

@Observable
@MainActor
final class PromptHistory {
    /// Bumped from `promptHistory.v1` for the schema change adding
    /// `polished` + `backendLabel`. Old `v1` entries can't be promoted (we
    /// never recorded the polished output back then), so they're dropped on
    /// first launch under the new schema. The `v1` key is also removed
    /// proactively so the prefs file doesn't carry stale data.
    private static let key = "promptHistory.v2"
    private static let legacyKey = "promptHistory.v1"
    private static let maxEntries = 10
    static let shared = PromptHistory()

    private let defaults: UserDefaults

    var entries: [PromptEntry] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([PromptEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
        // One-time cleanup of v1 history. Schema is incompatible — v1 stored
        // only the original text, with no record of the polished output or
        // backend, so a v1 entry can't power the new diff-detail view.
        // `removeObject` on a missing key is harmless, so this is also a
        // no-op for fresh installs.
        defaults.removeObject(forKey: Self.legacyKey)
    }

    /// Record a completed lint that the user accepted. Most recent first.
    /// Drops trailing entries past the cap. If the most recent entry has the
    /// same `original` text, skip it (avoid dupes from re-running the same
    /// input back-to-back).
    ///
    /// Capture happens on Accept (not on submit) — that way the history
    /// reflects only the lints the user actually used, and we have the
    /// polished output + backend label available to store.
    func recordAccepted(original: String, polished: String, backendLabel: String) {
        // Trim before both checking AND storing, so we don't persist
        // surrounding whitespace and re-load it that way next session.
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let first = entries.first, first.original == trimmed {
            return
        }
        let entry = PromptEntry(
            id: UUID(),
            original: trimmed,
            polished: polished,
            backendLabel: backendLabel,
            date: Date()
        )
        var next = [entry] + entries
        if next.count > Self.maxEntries {
            next.removeLast(next.count - Self.maxEntries)
        }
        entries = next
    }

    func clear() {
        entries = []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
