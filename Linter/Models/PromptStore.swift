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

/// Single source of truth for the LLM prompt and the user-facing
/// "Advanced Mode" toggle.
///
/// Design notes:
/// - There is exactly one prompt — the grammar-and-punctuation system
///   instruction — sent to the on-device model. There used to be a multi-
///   template UI; that's been removed in favor of a single prompt the user
///   can see and edit when Advanced Mode is on.
/// - `instructions` is the *complete* text the model receives. Examples,
///   rules, and constraints all live in this one string. Nothing is mixed
///   in from code at request time. That's the rule the user asked for:
///   "all LLM instructions coming from it [the prompt], not hidden in our
///   code."
@Observable
@MainActor
final class PromptStore {
    private static let instructionsKey = "grammarPrompt.v1"
    private static let advancedModeKey = "advancedMode.v1"
    private static let claudeModelKey  = "claudeModel.v1"
    private static let openaiModelKey  = "openaiModel.v1"
    private static let providerKey     = "cloudProvider.v1"
    private static let backendKey      = "selectedBackend.v1"

    private let defaults: UserDefaults
    private let keychainService: String
    private let claudeAccount: String
    private let openaiAccount: String

    /// The full system prompt sent to the on-device model. Editable by the
    /// user when Advanced Mode is enabled in Settings.
    var instructions: String {
        didSet { defaults.set(instructions, forKey: Self.instructionsKey) }
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
        let stored = defaults.string(forKey: Self.instructionsKey)
        if let stored, !stored.isEmpty {
            self.instructions = stored
        } else {
            self.instructions = Self.defaultInstructions
        }
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

        // One-time cleanup of orphaned keys from the multi-template build.
        // No-op once removed — `removeObject` on a missing key is harmless,
        // so we don't need a "did-clean-up" flag.
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

    /// Restore the factory grammar prompt. The Settings UI confirms before
    /// calling this so the user can't lose customizations accidentally.
    func revertToDefault() {
        instructions = Self.defaultInstructions
    }

    var isAtDefault: Bool {
        instructions == Self.defaultInstructions
    }
}
