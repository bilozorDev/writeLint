import Testing
import Foundation
@testable import Write_Lint

@Suite("PromptStore — UserDefaults-backed prompt + backend selection")
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
        // canonical persisted form is the JSON-encoded `templates.v3`
        // array; the legacy `grammarPrompt.v1` key is wiped on init and
        // never written back.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let store = Self.makeStore(scratch)
        store.instructions = "new prompt"
        let data = try #require(scratch.defaults.data(forKey: "templates.v3"))
        let decoded = try JSONDecoder().decode([Template].self, from: data)
        #expect(decoded.first?.instructions == "new prompt")
        #expect(scratch.defaults.string(forKey: "grammarPrompt.v1") == nil)
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

    // MARK: model defaults / persistence

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

    // MARK: selectedBackend persistence

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

    @Test func selectedBackendV1KeyReadVerbatim() {
        // v3 retired the legacy `advancedMode + cloudProvider.v1` upgrade
        // path. The init now does a single explicit read of
        // `selectedBackend.v1`, no fallback derivation. With a stored value
        // we expect that exact value out the other side.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set("openai", forKey: "selectedBackend.v1")
        let store = Self.makeStore(scratch)
        #expect(store.selectedBackend == .openai)
    }

    @Test func legacyAdvancedModeAndCloudProviderKeysAreIgnored() {
        // Defensive: if a v2-era install still has `advancedMode.v1` and
        // `cloudProvider.v1` set but no `selectedBackend.v1`, v3 init
        // should ignore the legacy keys entirely and default to onDevice.
        // (v2's footer Menu wrote `selectedBackend.v1` whenever the user
        // picked a non-default backend, so v2 users land in the explicit
        // read above — anyone hitting THIS branch had been on the
        // on-device path under v2 too.)
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        scratch.defaults.set(true, forKey: "advancedMode.v1")
        scratch.defaults.set("claude", forKey: "cloudProvider.v1")
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

    // MARK: v2 → v3 schema migration

    @Test func migrateV2ToV3_factoryGetsBluePencil_userTemplateGetsNonBlueSparkle() {
        // Mixed input: factory Grammar plus a user-created template.
        // Factory must always land on blue + pencil regardless of position;
        // user templates pull from the non-factory palette and get the
        // sparkle icon.
        let factoryID = UUID()
        let userID = UUID()
        let legacy: [LegacyTemplateV2] = [
            LegacyTemplateV2(
                id: factoryID,
                name: "Grammar",
                instructions: "factory body",
                factoryInstructions: PromptStore.defaultInstructions
            ),
            LegacyTemplateV2(
                id: userID,
                name: "Friendly",
                instructions: "warm body",
                factoryInstructions: nil
            ),
        ]
        let migrated = PromptStore.migrateV2ToV3(legacy)
        #expect(migrated.count == 2)
        #expect(migrated[0].id == factoryID)
        #expect(migrated[0].colorHex == "#0A84FF")
        #expect(migrated[0].iconName == "pencil")
        #expect(migrated[1].id == userID)
        // First non-factory entry should pull the first non-blue swatch.
        #expect(migrated[1].colorHex == "#5E5CE6")
        #expect(migrated[1].iconName == "sparkle")
    }

    @Test func migrateV2ToV3_preservesIdNameInstructionsFactory() {
        let id = UUID()
        let legacy = [
            LegacyTemplateV2(
                id: id,
                name: "Custom Name",
                instructions: "the body",
                factoryInstructions: "the factory"
            )
        ]
        let migrated = PromptStore.migrateV2ToV3(legacy)
        let entry = try? #require(migrated.first)
        #expect(entry?.id == id)
        #expect(entry?.name == "Custom Name")
        #expect(entry?.instructions == "the body")
        #expect(entry?.factoryInstructions == "the factory")
    }

    @Test func migrateV2ToV3_cyclesNonBluePalette() {
        // Five user templates exhaust the first five non-blue swatches in
        // declared order. The migration must NOT reuse the factory blue
        // — the cycling guarantees user-tab/sidebar visual distinction
        // from launch.
        let legacy = (0..<5).map { i in
            LegacyTemplateV2(
                id: UUID(),
                name: "T\(i)",
                instructions: "body \(i)",
                factoryInstructions: nil
            )
        }
        let migrated = PromptStore.migrateV2ToV3(legacy)
        #expect(migrated.map(\.colorHex) == [
            "#5E5CE6", "#FF9F0A", "#30D158", "#FF453A", "#BF5AF2"
        ])
        // Every entry should be sparkle-iconed by default.
        for entry in migrated {
            #expect(entry.iconName == "sparkle")
        }
    }

    @Test func init_migratesV2DataAndClearsLegacyKey() throws {
        // Simulate a v2 install: write the legacy `templates.v2` blob,
        // then construct a fresh PromptStore against the same defaults.
        // After init: `templates.v3` must be present, `templates.v2`
        // gone, and the in-memory templates carry the v3 fields.
        let scratch = ScratchDefaults.make()
        defer { scratch.cleanup() }
        let factoryID = UUID()
        let userID = UUID()
        let legacy: [LegacyTemplateV2] = [
            LegacyTemplateV2(
                id: factoryID,
                name: "Grammar",
                instructions: PromptStore.defaultInstructions,
                factoryInstructions: PromptStore.defaultInstructions
            ),
            LegacyTemplateV2(
                id: userID,
                name: "Friendly",
                instructions: "warm",
                factoryInstructions: nil
            ),
        ]
        let v2Data = try JSONEncoder().encode(legacy)
        scratch.defaults.set(v2Data, forKey: "templates.v2")

        let store = Self.makeStore(scratch)
        #expect(store.templates.count == 2)
        #expect(store.templates[0].id == factoryID)
        #expect(store.templates[0].colorHex == "#0A84FF")
        #expect(store.templates[0].iconName == "pencil")
        #expect(store.templates[1].id == userID)
        #expect(store.templates[1].colorHex == "#5E5CE6")
        #expect(store.templates[1].iconName == "sparkle")

        // Persistence sides match: v3 written, v2 cleared.
        #expect(scratch.defaults.data(forKey: "templates.v3") != nil)
        #expect(scratch.defaults.data(forKey: "templates.v2") == nil)
    }
}
