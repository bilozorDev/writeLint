import Testing
import Foundation
@testable import Linter

@Suite("PromptStore — UserDefaults-backed prompt + advanced-mode toggle")
@MainActor
struct PromptStoreTests {

    @Test func loadsDefaultInstructionsWhenSuiteEmpty() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        #expect(store.instructions == PromptStore.defaultInstructions)
        #expect(store.isAtDefault)
        #expect(store.advancedMode == false)
    }

    @Test func loadsExistingInstructionsFromSuite() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("custom prompt", forKey: "grammarPrompt.v1")
        let store = PromptStore(defaults: scratch.defaults)
        #expect(store.instructions == "custom prompt")
        #expect(store.isAtDefault == false)
    }

    @Test func writingInstructionsPersistsToSuite() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        store.instructions = "new prompt"
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == "new prompt")
    }

    @Test func writingAdvancedModePersistsToSuite() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        #expect(store.advancedMode == false)
        store.advancedMode = true
        #expect(scratch.defaults.bool(forKey: "advancedMode.v1") == true)
    }

    @Test func revertToDefaultRestoresFactoryPrompt() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = PromptStore(defaults: scratch.defaults)
        store.instructions = "user-customized prompt"
        #expect(store.isAtDefault == false)
        store.revertToDefault()
        #expect(store.isAtDefault)
        #expect(store.instructions == PromptStore.defaultInstructions)
        // Persisted too — next-launch load should match the default.
        let reloaded = PromptStore(defaults: scratch.defaults)
        #expect(reloaded.isAtDefault)
    }

    @Test func emptyStoredStringFallsBackToDefault() {
        // The init treats empty-but-present as "no preference set" and falls
        // back to default. Defends against a corrupt prefs file blanking out
        // the prompt.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("", forKey: "grammarPrompt.v1")
        let store = PromptStore(defaults: scratch.defaults)
        #expect(store.isAtDefault)
    }

    @Test func initRemovesOrphanedTemplateKeys() {
        // A user upgrading from the multi-template build will have these keys
        // lingering. Init should clear them on first read so they don't bloat
        // the prefs forever.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(["junk"], forKey: "templates.v1")
        scratch.defaults.set("some-uuid", forKey: "selectedTemplateID.v1")
        _ = PromptStore(defaults: scratch.defaults)
        #expect(scratch.defaults.object(forKey: "templates.v1") == nil)
        #expect(scratch.defaults.object(forKey: "selectedTemplateID.v1") == nil)
    }
}
