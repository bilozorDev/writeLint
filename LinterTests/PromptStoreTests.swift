import Testing
import Foundation
@testable import Write_Lint

@Suite("PromptStore — UserDefaults-backed prompt + advanced-mode toggle")
@MainActor
struct PromptStoreTests {

    /// Build a `PromptStore` whose Keychain reads/writes are scoped to a
    /// per-test service identifier. Without this isolation, every test
    /// would touch the developer's real `Hexaget.WriteLint` keychain entry
    /// at init — `hasClaudeKey`/`hasOpenAIKey` would intermittently observe
    /// real keys the developer happens to have set, and tests that
    /// manipulate the keys would clobber them.
    private static func makeStore(_ scratch: ScratchDefaults) -> PromptStore {
        PromptStore(
            defaults: scratch.defaults,
            keychainService: "linter.tests.promptstore.\(UUID().uuidString)",
            claudeAccount: "test-claude",
            openaiAccount: "test-openai"
        )
    }

    @Test func loadsDefaultInstructionsWhenSuiteEmpty() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.instructions == PromptStore.defaultInstructions)
        #expect(store.activeTemplate.isAtFactory)
        #expect(store.advancedMode == false)
    }

    @Test func loadsExistingInstructionsFromSuite() {
        // v1 → v2 migration: a stored grammarPrompt.v1 carries forward
        // into the seeded Grammar template's `instructions`, with the
        // factory text preserved as `factoryInstructions`. The compat
        // computed `instructions` reads the active template's body.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("custom prompt", forKey: "grammarPrompt.v1")
        let store = Self.makeStore(scratch)
        #expect(store.instructions == "custom prompt")
        #expect(store.activeTemplate.isAtFactory == false)
        #expect(store.activeTemplate.factoryInstructions == PromptStore.defaultInstructions)
    }

    @Test func writingInstructionsPersistsToTemplates() throws {
        // The legacy `instructions` setter is a writable computed that
        // routes per-keystroke writes to the active template's body. The
        // canonical persisted form is the JSON-encoded `templates.v2`
        // array; the legacy `grammarPrompt.v1` key is wiped on init and
        // never written back.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        store.instructions = "new prompt"
        let data = try #require(scratch.defaults.data(forKey: "templates.v2"))
        let decoded = try JSONDecoder().decode([Template].self, from: data)
        #expect(decoded.first?.instructions == "new prompt")
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == nil)
    }

    @Test func writingAdvancedModePersistsToSuite() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.advancedMode == false)
        store.advancedMode = true
        #expect(scratch.defaults.bool(forKey: "advancedMode.v1") == true)
    }

    @Test func revertTemplateToFactoryRestoresFactoryPrompt() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        store.instructions = "user-customized prompt"
        #expect(store.activeTemplate.isAtFactory == false)
        store.revertTemplateToFactory(id: store.selectedTemplateID)
        #expect(store.activeTemplate.isAtFactory)
        #expect(store.instructions == PromptStore.defaultInstructions)
        // Persisted too — next-launch load should match the default.
        let reloaded = Self.makeStore(scratch)
        #expect(reloaded.activeTemplate.isAtFactory)
    }

    @Test func emptyStoredStringFallsBackToDefault() {
        // The init treats empty-but-present as "no preference set" and falls
        // back to default. Defends against a corrupt prefs file blanking out
        // the prompt.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("", forKey: "grammarPrompt.v1")
        let store = Self.makeStore(scratch)
        #expect(store.activeTemplate.isAtFactory)
    }

    @Test func initRemovesOrphanedTemplateKeys() {
        // A user upgrading from a different earlier multi-template build
        // will have these keys lingering with an incompatible schema. Init
        // clears them on first read so they don't bloat prefs forever.
        // The new v2 keys (`templates.v2` / `selectedTemplateID.v2`) live
        // under different names, so this cleanup doesn't touch them.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(["junk"], forKey: "templates.v1")
        scratch.defaults.set("some-uuid", forKey: "selectedTemplateID.v1")
        _ = Self.makeStore(scratch)
        #expect(scratch.defaults.object(forKey: "templates.v1") == nil)
        #expect(scratch.defaults.object(forKey: "selectedTemplateID.v1") == nil)
    }

    // MARK: provider + model defaults / persistence

    @Test func selectedProviderDefaultsToClaude() {
        // First-launch and migration-from-Claude-only both land here:
        // no `cloudProvider.v1` key in defaults → Claude. Matches the
        // pre-OpenAI behavior so existing users see no observable change.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.selectedProvider == .claude)
    }

    @Test func selectedProviderPersistsAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        do {
            let store = Self.makeStore(scratch)
            store.selectedProvider = .openai
        }
        let reloaded = Self.makeStore(scratch)
        #expect(reloaded.selectedProvider == .openai)
    }

    @Test func selectedOpenAIModelDefaultsToGpt41Mini() {
        // Default matches the user's chosen baseline for grammar polish —
        // fast and cheap. Anything else here would silently shift cost
        // for users who never opened the picker.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.selectedOpenAIModel == .gpt41Mini)
    }

    @Test func selectedOpenAIModelPersistsAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        do {
            let store = Self.makeStore(scratch)
            store.selectedOpenAIModel = .gpt5
        }
        let reloaded = Self.makeStore(scratch)
        #expect(reloaded.selectedOpenAIModel == .gpt5)
    }

    // MARK: Keychain key round-trip (Claude + OpenAI)

    @Test func claudeKeyRoundTripUpdatesHasFlagAndCurrentValue() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearClaudeKey() }
        #expect(store.hasClaudeKey == false)
        #expect(store.currentClaudeKey() == nil)

        try store.setClaudeKey("sk-ant-test")
        #expect(store.hasClaudeKey == true)
        #expect(store.currentClaudeKey() == "sk-ant-test")

        try store.clearClaudeKey()
        #expect(store.hasClaudeKey == false)
        #expect(store.currentClaudeKey() == nil)
    }

    @Test func openaiKeyRoundTripUpdatesHasFlagAndCurrentValue() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearOpenAIKey() }
        #expect(store.hasOpenAIKey == false)
        #expect(store.currentOpenAIKey() == nil)

        try store.setOpenAIKey("sk-test")
        #expect(store.hasOpenAIKey == true)
        #expect(store.currentOpenAIKey() == "sk-test")

        try store.clearOpenAIKey()
        #expect(store.hasOpenAIKey == false)
        #expect(store.currentOpenAIKey() == nil)
    }

    @Test func clearingOneProviderKeyLeavesTheOtherIntact() throws {
        // Both providers share the same Keychain service but different
        // accounts — clearing one must NOT affect the other. Catches a
        // future regression where someone refactors the helpers and
        // accidentally widens the delete scope.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer {
            try? store.clearClaudeKey()
            try? store.clearOpenAIKey()
        }
        try store.setClaudeKey("claude-key")
        try store.setOpenAIKey("openai-key")
        #expect(store.hasClaudeKey && store.hasOpenAIKey)

        try store.clearClaudeKey()
        #expect(store.hasClaudeKey == false)
        #expect(store.hasOpenAIKey == true)
        #expect(store.currentOpenAIKey() == "openai-key")
    }

    // MARK: activeBackend derivation truth table

    /// Parametrized over `selectedBackend × hasClaudeKey × hasOpenAIKey`.
    /// `advancedMode` was dropped from the gate when the inline backend
    /// picker landed — a saved API key is now the only gate. The truth
    /// table at a glance:
    ///   selectedBackend=.onDevice → .onDevice (regardless of keys)
    ///   selectedBackend=.claude + hasClaudeKey → .claude
    ///   selectedBackend=.claude + !hasClaudeKey → .onDevice (fallback)
    ///   selectedBackend=.openai + hasOpenAIKey → .openai
    ///   selectedBackend=.openai + !hasOpenAIKey → .onDevice (fallback)
    /// Eight representative rows below.
    @Test(arguments: [
        // (selectedBackend, claudeKey, openaiKey, expected)
        (LintBackend.onDevice, false, false, LintBackend.onDevice),
        // .onDevice respected even when both keys exist — user explicitly
        // picked on-device, key presence shouldn't override.
        (LintBackend.onDevice, true,  true,  LintBackend.onDevice),
        (LintBackend.claude,   true,  false, LintBackend.claude),
        (LintBackend.claude,   true,  true,  LintBackend.claude),
        // Fallback when the picked cloud's key isn't present.
        (LintBackend.claude,   false, true,  LintBackend.onDevice),
        (LintBackend.openai,   false, true,  LintBackend.openai),
        (LintBackend.openai,   true,  true,  LintBackend.openai),
        (LintBackend.openai,   true,  false, LintBackend.onDevice),
    ])
    func activeBackendDerivation(
        selectedBackend: LintBackend,
        claudeKey: Bool,
        openaiKey: Bool,
        expected: LintBackend
    ) throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer {
            try? store.clearClaudeKey()
            try? store.clearOpenAIKey()
        }
        if claudeKey { try store.setClaudeKey("c") }
        if openaiKey { try store.setOpenAIKey("o") }
        store.selectedBackend = selectedBackend

        #expect(store.activeBackend == expected)
    }

    // MARK: selectedBackend persistence + migration

    @Test func selectedBackendDefaultsToOnDeviceOnFreshInstall() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        #expect(store.selectedBackend == .onDevice)
    }

    @Test func selectedBackendPersistsAcrossInits() {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let service = "linter.tests.persist.\(UUID().uuidString)"
        do {
            let store = PromptStore(
                defaults: scratch.defaults,
                keychainService: service,
                claudeAccount: "c", openaiAccount: "o"
            )
            store.selectedBackend = .openai
        }
        let reloaded = PromptStore(
            defaults: scratch.defaults,
            keychainService: service,
            claudeAccount: "c", openaiAccount: "o"
        )
        #expect(reloaded.selectedBackend == .openai)
    }

    @Test func migratesPreBackendKeyInstallWithCloudActive() throws {
        // Simulate a v1 install: `advancedMode = true`, `cloudProvider.v1
        // = "claude"`, Claude key in Keychain. The migration in init
        // should derive `selectedBackend = .claude` so the user's
        // existing cloud setup keeps working under the new gate model.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let service = "linter.tests.migrate.\(UUID().uuidString)"
        scratch.defaults.set(true, forKey: "advancedMode.v1")
        scratch.defaults.set("claude", forKey: "cloudProvider.v1")
        try Keychain.set("legacy-key", service: service, account: "claude-acct")
        defer { try? Keychain.clear(service: service, account: "claude-acct") }

        let store = PromptStore(
            defaults: scratch.defaults,
            keychainService: service,
            claudeAccount: "claude-acct",
            openaiAccount: "openai-acct"
        )
        #expect(store.selectedBackend == .claude)
    }

    @Test func migratesPreBackendKeyInstallWithCloudActiveOpenAI() throws {
        // Symmetric of the Claude case — verify the OpenAI arm of the
        // migration switch works too. Without this, a refactor that
        // accidentally wrote `.claude` for both branches of the
        // CloudProvider switch would slip past the existing coverage.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let service = "linter.tests.migrate.\(UUID().uuidString)"
        scratch.defaults.set(true, forKey: "advancedMode.v1")
        scratch.defaults.set("openai", forKey: "cloudProvider.v1")
        try Keychain.set("legacy-openai", service: service, account: "openai-acct")
        defer { try? Keychain.clear(service: service, account: "openai-acct") }

        let store = PromptStore(
            defaults: scratch.defaults,
            keychainService: service,
            claudeAccount: "claude-acct",
            openaiAccount: "openai-acct"
        )
        #expect(store.selectedBackend == .openai)
    }

    @Test func migratesPreBackendKeyInstallWithoutCloudActive() {
        // Same shape but `advancedMode = false` — the user was on the
        // on-device path under the old gate. Migration should leave them
        // there, regardless of any stale cloudProvider value.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(false, forKey: "advancedMode.v1")
        scratch.defaults.set("claude", forKey: "cloudProvider.v1")
        let store = Self.makeStore(scratch)
        #expect(store.selectedBackend == .onDevice)
    }

    @Test func persistedSelectedBackendTakesPrecedenceOverMigration() {
        // If `selectedBackend.v1` is already set, the init must use that
        // verbatim — the migration branch (which reads the legacy
        // `advancedMode.v1` + `cloudProvider.v1` pair) is a fallback for
        // first-launch-under-new-code only. Set conflicting values for
        // both schemas; the v2 value wins.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(true, forKey: "advancedMode.v1")
        scratch.defaults.set("claude", forKey: "cloudProvider.v1")  // legacy says claude
        scratch.defaults.set("onDevice", forKey: "selectedBackend.v1")  // v2 says on-device
        let store = Self.makeStore(scratch)
        #expect(store.selectedBackend == .onDevice)
    }

    // MARK: auto-switch on key save / remove

    @Test func savingClaudeKeyWhileOnDeviceFlipsActiveToClaude() throws {
        // Saving a key while the user is on .onDevice should activate
        // that backend — they pasted the key, that's their intent.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearClaudeKey() }
        #expect(store.selectedBackend == .onDevice)
        try store.setClaudeKey("sk")
        #expect(store.selectedBackend == .claude)
    }

    @Test func savingOpenAIKeyWhileOnDeviceFlipsActiveToOpenAI() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearOpenAIKey() }
        try store.setOpenAIKey("sk")
        #expect(store.selectedBackend == .openai)
    }

    @Test func savingClaudeKeyWhileOpenAIActiveDoesNotFlip() throws {
        // Adding a backup key while another cloud is active is the
        // critical narrowing — without it, registering a Claude fallback
        // would silently move every lint to Claude. Active backend stays.
        //
        // Setup uses a *direct* `selectedBackend` assignment instead of
        // calling `setOpenAIKey` first — that way this test only
        // exercises the Claude-side narrowing, independent of whether
        // the OpenAI-side auto-switch is correct.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearClaudeKey() }
        store.selectedBackend = .openai
        try store.setClaudeKey("claude-key")
        #expect(store.selectedBackend == .openai, "registering a Claude key while OpenAI active should not flip")
    }

    @Test func savingOpenAIKeyWhileClaudeActiveDoesNotFlip() throws {
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearOpenAIKey() }
        store.selectedBackend = .claude
        try store.setOpenAIKey("openai-key")
        #expect(store.selectedBackend == .claude, "registering an OpenAI key while Claude active should not flip")
    }

    @Test func clearingActiveProviderKeyFallsBackToOnDevice() throws {
        // Removing the active provider's key drops the user back to the
        // on-device path — selectedBackend stays in sync rather than
        // dangling on a now-keyless cloud option.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer { try? store.clearClaudeKey() }
        try store.setClaudeKey("sk")
        #expect(store.selectedBackend == .claude)
        try store.clearClaudeKey()
        #expect(store.selectedBackend == .onDevice)
    }

    @Test func clearingInactiveProviderKeyDoesNotChangeBackend() throws {
        // The user has Claude active and an OpenAI key registered (but
        // not active). Removing the OpenAI key should leave Claude
        // active — only the active provider's removal triggers a
        // fallback.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer {
            try? store.clearClaudeKey()
            try? store.clearOpenAIKey()
        }
        try store.setClaudeKey("c")
        try store.setOpenAIKey("o")
        #expect(store.selectedBackend == .claude)
        try store.clearOpenAIKey()
        #expect(store.selectedBackend == .claude)
    }

    @Test func clearingInactiveKeyWhileOnDeviceDoesNotChangeBackend() throws {
        // Edge case the previous test missed: user has both keys saved
        // but is currently on .onDevice (e.g., they registered keys
        // earlier and toggled back to local). Removing either key must
        // leave selectedBackend at .onDevice — neither was active, so
        // there's nothing to fall back from.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        defer {
            try? store.clearClaudeKey()
            try? store.clearOpenAIKey()
        }
        try store.setClaudeKey("c")
        try store.setOpenAIKey("o")
        store.selectedBackend = .onDevice
        try store.clearClaudeKey()
        #expect(store.selectedBackend == .onDevice)
        try store.clearOpenAIKey()
        #expect(store.selectedBackend == .onDevice)
    }
}
