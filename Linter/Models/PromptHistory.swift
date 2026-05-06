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
    /// v3+: the template that produced this polish. Optional so v2 entries
    /// (no template concept) decode forward as `nil`. Recorded for future
    /// history-detail use; not yet displayed anywhere.
    var templateID: UUID?
}

@Observable
@MainActor
final class PromptHistory {
    /// Bumped from `promptHistory.v2` for the schema change adding
    /// `templateID`. v2 entries decode forward — `templateID` is optional,
    /// so a missing JSON key resolves to `nil` — and we re-encode under v3
    /// on first launch, then drop the v2 key. v1 entries can't be promoted
    /// (we never recorded the polished output back then), so v1 data is
    /// dropped on first launch under v2 or later.
    private static let key = "promptHistory.v3"
    private static let legacyKey = "promptHistory.v2"
    private static let veryLegacyKey = "promptHistory.v1"
    private static let maxEntries = 10
    static let shared = PromptHistory()

    private let defaults: UserDefaults

    var entries: [PromptEntry] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Chained read: v3 → corrupt-v3-fallback to v2 → v2-decode + re-encode → empty.
        // Only remove the v2 key after a successful v3 re-encode so an
        // encoder failure (extremely unlikely with a flat Codable struct,
        // but cheap insurance) doesn't wipe history.
        let loaded: [PromptEntry]
        if let data = defaults.data(forKey: Self.key) {
            if let decoded = try? JSONDecoder().decode([PromptEntry].self, from: data) {
                loaded = decoded
            } else if let v2Data = defaults.data(forKey: Self.legacyKey),
                      let decoded = try? JSONDecoder().decode([PromptEntry].self, from: v2Data) {
                loaded = decoded
                if let reencoded = try? JSONEncoder().encode(decoded) {
                    defaults.set(reencoded, forKey: Self.key)
                    defaults.removeObject(forKey: Self.legacyKey)
                }
            } else {
                loaded = []
            }
        } else if let v2Data = defaults.data(forKey: Self.legacyKey),
                  let decoded = try? JSONDecoder().decode([PromptEntry].self, from: v2Data) {
            loaded = decoded
            if let reencoded = try? JSONEncoder().encode(decoded) {
                defaults.set(reencoded, forKey: Self.key)
                defaults.removeObject(forKey: Self.legacyKey)
            }
        } else {
            loaded = []
        }
        self.entries = loaded

        // v1 cleanup is unconditional — schema is incompatible (v1 stored
        // only the original text, no polished output, no backend label).
        // `removeObject` on a missing key is harmless.
        defaults.removeObject(forKey: Self.veryLegacyKey)
    }

    /// Record a completed lint that the user accepted. Most recent first.
    /// Drops trailing entries past the cap. If the most recent entry has the
    /// same `original` text, skip it (avoid dupes from re-running the same
    /// input back-to-back).
    ///
    /// Capture happens on Accept (not on submit) — that way the history
    /// reflects only the lints the user actually used, and we have the
    /// polished output + backend label available to store. `templateID`
    /// is the template the lint *was run with* at submit time, captured
    /// by the caller alongside the prompt body so a switch between submit
    /// and accept doesn't mis-attribute the entry.
    func recordAccepted(
        original: String,
        polished: String,
        backendLabel: String,
        templateID: UUID? = nil
    ) {
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
            date: Date(),
            templateID: templateID
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
