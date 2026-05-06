import Testing
import Foundation
@testable import Write_Lint

/// Behavioral coverage for the multi-template features added in v2:
/// migration from `grammarPrompt.v1`, CRUD on the `templates` array, the
/// writable computed `instructions` getter/setter, and `isAtFactory`
/// flipping per-template. The Settings UI is not exercised here — these
/// tests only touch `PromptStore` semantics.
@Suite("PromptStore — multi-template behavior")
@MainActor
struct TemplatesTests {

    private static func makeStore(_ scratch: ScratchDefaults) -> PromptStore {
        PromptStore(
            defaults: scratch.defaults,
            keychainService: "linter.tests.templates.\(UUID().uuidString)",
            claudeAccount: "test-claude",
            openaiAccount: "test-openai"
        )
    }

    // MARK: Migration

    @Test func freshInstallSeedsGrammarTemplate() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.templates.count == 1)
        let grammar = store.templates[0]
        #expect(grammar.name == "Grammar")
        #expect(grammar.instructions == PromptStore.defaultInstructions)
        #expect(grammar.factoryInstructions == PromptStore.defaultInstructions)
        #expect(grammar.isAtFactory)
        #expect(store.selectedTemplateID == grammar.id)
    }

    @Test func legacyV1NonDefaultPromptMigratesIntoGrammar() {
        // A v1.0 user with a customized prompt: the migration carries
        // their text into the seeded Grammar template's `instructions`,
        // preserves the factory text as `factoryInstructions` (so Revert
        // still works), and removes the legacy key.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("custom user prompt", forKey: "grammarPrompt.v1")
        let store = Self.makeStore(scratch)
        #expect(store.templates.count == 1)
        let grammar = store.templates[0]
        #expect(grammar.instructions == "custom user prompt")
        #expect(grammar.factoryInstructions == PromptStore.defaultInstructions)
        #expect(grammar.isAtFactory == false)
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == nil)
    }

    @Test func legacyV1DefaultPromptMigratesAsDefault() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(PromptStore.defaultInstructions, forKey: "grammarPrompt.v1")
        let store = Self.makeStore(scratch)
        #expect(store.templates[0].isAtFactory)
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == nil)
    }

    @Test func v2KeysRoundTripAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let firstID: UUID
        do {
            let store = Self.makeStore(scratch)
            store.instructions = "round-trip body"
            store.addTemplate(name: "Friendly", instructions: "be warm")
            firstID = store.selectedTemplateID  // now points at Friendly
            #expect(store.templates.count == 2)
            #expect(firstID == store.templates[1].id)
        }
        let reloaded = Self.makeStore(scratch)
        #expect(reloaded.templates.count == 2)
        #expect(reloaded.templates[0].instructions == "round-trip body")
        #expect(reloaded.templates[1].name == "Friendly")
        #expect(reloaded.selectedTemplateID == firstID)
    }

    @Test func templatesV2WinsWhenBothV1AndV2Exist() throws {
        // Downgrade-replay scenario: user is on v2, downgrades to v1.0,
        // edits the prompt (v1 writes grammarPrompt.v1), upgrades back to
        // v2. `templates.v2` already exists from the first v2 launch and
        // takes precedence; the user's v1-era edits are dropped. v1 key
        // cleaned up unconditionally.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let preserved = Template(
            id: UUID(),
            name: "Preserved",
            instructions: "v2 body",
            factoryInstructions: PromptStore.defaultInstructions
        )
        let data = try JSONEncoder().encode([preserved])
        scratch.defaults.set(data, forKey: "templates.v2")
        scratch.defaults.set("v1 edits should be dropped", forKey: "grammarPrompt.v1")

        let store = Self.makeStore(scratch)
        #expect(store.templates.count == 1)
        #expect(store.templates[0].name == "Preserved")
        #expect(store.templates[0].instructions == "v2 body")
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == nil)
    }

    @Test func staleSelectedTemplateIDSelfHealsToFirstTemplate() throws {
        // If `selectedTemplateID.v2` references a UUID not in the loaded
        // `templates.v2` array (corrupt prefs or interrupted didSet
        // between two writes), init falls back to templates[0] and
        // re-persists the corrected ID.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let real = Template(
            id: UUID(),
            name: "Grammar",
            instructions: "x",
            factoryInstructions: PromptStore.defaultInstructions
        )
        let data = try JSONEncoder().encode([real])
        scratch.defaults.set(data, forKey: "templates.v2")
        scratch.defaults.set(UUID().uuidString, forKey: "selectedTemplateID.v2")

        let store = Self.makeStore(scratch)
        #expect(store.selectedTemplateID == real.id)
        #expect(scratch.defaults.string(forKey: "selectedTemplateID.v2") == real.id.uuidString)
    }

    // MARK: CRUD

    @Test func addTemplateAppendsAndSelectsIt() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let newID = store.addTemplate(name: "Friendly", instructions: "")
        #expect(store.templates.count == 2)
        #expect(store.templates.last?.id == newID)
        #expect(store.selectedTemplateID == newID)
        #expect(store.activeTemplate.factoryInstructions == nil)
    }


    @Test func addTemplateAutoNumbersDefaultName() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        store.addTemplate(instructions: "")  // "New template"
        store.addTemplate(instructions: "")  // "New template 2"
        store.addTemplate(instructions: "")  // "New template 3"
        #expect(store.templates.map(\.name) == ["Grammar", "New template", "New template 2", "New template 3"])
    }

    @Test func deleteTemplateMovesSelectionToPrevious() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let a = store.addTemplate(name: "A", instructions: "")
        let b = store.addTemplate(name: "B", instructions: "")
        let c = store.addTemplate(name: "C", instructions: "")
        store.selectTemplate(id: b)
        store.deleteTemplate(id: b)
        #expect(store.templates.count == 3)
        #expect(store.templates.map(\.name) == ["Grammar", "A", "C"])
        // Was at index 2 (B) before deletion → selection moves to index 1 (A).
        #expect(store.selectedTemplateID == a)
        #expect(c == c) // silence unused warning
    }

    @Test func deleteLastTemplateIsNoOp() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let onlyID = store.selectedTemplateID
        store.deleteTemplate(id: onlyID)
        #expect(store.templates.count == 1)
        #expect(store.selectedTemplateID == onlyID)
    }

    @Test func renameTemplatePersists() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let id = store.selectedTemplateID
        store.renameTemplate(id: id, to: "Updated")
        #expect(store.activeTemplate.name == "Updated")
    }

    @Test func renameTemplateAllowsDuplicates() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let added = store.addTemplate(name: "Other", instructions: "")
        store.renameTemplate(id: added, to: "Grammar")
        #expect(store.templates.map(\.name) == ["Grammar", "Grammar"])
    }

    @Test func renameTemplateTrimsWhitespace() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let id = store.selectedTemplateID
        store.renameTemplate(id: id, to: "  Spaces  ")
        #expect(store.activeTemplate.name == "Spaces")
    }

    @Test func renameTemplateRejectsWhitespaceOnly() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let id = store.selectedTemplateID
        let original = store.activeTemplate.name
        store.renameTemplate(id: id, to: "   ")
        #expect(store.activeTemplate.name == original)
    }

    @Test func selectTemplateAtBoundsCheck() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let originalID = store.selectedTemplateID
        store.selectTemplate(at: 99)
        #expect(store.selectedTemplateID == originalID)
        store.selectTemplate(at: -1)
        #expect(store.selectedTemplateID == originalID)
    }

    @Test func setInstructionsRoutesByID() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let other = store.addTemplate(name: "Other", instructions: "untouched")
        store.selectTemplate(id: store.templates[0].id)  // back to Grammar
        store.setInstructions("grammar update", for: store.templates[0].id)
        #expect(store.templates[0].instructions == "grammar update")
        #expect(store.templates.first(where: { $0.id == other })?.instructions == "untouched")
    }

    @Test func revertTemplateToFactoryNoOpsForUserCreated() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let custom = store.addTemplate(name: "Custom", instructions: "user body")
        #expect(store.templates.first(where: { $0.id == custom })?.factoryInstructions == nil)
        store.revertTemplateToFactory(id: custom)
        #expect(store.templates.first(where: { $0.id == custom })?.instructions == "user body")
    }

    // MARK: Computed `instructions` round-trip

    @Test func instructionsGetterReadsActiveTemplate() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        store.addTemplate(name: "Friendly", instructions: "warm body")
        // addTemplate selects the new one, so instructions getter should
        // return Friendly's body.
        #expect(store.instructions == "warm body")
    }

    @Test func instructionsSetterRoutesToActiveTemplate() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let grammarID = store.templates[0].id
        let friendlyID = store.addTemplate(name: "Friendly", instructions: "")
        store.instructions = "friendly write"
        #expect(store.templates.first(where: { $0.id == friendlyID })?.instructions == "friendly write")
        // Grammar untouched — the setter routes by *current* selectedTemplateID.
        #expect(store.templates.first(where: { $0.id == grammarID })?.instructions
                == PromptStore.defaultInstructions)
    }

    @Test func isAtFactoryFlipsOnEdit() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.activeTemplate.isAtFactory)
        store.instructions = "edited"
        #expect(store.activeTemplate.isAtFactory == false)
    }

    @Test func userCreatedTemplateNeverFactory() {
        // Even if a user-created template's body coincidentally equals
        // `defaultInstructions`, `isAtFactory` stays false because the
        // template's `factoryInstructions` is nil — there's no factory to
        // be "at". The Revert button stays hidden for user-created
        // templates.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        let id = store.addTemplate(name: "Coincidence", instructions: PromptStore.defaultInstructions)
        let template = try? #require(store.templates.first(where: { $0.id == id }))
        #expect(template?.factoryInstructions == nil)
        #expect(template?.isAtFactory == false)
    }

    // MARK: defaultNameForNewTemplate

    @Test func defaultNamePicksSmallestUnusedSuffix() {
        let base = Template(
            id: UUID(),
            name: "Grammar",
            instructions: "",
            factoryInstructions: nil
        )
        let nt1 = Template(id: UUID(), name: "New template", instructions: "", factoryInstructions: nil)
        let nt2 = Template(id: UUID(), name: "New template 2", instructions: "", factoryInstructions: nil)

        #expect(PromptStore.defaultNameForNewTemplate(in: [base]) == "New template")
        #expect(PromptStore.defaultNameForNewTemplate(in: [base, nt1]) == "New template 2")
        #expect(PromptStore.defaultNameForNewTemplate(in: [base, nt1, nt2]) == "New template 3")
        // Holes don't fill — "New template 2" is taken even if "New template" got renamed.
        let renamedBase = Template(id: UUID(), name: "Renamed", instructions: "", factoryInstructions: nil)
        #expect(PromptStore.defaultNameForNewTemplate(in: [renamedBase, nt2]) == "New template")
    }
}
