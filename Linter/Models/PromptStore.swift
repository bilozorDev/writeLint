import Foundation
import Observation

/// Which backend is currently servicing lint requests. Used as both the
/// derived `activeBackend` value and the user-pickable `selectedBackend`
/// stored in `PromptStore`. `String` raw values let us persist + use in
/// `Picker`; `CaseIterable + Identifiable` let SwiftUI iterate cleanly.
enum LintBackend: String, Equatable, CaseIterable, Identifiable {
    case onDevice
    case claude
    case openai

    var id: String { rawValue }
}

/// Which cloud provider the user has selected in Advanced Mode. The
/// active backend is `.onDevice` until both (a) Advanced Mode is on AND
/// (b) the selected provider has a Keychain-stored API key.
enum CloudProvider: String, CaseIterable, Identifiable {
    case claude
    case openai
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        }
    }
}

/// Available Claude models for the cloud backend. `rawValue` is the model
/// identifier sent in the Anthropic Messages API request body.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku45 = "claude-haiku-4-5"
    case sonnet46 = "claude-sonnet-4-6"
    case opus47 = "claude-opus-4-7"

    var id: String { rawValue }

    /// Human-friendly label shown in the Settings picker and the footer.
    var displayName: String {
        switch self {
        case .haiku45: return "Claude Haiku 4.5"
        case .sonnet46: return "Claude Sonnet 4.6"
        case .opus47: return "Claude Opus 4.7"
        }
    }

    /// Short label used in the in-panel footer alongside "Cloud · …".
    var footerLabel: String {
        switch self {
        case .haiku45: return "Haiku 4.5"
        case .sonnet46: return "Sonnet 4.6"
        case .opus47: return "Opus 4.7"
        }
    }

    /// Whether this model accepts `output_config.effort`. Sending it to a
    /// model that doesn't support it (Haiku 4.5) returns a 400. Sonnet 4.6,
    /// Opus 4.6, and Opus 4.7 all accept it. Grammar polishing is a short,
    /// scoped task — when the model supports effort, the Claude backend
    /// sends `"low"` to minimize latency and token usage.
    var supportsEffort: Bool {
        switch self {
        case .haiku45: return false
        case .sonnet46, .opus47: return true
        }
    }
}

/// Available OpenAI models for the cloud backend. `rawValue` is the model
/// identifier sent in the Chat Completions API request body. Default is
/// `gpt-4.1-mini` — fast, cheap, plenty for grammar polishing.
enum OpenAIModel: String, CaseIterable, Identifiable {
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41 = "gpt-4.1"
    case gpt5 = "gpt-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt41Mini: return "GPT-4.1 mini"
        case .gpt41: return "GPT-4.1"
        case .gpt5: return "GPT-5"
        }
    }

    var footerLabel: String {
        switch self {
        case .gpt41Mini: return "GPT-4.1 mini"
        case .gpt41: return "GPT-4.1"
        case .gpt5: return "GPT-5"
        }
    }
}

/// One named prompt the user can swap between. The full system message
/// the model receives is `instructions` — examples, rules, the lot. There
/// is no schema-side or transcript-side injection layered on top; what
/// you see here is what the model sees.
///
/// `factoryInstructions` is non-nil for built-in templates that ship with
/// the app (today: just "Grammar"). User-created templates get `nil`, so
/// the Settings UI hides the Revert button for them.
struct Template: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var instructions: String
    var factoryInstructions: String?

    /// True when this template's body equals its shipped factory text.
    /// User-created templates (`factoryInstructions == nil`) always
    /// return false — there's no factory to compare against, and the
    /// Revert button is hidden for them anyway.
    var isAtFactory: Bool {
        factoryInstructions.map { $0 == instructions } ?? false
    }
}

/// Single source of truth for the LLM prompts and the user-facing
/// "Advanced Mode" toggle.
///
/// Design notes:
/// - The user maintains a list of named templates (`templates`). Exactly
///   one is active at a time (`selectedTemplateID`). The legacy
///   single-prompt API (`var instructions: String`) is preserved as a
///   writable computed property so backends, the lint pipeline, and
///   tests don't need to know there are multiple templates.
/// - `activeTemplate.instructions` is the *complete* text the model
///   receives. Examples, rules, and constraints all live in this one
///   string per-template. Nothing is mixed in from code at request time.
@Observable
@MainActor
final class PromptStore {
    private static let templatesKey          = "templates.v2"
    private static let selectedTemplateIDKey = "selectedTemplateID.v2"
    private static let legacyInstructionsKey = "grammarPrompt.v1"
    private static let advancedModeKey       = "advancedMode.v1"
    private static let claudeModelKey        = "claudeModel.v1"
    private static let openaiModelKey        = "openaiModel.v1"
    private static let providerKey           = "cloudProvider.v1"
    private static let backendKey            = "selectedBackend.v1"

    private let defaults: UserDefaults
    private let keychainService: String
    private let claudeAccount: String
    private let openaiAccount: String

    /// Ordered list of templates. The first entry is always the seeded
    /// Grammar template (or a v1-migrated descendant of it). New
    /// user-created templates append to the end.
    var templates: [Template] {
        didSet { persistTemplates() }
    }

    /// Which template is active for the next lint and which body the
    /// `instructions` computed reads/writes. Self-heals on init if the
    /// stored UUID doesn't match any current template.
    var selectedTemplateID: UUID {
        didSet {
            defaults.set(selectedTemplateID.uuidString, forKey: Self.selectedTemplateIDKey)
        }
    }

    /// The active template. Defensive `?? templates[0]` fallback exists
    /// only to satisfy the type system; the `precondition` in `init`
    /// guarantees `templates` is never empty, and `deleteTemplate`
    /// no-ops on the last template, so the fallback should never fire.
    var activeTemplate: Template {
        templates.first(where: { $0.id == selectedTemplateID }) ?? templates[0]
    }

    /// Legacy single-prompt API, preserved as a writable computed
    /// property so existing call sites in `LinterWindow`,
    /// `FoundationModelService`, `ClaudeBackend`, `OpenAIBackend`, and
    /// the test target keep working unchanged. Get returns the active
    /// template's body; set routes through `setInstructions(_:for:)`
    /// keyed on `selectedTemplateID` at call time.
    var instructions: String {
        get { activeTemplate.instructions }
        set { setInstructions(newValue, for: selectedTemplateID) }
    }

    /// When true, Settings reveals the prompt editor and Revert button.
    /// Off by default — most users never see the prompt.
    var advancedMode: Bool {
        didSet { defaults.set(advancedMode, forKey: Self.advancedModeKey) }
    }

    /// Which provider's config section the user is editing in Settings.
    /// UI-only state — driving the segmented Picker that toggles the
    /// Claude vs OpenAI key/model pane. Independent of `selectedBackend`
    /// so the user can configure OpenAI without flipping the active
    /// backend off Claude.
    var selectedProvider: CloudProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Self.providerKey) }
    }

    /// User's chosen backend — what the next lint runs against. Driven by
    /// the in-panel footer Menu and persisted across launches. Distinct
    /// from `activeBackend`: that's a *derivation* that falls back to
    /// `.onDevice` when the picked backend is unreachable (e.g. selected
    /// `.claude` but the key was removed).
    var selectedBackend: LintBackend {
        didSet { defaults.set(selectedBackend.rawValue, forKey: Self.backendKey) }
    }

    /// Currently-selected Claude model. Only consulted when
    /// `activeBackend == .claude`.
    var selectedClaudeModel: ClaudeModel {
        didSet { defaults.set(selectedClaudeModel.rawValue, forKey: Self.claudeModelKey) }
    }

    /// Currently-selected OpenAI model. Only consulted when
    /// `activeBackend == .openai`. Default is `gpt-4.1-mini` — fast, cheap,
    /// plenty for grammar polishing.
    var selectedOpenAIModel: OpenAIModel {
        didSet { defaults.set(selectedOpenAIModel.rawValue, forKey: Self.openaiModelKey) }
    }

    /// Cached "is an Anthropic API key present in the Keychain?" flag. The
    /// canonical value lives in the Keychain; this property mirrors it so
    /// SwiftUI views observing `activeBackend` get a re-render when the user
    /// adds or removes the key. Mutated only by `setClaudeKey(_:)` and
    /// `clearClaudeKey()` — read-only from outside.
    private(set) var hasClaudeKey: Bool

    /// Cached "is an OpenAI API key present in the Keychain?" flag. Same
    /// shape as `hasClaudeKey` — observable mirror of the Keychain state,
    /// updated only by `setOpenAIKey(_:)` / `clearOpenAIKey()`.
    private(set) var hasOpenAIKey: Bool

    /// Active backend — what runs on the next lint. Derives from
    /// `selectedBackend` with a *reachability* check: the user's pick
    /// stands as long as the matching API key is present. If the key was
    /// removed from another machine or via the Remove button without
    /// updating the backend choice, `activeBackend` quietly falls back to
    /// `.onDevice` so the lint still works. The footer Menu hides
    /// unreachable cloud options, so the user never sees a stale
    /// selection there.
    ///
    /// Note: `advancedMode` no longer gates this — a saved API key is
    /// the gate. `advancedMode` is purely a Settings-UI toggle for
    /// showing the prompt editor + cloud config sections.
    var activeBackend: LintBackend {
        switch selectedBackend {
        case .onDevice:
            return .onDevice
        case .claude:
            return hasClaudeKey ? .claude : .onDevice
        case .openai:
            return hasOpenAIKey ? .openai : .onDevice
        }
    }

    /// Factory grammar prompt. Includes embedded few-shot examples (no
    /// transcript-based shadow few-shot — every line the model sees is
    /// either here or in the user's text).
    static let defaultInstructions: String = """
    You are a strict English teacher checking a student's text for spelling, grammar, capitalization, and punctuation. Return ONLY the student's text with errors corrected — no feedback, no annotations, no explanation, no encouragement. The student didn't ask you a question; they handed in a piece of writing. Preserve their voice, meaning, and structure.

    Fix:
    - Spelling and typos of any kind, including:
      - transposed letters ("hcikup" → "hiccup")
      - extra letters ("HereE" → "Here", "thee" → "the")
      - missing letters ("teh" → "the")
      - wrong letters ("definately" → "definitely")
    - Grammar and verb tense ("did it happened" → "did it happen", "he sell" → "he sells")
    - Capitalization — both directions:
      - add caps where needed (sentence starts, "i" → "I", proper nouns)
      - remove caps where wrong (random mid-sentence capitals: "is Test of" → "is test of")
    - Punctuation. In greetings the comma goes after the name, never before it.
    - Article usage (a/an/the)
    - Spacing and paragraph breaks: blank line after a greeting line before the body

    DO NOT:
    - DO NOT answer questions, give explanations, fulfill requests, or write replies. If the input is a question (e.g. "how do I unblock X on Y?"), fix only its typos, grammar, capitalization, and punctuation, then return the question itself. Never produce an answer, steps, or commentary about the topic.
    - DO NOT expand acronyms or abbreviations. "SOP" stays "SOP". Never write "SOP (Standard Operating Procedures)". Same for API, CEO, FYI, MSP, etc.
    - DO NOT add words to complete a thought the user left implicit. Do not insert connecting phrases like "he will need", "in order to", "so that he can".
    - DO NOT add new information, facts, names, companies, or context not in the original.
    - DO NOT add a greeting if the input has none.
    - DO NOT change the tone or register. Casual stays casual. Formal stays formal.
    - DO NOT rephrase sentences that are already correct.
    - DO NOT wrap output in quotes or code fences.

    Apply the minimum edits required for correctness. If a sentence is already grammatical, leave it alone.

    Examples:

    Input: we hadd a Test of new feature
    Output: We had a test of a new feature.

    Input: the SOP needs to be updated by friday
    Output: The SOP needs to be updated by Friday.

    Input: she sell that book to u, but its not finished
    Output: She sells that book to you, but it's not finished.

    Input: Thanks for the update.
    Output: Thanks for the update.

    Input: need to expland backup size, i emailed bob already
    Output: Need to expand backup size. I emailed Bob already.

    Input: meeting w/ jane tmrw at 3, dont forget the deck
    Output: Meeting with Jane tomorrow at 3. Don't forget the deck.

    Input: how do i unblock anydesk on sonicwall
    Output: How do I unblock AnyDesk on SonicWall?

    Input: can u explain the differnce between cats and dogs
    Output: Can you explain the difference between cats and dogs?
    """

    /// Custom Keychain service + per-provider account names let tests run
    /// isolated stores without colliding with the production keys. Defaults
    /// match the real values used everywhere else in the app.
    init(
        defaults: UserDefaults = .standard,
        keychainService: String = Keychain.service,
        claudeAccount: String = Keychain.anthropicAccount,
        openaiAccount: String = Keychain.openaiAccount
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.claudeAccount = claudeAccount
        self.openaiAccount = openaiAccount

        // Templates: load v2, else migrate from grammarPrompt.v1, else
        // seed default. `templates.v2` always wins when both v2 and v1
        // exist (downgrade-replay scenario: v1 doesn't touch v2 keys, so
        // v2 data survives a v1 round-trip; v1-era edits made between
        // round-trips are intentionally dropped on the second v2 launch).
        let loadedTemplates: [Template]
        if let data = defaults.data(forKey: Self.templatesKey),
           let decoded = try? JSONDecoder().decode([Template].self, from: data),
           !decoded.isEmpty {
            loadedTemplates = decoded
        } else {
            let legacy = defaults.string(forKey: Self.legacyInstructionsKey)
            let seedInstructions: String
            if let legacy, !legacy.isEmpty, legacy != Self.defaultInstructions {
                seedInstructions = legacy
            } else {
                seedInstructions = Self.defaultInstructions
            }
            let grammar = Template(
                id: UUID(),
                name: "Grammar",
                instructions: seedInstructions,
                factoryInstructions: Self.defaultInstructions
            )
            loadedTemplates = [grammar]
            if let data = try? JSONEncoder().encode(loadedTemplates) {
                defaults.set(data, forKey: Self.templatesKey)
            }
        }
        self.templates = loadedTemplates
        // Always remove the legacy key — including in the v2-already-present
        // path, so a stray v1 key from a v1 round-trip gets cleaned up.
        defaults.removeObject(forKey: Self.legacyInstructionsKey)

        // Selected template ID: load v2 if present and matches a template,
        // else first. Self-healing covers the rare race where `templates`
        // and `selectedTemplateID` `didSet` writes were interrupted between
        // calls.
        let resolvedSelected: UUID
        if let raw = defaults.string(forKey: Self.selectedTemplateIDKey),
           let id = UUID(uuidString: raw),
           loadedTemplates.contains(where: { $0.id == id }) {
            resolvedSelected = id
        } else {
            resolvedSelected = loadedTemplates[0].id
            defaults.set(resolvedSelected.uuidString, forKey: Self.selectedTemplateIDKey)
        }
        self.selectedTemplateID = resolvedSelected
        precondition(!loadedTemplates.isEmpty, "PromptStore.templates must never be empty after init")

        // Locals named `initial*` to avoid shadowing the corresponding
        // stored properties — Swift requires every stored property to
        // be initialized before `self` is usable, so the migration block
        // below has to read these values from locals rather than from
        // `self.advancedMode` / `self.hasClaudeKey` etc.
        let initialAdvancedMode = defaults.bool(forKey: Self.advancedModeKey)
        self.advancedMode = initialAdvancedMode
        if let raw = defaults.string(forKey: Self.providerKey),
           let provider = CloudProvider(rawValue: raw) {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .claude
        }
        if let raw = defaults.string(forKey: Self.claudeModelKey),
           let model = ClaudeModel(rawValue: raw) {
            self.selectedClaudeModel = model
        } else {
            self.selectedClaudeModel = .haiku45
        }
        if let raw = defaults.string(forKey: Self.openaiModelKey),
           let model = OpenAIModel(rawValue: raw) {
            self.selectedOpenAIModel = model
        } else {
            self.selectedOpenAIModel = .gpt41Mini
        }
        let initialClaudeKey = (Keychain.get(service: keychainService, account: claudeAccount) != nil)
        let initialOpenAIKey = (Keychain.get(service: keychainService, account: openaiAccount) != nil)
        self.hasClaudeKey = initialClaudeKey
        self.hasOpenAIKey = initialOpenAIKey

        self.selectedBackend = Self.resolveInitialBackend(
            defaults: defaults,
            advancedMode: initialAdvancedMode,
            hasClaudeKey: initialClaudeKey,
            hasOpenAIKey: initialOpenAIKey
        )

        // One-time cleanup of orphaned keys from a different earlier
        // multi-template build. The schema there was incompatible with
        // v2; just drop the keys. `removeObject` on a missing key is
        // harmless, so this is also a no-op for fresh installs and on
        // every subsequent launch.
        defaults.removeObject(forKey: "templates.v1")
        defaults.removeObject(forKey: "selectedTemplateID.v1")
    }

    /// Decides what `selectedBackend` should be at init time. New installs
    /// (no `selectedBackend.v1` key) default to `.onDevice`. Users
    /// upgrading from the previous schema (where `advancedMode +
    /// cloudProvider.v1` was the activation gate) get their effective
    /// pre-upgrade backend preserved: if they had advancedMode on with a
    /// cloud provider selected and that provider's key in the Keychain,
    /// they stay on cloud; otherwise on-device.
    ///
    /// Static + parameter-driven so it can be unit-tested without
    /// constructing a full `PromptStore`. Called from init only — once
    /// the v2 key is written, subsequent loads bypass the migration
    /// branch via the explicit `defaults.string(forKey: backendKey)`
    /// check.
    private static func resolveInitialBackend(
        defaults: UserDefaults,
        advancedMode: Bool,
        hasClaudeKey: Bool,
        hasOpenAIKey: Bool
    ) -> LintBackend {
        if let raw = defaults.string(forKey: Self.backendKey),
           let backend = LintBackend(rawValue: raw) {
            return backend
        }
        guard advancedMode,
              let raw = defaults.string(forKey: Self.providerKey),
              let cp = CloudProvider(rawValue: raw) else {
            return .onDevice
        }
        switch cp {
        case .claude: return hasClaudeKey ? .claude : .onDevice
        case .openai: return hasOpenAIKey ? .openai : .onDevice
        }
    }

    // MARK: - Template CRUD

    /// Switch the active template by ID. No-ops if `id` doesn't match any
    /// current template — defensive, since the only public way to get an
    /// ID is to read one off `templates`, but `setSelectedID` paths from
    /// stale view state could pass an old UUID.
    func selectTemplate(id: UUID) {
        guard templates.contains(where: { $0.id == id }) else { return }
        selectedTemplateID = id
    }

    /// Switch the active template by zero-based index (so ⌘1 → 0). Silent
    /// no-op when out of range, which is how ⌘5 with 2 templates becomes
    /// a no-op without the call site needing to know the count.
    func selectTemplate(at index: Int) {
        guard templates.indices.contains(index) else { return }
        selectedTemplateID = templates[index].id
    }

    /// Append a new user-created template and select it. Returns the new
    /// UUID so the caller can drive focus (e.g. the Settings name field).
    /// The default name auto-numbers to avoid collisions; callers wanting
    /// a specific name should pass it explicitly. The `instructions`
    /// parameter has no implicit default — Settings creates templates
    /// via a draft + Save flow, so the body is always supplied
    /// explicitly. The submit-time empty-instructions guard in
    /// `LinterWindow.submit()` catches the case where a user manually
    /// clears a saved template's body.
    @discardableResult
    func addTemplate(
        name: String? = nil,
        instructions: String
    ) -> UUID {
        let resolvedName = name ?? Self.defaultNameForNewTemplate(in: templates)
        let t = Template(
            id: UUID(),
            name: resolvedName,
            instructions: instructions,
            factoryInstructions: nil
        )
        templates.append(t)
        selectedTemplateID = t.id
        return t.id
    }

    /// Compute the default name for a new template, picking the smallest
    /// integer suffix not already in use. "New template" if untaken, else
    /// "New template 2", "New template 3", and so on.
    static func defaultNameForNewTemplate(in existing: [Template]) -> String {
        let base = "New template"
        let names = Set(existing.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Remove a template. No-ops on the last remaining template — there
    /// must always be at least one for the active-template invariant to
    /// hold. If the deleted template was selected, selection moves to
    /// the previous index (or `templates[0]` if we were at index 0).
    func deleteTemplate(id: UUID) {
        guard templates.count > 1 else { return }
        guard let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        templates.remove(at: idx)
        if selectedTemplateID == id {
            selectedTemplateID = templates[max(0, idx - 1)].id
        }
    }

    /// Rename a template. Trims surrounding whitespace; if the trimmed
    /// result is empty, the rename is silently rejected (preserves the
    /// previous name). Duplicates are allowed by design — the slash
    /// popup matches in declared order, and ⌘N hints by position.
    func renameTemplate(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[idx].name = trimmed
    }

    /// Update a template's body. Silent no-op if `id` doesn't match —
    /// the writable computed `instructions` setter routes here using
    /// `selectedTemplateID`, which is always valid.
    func setInstructions(_ text: String, for id: UUID) {
        guard let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[idx].instructions = text
    }

    /// Reset a template's body to its shipped factory text. Only
    /// meaningful for built-in templates (those with non-nil
    /// `factoryInstructions`); silently no-ops for user-created ones.
    /// The Settings UI hides the Revert button for templates without a
    /// factory, so this guard is defense-in-depth.
    func revertTemplateToFactory(id: UUID) {
        guard let idx = templates.firstIndex(where: { $0.id == id }),
              let factory = templates[idx].factoryInstructions else { return }
        templates[idx].instructions = factory
    }

    private func persistTemplates() {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.templatesKey)
        }
    }

    // MARK: - Cloud keys

    /// Persist `key` to the Keychain and flip `hasClaudeKey` so observers
    /// (the footer, the activeBackend-driven router) re-render. Throws on
    /// underlying Keychain failure — the Settings UI surfaces it as an
    /// inline error.
    ///
    /// Auto-switches `selectedBackend` to `.claude` *only* when the user
    /// is currently on `.onDevice`. Saving a Claude key while OpenAI is
    /// already active is treated as registering a backup — the active
    /// backend stays put. Without the narrowing, a user adding a second
    /// key would silently change which provider runs their next lint.
    func setClaudeKey(_ key: String) throws {
        try Keychain.set(key, service: keychainService, account: claudeAccount)
        hasClaudeKey = true
        if selectedBackend == .onDevice {
            selectedBackend = .claude
        }
    }

    /// Read the stored Claude key. Used by `ClaudeBackend` at request time
    /// so the key never sits in memory between lints — and so a change in
    /// Settings is picked up on the very next request without needing to
    /// thread it through the call.
    func currentClaudeKey() -> String? {
        Keychain.get(service: keychainService, account: claudeAccount)
    }

    /// Remove the stored Claude key. If Claude was the active backend,
    /// fall back to `.onDevice` so `selectedBackend` doesn't dangle on a
    /// provider with no key (the footer would auto-coerce, but stale
    /// state is still confusing).
    func clearClaudeKey() throws {
        try Keychain.clear(service: keychainService, account: claudeAccount)
        hasClaudeKey = false
        if selectedBackend == .claude {
            selectedBackend = .onDevice
        }
    }

    /// Persist `key` to the Keychain and flip `hasOpenAIKey`. Same shape
    /// as `setClaudeKey` — separate account namespace under the same
    /// service so both providers' keys can coexist. Same auto-switch
    /// narrowing: only flip the active backend when currently on
    /// `.onDevice`.
    func setOpenAIKey(_ key: String) throws {
        try Keychain.set(key, service: keychainService, account: openaiAccount)
        hasOpenAIKey = true
        if selectedBackend == .onDevice {
            selectedBackend = .openai
        }
    }

    /// Read the stored OpenAI key. Used by `OpenAIBackend` at request time
    /// for the same reasons as `currentClaudeKey()`.
    func currentOpenAIKey() -> String? {
        Keychain.get(service: keychainService, account: openaiAccount)
    }

    /// Remove the stored OpenAI key. If OpenAI was the active backend,
    /// fall back to `.onDevice` (matching the Claude-side semantics).
    func clearOpenAIKey() throws {
        try Keychain.clear(service: keychainService, account: openaiAccount)
        hasOpenAIKey = false
        if selectedBackend == .openai {
            selectedBackend = .onDevice
        }
    }
}
