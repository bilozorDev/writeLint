import Foundation
import Observation

struct FewShotExample: Codable, Equatable, Hashable {
    var input: String
    var output: String
}

struct Template: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var icon: String
    var colorHex: String
    var instructions: String
    /// Optional user/assistant example pairs replayed before the user's text.
    /// Helps the model learn the exact style of correction we want for the
    /// template (e.g. "SOP stays SOP, no parenthetical expansion").
    var fewShot: [FewShotExample]?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, colorHex, instructions, fewShot
    }

    init(id: String, name: String, icon: String, colorHex: String, instructions: String, fewShot: [FewShotExample]? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.instructions = instructions
        self.fewShot = fewShot
    }

    init(from decoder: Decoder) throws {
        // Custom decode so older persisted templates (no `fewShot` key) keep
        // working. Defaults missing fewShot to nil.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        instructions = try c.decode(String.self, forKey: .instructions)
        fewShot = try c.decodeIfPresent([FewShotExample].self, forKey: .fewShot)
    }
}

extension Template {
    /// The single template the app guarantees always exists. Cannot be deleted
    /// from the UI; if it's missing on load (e.g. user wiped persisted state),
    /// `TemplateStore` re-injects it from `Template.defaults`.
    static let grammarID = "grammar"

    /// Past `instructions` strings for the grammar template that should be
    /// auto-migrated to the current default on launch. We migrate only when
    /// the stored value matches verbatim — if the user customized the prompt
    /// themselves, their changes are preserved.
    static let grammarLegacyInstructions: [String] = [
        "You are an English teacher that checks grammar and punctuation. Don't modify text meaning, only apply grammar corrections and punctuation. Reply with only the corrected text — no preamble, no explanation.",
        // Prior prompt with embedded examples — replaced by the new
        // strict-NEVER prompt + transcript-based few-shot.
        """
        You are a text polisher. Fix spelling, grammar, punctuation, capitalization, and spacing in the user's text while preserving their exact meaning and voice.

        Specific rules:
        - Greetings: comma after the name, not before ("Hey, Katie" → "Hey Katie,")
        - Insert a blank line between a greeting line and the body
        - Fix verb tense after did/does/do (use base form: "did it happened" → "did it happen")
        - Add articles (a/an/the) where grammatically required
        - Hyphenate compound modifiers before nouns ("one time hiccup" → "a one-time hiccup")
        - Fix typos and capitalization (sentence starts, "i" → "I", proper nouns)

        Hard constraints:
        - NEVER add information, context, names, companies, or details that aren't in the original. If the source ends at "hiccup", the output ends at "hiccup." — never extend with invented context.
        - NEVER change the tone or register (casual stays casual, formal stays formal).
        - NEVER rewrite sentences that are already correct.
        - NEVER add preamble, explanation, or wrap the output in quotes or code fences.
        - Output only the polished text.

        Examples:

        Input:
        Hey, Katie
        Did it happened since last week? maybe it was one time hcikup

        Output:
        Hey Katie,

        Did it happen since last week? Maybe it was a one-time hiccup.

        Input:
        thanks for the help

        Output:
        Thanks for the help.

        Input:
        lol that's wild

        Output:
        lol that's wild
        """
    ]

    static let defaults: [Template] = [
        Template(
            id: grammarID,
            name: "Grammar & Punctuation",
            icon: "pencil",
            colorHex: "#0A84FF",
            instructions: """
            You are a text polisher. Rewrite the user's text to be clean and natural while preserving their voice, meaning, and structure.

            Fix:
            - Spelling and typos
            - Grammar and verb tense (e.g., "did it happened" → "did it happen", "he sell" → "he sells")
            - Punctuation, including comma placement around names in greetings ("Hey, Katie" → "Hey Katie,")
            - Capitalization (sentence starts, "i" → "I", proper nouns)
            - Article usage (a/an/the) where grammatically required
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
            """,
            fewShot: [
                FewShotExample(
                    input: "Hey, Katie\nDid it happened since last week? maybe it was one time hcikup",
                    output: "Hey Katie,\n\nDid it happen since last week? Maybe it was a one-time hiccup."
                ),
                FewShotExample(
                    input: "And u know most important to have SOP? When he sell company to show them all the documentation's",
                    output: "And you know, most importantly, to have SOPs? When he sells the company to show them all the documentation."
                ),
                FewShotExample(
                    input: "Thanks for the update — I'll review it tomorrow.",
                    output: "Thanks for the update — I'll review it tomorrow."
                )
            ]
        ),
        Template(
            id: "spelling",
            name: "Fix Spelling",
            icon: "checkmark.seal",
            colorHex: "#FF9F0A",
            instructions: "Fix only spelling mistakes. Do not change grammar, punctuation, word choice, or tone. Reply with only the corrected text — no preamble, no explanation."
        ),
        Template(
            id: "professional",
            name: "Professional Tone",
            icon: "briefcase",
            colorHex: "#5E5CE6",
            instructions: "Rewrite the text in a polished, professional tone suitable for business communication. Keep the meaning intact. Avoid jargon and filler words. Reply with only the rewritten text — no preamble, no explanation."
        ),
        Template(
            id: "casual",
            name: "Casual & Friendly",
            icon: "hand.wave",
            colorHex: "#30D158",
            instructions: "Rewrite the text in a casual, warm, friendly tone — like talking to a friend. Use contractions. Keep it natural, not corporate. Reply with only the rewritten text — no preamble, no explanation."
        )
    ]
}

@Observable
final class TemplateStore {
    private static let templatesKey = "templates.v1"
    private static let selectedKey = "selectedTemplateID.v1"

    var templates: [Template] {
        didSet { persist() }
    }

    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.selectedKey) }
    }

    var selected: Template {
        templates.first(where: { $0.id == selectedID }) ?? templates.first ?? Template.defaults[0]
    }

    init() {
        let defaults = UserDefaults.standard
        var loaded: [Template]
        if let data = defaults.data(forKey: Self.templatesKey),
           let decoded = try? JSONDecoder().decode([Template].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = Template.defaults
        }

        // Guarantee the Grammar template always exists.
        if !loaded.contains(where: { $0.id == Template.grammarID }),
           let canonicalGrammar = Template.defaults.first(where: { $0.id == Template.grammarID }) {
            loaded.insert(canonicalGrammar, at: 0)
        }

        // Auto-migrate any legacy grammar instructions to the current default.
        // Only when the stored value matches a known prior verbatim — user-
        // customized prompts are preserved.
        if let idx = loaded.firstIndex(where: { $0.id == Template.grammarID }),
           let canonical = Template.defaults.first(where: { $0.id == Template.grammarID }),
           Template.grammarLegacyInstructions.contains(loaded[idx].instructions) {
            loaded[idx].instructions = canonical.instructions
        }

        let storedSelected = defaults.string(forKey: Self.selectedKey) ?? Template.grammarID
        let resolvedSelected = loaded.contains(where: { $0.id == storedSelected })
            ? storedSelected
            : (loaded.first?.id ?? Template.grammarID)

        self.templates = loaded
        self.selectedID = resolvedSelected
    }

    func add(_ template: Template) {
        templates.append(template)
    }

    func update(_ template: Template) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else {
            assertionFailure("Tried to update template id=\(template.id) that isn't in the store.")
            return
        }
        templates[idx] = template
    }

    func delete(id: String) {
        // Grammar template is the app's anchor — never deletable.
        guard id != Template.grammarID else { return }
        templates.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = templates.first?.id ?? Template.grammarID
        }
        if templates.isEmpty {
            templates = Template.defaults
            selectedID = Template.grammarID
        }
    }

    func selectByIndex(_ index: Int) {
        guard templates.indices.contains(index) else { return }
        selectedID = templates[index].id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.templatesKey)
        }
    }
}
