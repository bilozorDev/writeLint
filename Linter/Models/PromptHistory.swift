import Foundation
import Observation

struct PromptEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var text: String
    var templateID: String
    var date: Date
}

@Observable
@MainActor
final class PromptHistory {
    private static let key = "promptHistory.v1"
    private static let maxEntries = 10
    static let shared = PromptHistory()

    var entries: [PromptEntry] {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([PromptEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    /// Record a new prompt. Most recent first. Drops trailing entries past the cap.
    /// If the most recent entry has the same text + template, skip it (avoid dupes
    /// from re-running the same input back-to-back).
    func record(text: String, templateID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let first = entries.first,
           first.text == text, first.templateID == templateID {
            return
        }
        let entry = PromptEntry(id: UUID(), text: text, templateID: templateID, date: Date())
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
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
