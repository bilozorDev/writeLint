import Testing
import Foundation
@testable import Write_Lint

@Suite("Keychain helper — round-trip set/get/clear")
struct KeychainTests {
    /// Each test gets a unique service identifier so the production key
    /// (under `Keychain.anthropicService`) is never touched, and so parallel
    /// runs of these tests don't collide with each other.
    private static func uniqueService() -> String {
        "linter.tests.keychain.\(UUID().uuidString)"
    }

    @Test func setThenGetReturnsStoredValue() throws {
        let service = Self.uniqueService()
        let account = "test"
        defer { try? Keychain.clear(service: service, account: account) }

        try Keychain.set("sk-test-abc", service: service, account: account)
        #expect(Keychain.get(service: service, account: account) == "sk-test-abc")
    }

    @Test func setOverwritesExistingValue() throws {
        let service = Self.uniqueService()
        let account = "test"
        defer { try? Keychain.clear(service: service, account: account) }

        try Keychain.set("first", service: service, account: account)
        try Keychain.set("second", service: service, account: account)
        #expect(Keychain.get(service: service, account: account) == "second")
    }

    @Test func clearRemovesValue() throws {
        let service = Self.uniqueService()
        let account = "test"

        try Keychain.set("to-be-cleared", service: service, account: account)
        try Keychain.clear(service: service, account: account)
        #expect(Keychain.get(service: service, account: account) == nil)
    }

    @Test func clearOnMissingKeyIsNoOp() throws {
        // Clearing a never-set key must not throw — used by the Settings UI
        // to ensure the slot is empty before storing a new value.
        let service = Self.uniqueService()
        try Keychain.clear(service: service, account: "never-set")
    }

    @Test func getOnMissingKeyReturnsNil() {
        let service = Self.uniqueService()
        #expect(Keychain.get(service: service, account: "never-set") == nil)
    }

    @Test func roundTripUnicodeAndPunctuationSurvive() throws {
        let service = Self.uniqueService()
        let account = "test"
        defer { try? Keychain.clear(service: service, account: account) }

        let weird = "sk-ant-Α–β=⌘\nfoo"
        try Keychain.set(weird, service: service, account: account)
        #expect(Keychain.get(service: service, account: account) == weird)
    }
}
