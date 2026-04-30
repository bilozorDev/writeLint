import Foundation
import Observation

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

    /// The full system prompt sent to the on-device model. Editable by the
    /// user when Advanced Mode is enabled in Settings.
    var instructions: String {
        didSet { UserDefaults.standard.set(instructions, forKey: Self.instructionsKey) }
    }

    /// When true, Settings reveals the prompt editor and Revert button.
    /// Off by default — most users never see the prompt.
    var advancedMode: Bool {
        didSet { UserDefaults.standard.set(advancedMode, forKey: Self.advancedModeKey) }
    }

    /// Factory grammar prompt. Includes embedded few-shot examples (no
    /// transcript-based shadow few-shot — every line the model sees is
    /// either here or in the user's text).
    static let defaultInstructions: String = """
    You are a text polisher. Rewrite the user's text to be clean and natural while preserving their voice, meaning, and structure.

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

    NEVER:
    - Expand acronyms or abbreviations. "SOP" stays "SOP". Never write "SOP (Standard Operating Procedures)". Same for API, CEO, FYI, MSP, etc.
    - Add words to complete a thought the user left implicit. Do not insert connecting phrases like "he will need", "in order to", "so that he can".
    - Add new information, facts, names, companies, or context not in the original.
    - Add a greeting if the input has none.
    - Change the tone or register. Casual stays casual. Formal stays formal.
    - Rephrase sentences that are already correct.
    - Wrap output in quotes or code fences.

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
    """

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.instructionsKey)
        // One-time scrub: reject any stored prompt that still contains the
        // deprecated "Hey, Katie" example (the on-device model parrots it
        // into responses). After one launch the canonical doesn't include
        // the phrase, so this is idempotent.
        if let stored, !stored.isEmpty, !stored.contains("Hey, Katie") {
            self.instructions = stored
        } else {
            self.instructions = Self.defaultInstructions
        }
        self.advancedMode = UserDefaults.standard.bool(forKey: Self.advancedModeKey)
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
