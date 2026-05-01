import Testing
import Foundation
@testable import Linter

@Suite("PromptHistory — recent-prompts list with dedup, trim, cap-to-10, legacy decode")
@MainActor
struct PromptHistoryTests {

    @Test func loadsEmptyWhenSuiteEmpty() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        #expect(h.entries.isEmpty)
    }

    @Test func recordPrependsToList() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.record(text: "first")
        h.record(text: "second")
        #expect(h.entries.map(\.text) == ["second", "first"])
    }

    @Test func recordSkipsExactDupOfMostRecent() {
        // Re-running the same input shouldn't pile up. Older identical entries
        // (e.g. "hi" → other → "hi") DO add a new row — this only dedups
        // back-to-back duplicates.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.record(text: "hi")
        h.record(text: "hi")
        h.record(text: "hi")
        #expect(h.entries.count == 1)
    }

    @Test func recordTrimsWhitespaceBeforeStorageAndDedup() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.record(text: "hello")
        h.record(text: "  hello  ")  // same content after trim — should dedup
        #expect(h.entries.count == 1)
        #expect(h.entries[0].text == "hello")
    }

    @Test func recordIgnoresWhitespaceOnlyInput() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.record(text: "   \n\t ")
        #expect(h.entries.isEmpty)
    }

    @Test func recordCapsAtTenEntriesEvictingOldest() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        for i in 1...12 {
            h.record(text: "entry \(i)")
        }
        #expect(h.entries.count == 10)
        // Most-recent first, so entries 12 and 3 are the ends.
        #expect(h.entries.first?.text == "entry 12")
        #expect(h.entries.last?.text == "entry 3")
    }

    @Test func clearEmptiesEntries() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.record(text: "anything")
        #expect(h.entries.isEmpty == false)
        h.clear()
        #expect(h.entries.isEmpty)
        // Clear persists — reloading sees empty.
        let reloaded = PromptHistory(defaults: scratch.defaults)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func entriesPersistAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        do {
            let h = PromptHistory(defaults: scratch.defaults)
            h.record(text: "alpha")
            h.record(text: "beta")
        }
        let h2 = PromptHistory(defaults: scratch.defaults)
        #expect(h2.entries.map(\.text) == ["beta", "alpha"])
    }

    // MARK: legacy `templateID` forward-compat

    @Test func decodesLegacyEntriesWithTemplateIDField() {
        // Older builds stored each entry with an extra `templateID` field.
        // JSONDecoder ignores unknown keys, so old data should decode cleanly
        // into the slimmer `PromptEntry`. After load, the field is dropped on
        // the next persist — verify by re-encoding and confirming `templateID`
        // is absent in the round-tripped JSON.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let legacyJSON = """
        [
          { "id": "11111111-1111-1111-1111-111111111111",
            "text": "old entry one",
            "date": 770000000.0,
            "templateID": "deprecated-template" }
        ]
        """
        scratch.defaults.set(legacyJSON.data(using: .utf8)!, forKey: "promptHistory.v1")
        let h = PromptHistory(defaults: scratch.defaults)
        #expect(h.entries.count == 1)
        #expect(h.entries[0].text == "old entry one")
        // Force a re-persist by adding then clearing.
        h.record(text: "trigger")
        h.clear()
        h.record(text: "trigger")
        let raw = scratch.defaults.data(forKey: "promptHistory.v1") ?? Data()
        let str = String(data: raw, encoding: .utf8) ?? ""
        #expect(str.contains("templateID") == false, "legacy field should be dropped on re-persist; got: \(str)")
    }

    @Test func selfHealsWhitespaceInLegacyEntriesOnLoad() {
        // Older builds didn't trim before persisting. Init detects untrimmed
        // entries and re-persists trimmed versions, so the next session is
        // clean.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let dirtyJSON = """
        [
          { "id": "22222222-2222-2222-2222-222222222222",
            "text": "  surrounded by spaces  ",
            "date": 770000000.0 }
        ]
        """
        scratch.defaults.set(dirtyJSON.data(using: .utf8)!, forKey: "promptHistory.v1")
        let h = PromptHistory(defaults: scratch.defaults)
        #expect(h.entries[0].text == "surrounded by spaces")
        // Verify it persisted the trimmed value.
        let h2 = PromptHistory(defaults: scratch.defaults)
        #expect(h2.entries[0].text == "surrounded by spaces")
    }
}
