import Foundation
import Observation

struct Template: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var icon: String
    var colorHex: String
    var instructions: String
}

extension Template {
    static let defaults: [Template] = [
        Template(
            id: "grammar",
            name: "Grammar & Punctuation",
            icon: "pencil",
            colorHex: "#0A84FF",
            instructions: "You are an English teacher that checks grammar and punctuation. Don't modify text meaning, only apply grammar corrections and punctuation. Reply with only the corrected text — no preamble, no explanation."
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
        let loaded: [Template]
        if let data = defaults.data(forKey: Self.templatesKey),
           let decoded = try? JSONDecoder().decode([Template].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = Template.defaults
        }
        let storedSelected = defaults.string(forKey: Self.selectedKey) ?? Template.defaults[0].id
        let resolvedSelected = loaded.contains(where: { $0.id == storedSelected })
            ? storedSelected
            : (loaded.first?.id ?? Template.defaults[0].id)

        self.templates = loaded
        self.selectedID = resolvedSelected
    }

    func add(_ template: Template) {
        templates.append(template)
    }

    func update(_ template: Template) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
    }

    func delete(id: String) {
        templates.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = templates.first?.id ?? Template.defaults[0].id
        }
        if templates.isEmpty {
            templates = Template.defaults
            selectedID = Template.defaults[0].id
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
