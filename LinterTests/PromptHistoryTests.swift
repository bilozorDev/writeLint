import Testing
import Foundation
@testable import Write_Lint

@Suite("PromptHistory — recent-prompts list with dedup, trim, cap-to-10, v1→v2 wipe")
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
        h.recordAccepted(original: "first", polished: "First.", backendLabel: "on-device")
        h.recordAccepted(original: "second", polished: "Second.", backendLabel: "on-device")
        #expect(h.entries.map(\.original) == ["second", "first"])
    }

    @Test func recordCapturesPolishedAndBackend() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(
            original: "helo world",
            polished: "Hello, world.",
            backendLabel: "Claude · Haiku 4.5"
        )
        let entry = try #require(h.entries.first)
        #expect(entry.original == "helo world")
        #expect(entry.polished == "Hello, world.")
        #expect(entry.backendLabel == "Claude · Haiku 4.5")
    }

    @Test func recordSkipsExactDupOfMostRecent() {
        // Re-running the same input shouldn't pile up. Older identical entries
        // (e.g. "hi" → other → "hi") DO add a new row — this only dedups
        // back-to-back duplicates. Dedup is on `original`, not `polished`,
        // so the same original re-polished slightly differently still
        // dedups (rare, but matches "the user submitted the same thing").
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(original: "hi", polished: "Hi.", backendLabel: "on-device")
        h.recordAccepted(original: "hi", polished: "Hi.", backendLabel: "on-device")
        h.recordAccepted(original: "hi", polished: "Hi!", backendLabel: "on-device")
        #expect(h.entries.count == 1)
    }

    @Test func recordTrimsWhitespaceBeforeStorageAndDedup() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(original: "hello", polished: "Hello.", backendLabel: "on-device")
        h.recordAccepted(original: "  hello  ", polished: "Hello.", backendLabel: "on-device")
        #expect(h.entries.count == 1)
        #expect(h.entries[0].original == "hello")
    }

    @Test func recordIgnoresWhitespaceOnlyInput() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(original: "   \n\t ", polished: "ignored", backendLabel: "on-device")
        #expect(h.entries.isEmpty)
    }

    @Test func recordCapsAtTenEntriesEvictingOldest() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        for i in 1...12 {
            h.recordAccepted(
                original: "entry \(i)",
                polished: "Entry \(i).",
                backendLabel: "on-device"
            )
        }
        #expect(h.entries.count == 10)
        #expect(h.entries.first?.original == "entry 12")
        #expect(h.entries.last?.original == "entry 3")
    }

    @Test func clearEmptiesEntries() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(original: "anything", polished: "Anything.", backendLabel: "on-device")
        #expect(h.entries.isEmpty == false)
        h.clear()
        #expect(h.entries.isEmpty)
        let reloaded = PromptHistory(defaults: scratch.defaults)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func entriesPersistAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        do {
            let h = PromptHistory(defaults: scratch.defaults)
            h.recordAccepted(original: "alpha", polished: "Alpha.", backendLabel: "on-device")
            h.recordAccepted(
                original: "beta",
                polished: "Beta.",
                backendLabel: "Claude · Haiku 4.5"
            )
        }
        let h2 = PromptHistory(defaults: scratch.defaults)
        #expect(h2.entries.map(\.original) == ["beta", "alpha"])
        // Backend label is part of the persisted shape — verify it
        // round-trips so the detail view can show "what model was used"
        // for a lint that happened across launches.
        #expect(h2.entries.first?.backendLabel == "Claude · Haiku 4.5")
    }

    // MARK: v1 → v2 schema migration

    @Test func legacyV1HistoryIsWipedAndKeyRemoved() {
        // v1 entries only carried the original text — no polished output,
        // no backend label. The detail view can't render a meaningful diff
        // from that, so on first launch under v2 we drop the v1 data and
        // remove the key. New entries land under `promptHistory.v2`.
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
        #expect(h.entries.isEmpty)
        // The legacy key is removed proactively so the prefs file doesn't
        // carry stale data.
        #expect(scratch.defaults.object(forKey: "promptHistory.v1") == nil)
    }

    @Test func newEntriesPersistUnderV3Key() {
        // Sanity-check that the new key really is `v3` — guards against
        // accidental key reverts that would silently lose data on next
        // launch.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(original: "hello", polished: "Hello.", backendLabel: "on-device")
        #expect(scratch.defaults.data(forKey: "promptHistory.v3") != nil)
        #expect(scratch.defaults.data(forKey: "promptHistory.v2") == nil)
        #expect(scratch.defaults.data(forKey: "promptHistory.v1") == nil)
    }

    // MARK: v2 → v3 schema migration (templateID added)

    @Test func legacyV2EntriesDecodeForwardWithNilTemplateID() throws {
        // v2 entries carried (id, original, polished, backendLabel, date) —
        // no `templateID`. Optional Codable fields decode to nil for missing
        // keys, so v2 data should round-trip into v3 with templateID == nil
        // and the legacy v2 key should be cleaned up.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let v2Entry: [String: Any] = [
            "id": "11111111-1111-1111-1111-111111111111",
            "original": "old entry",
            "polished": "Old entry.",
            "backendLabel": "on-device",
            "date": 770_000_000.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: [v2Entry])
        scratch.defaults.set(data, forKey: "promptHistory.v2")

        let h = PromptHistory(defaults: scratch.defaults)
        let entry = try #require(h.entries.first)
        #expect(entry.original == "old entry")
        #expect(entry.templateID == nil)
        // v2 key removed after successful re-encode under v3.
        #expect(scratch.defaults.data(forKey: "promptHistory.v2") == nil)
        #expect(scratch.defaults.data(forKey: "promptHistory.v3") != nil)
    }

    @Test func recordAcceptedRoundTripsTemplateID() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let template = UUID()
        let h = PromptHistory(defaults: scratch.defaults)
        h.recordAccepted(
            original: "hi",
            polished: "Hi.",
            backendLabel: "on-device",
            templateID: template
        )
        let reloaded = PromptHistory(defaults: scratch.defaults)
        #expect(reloaded.entries.first?.templateID == template)
    }
}
