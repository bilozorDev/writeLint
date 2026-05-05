import Foundation
import Security

/// Tiny wrapper around the system Keychain for storing the Anthropic API key.
/// Sandboxed apps get their own per-app keychain access for free — no
/// access-group entitlement is needed unless we want to share the key with a
/// helper or extension, and we don't.
///
/// Items are stored as `kSecClassGenericPassword` under a fixed service /
/// account pair. `accessible` is `whenUnlocked` (not `afterFirstUnlock`)
/// because this is a foreground GUI app — there's never a reason to read the
/// key while the screen is locked.
///
/// All three operations are synchronous and main-thread-safe (Keychain calls
/// are quick and not actor-isolated). Errors are surfaced as a typed enum so
/// the UI can distinguish "no key" from "keychain refused" — most call sites
/// only need the optional convenience getter.
enum Keychain {
    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): return "Keychain error \(s)."
            case .decodingFailed: return "Keychain returned data we couldn't decode."
            }
        }
    }

    /// Shared service identifier for every key the app stores. Each provider
    /// gets its own `account` under this service, so adding a new backend
    /// (Anthropic, OpenAI, future) only requires another account constant —
    /// the underlying keychain entry is namespaced cleanly.
    ///
    /// `nonisolated` because the project's `SWIFT_DEFAULT_ACTOR_ISOLATION
    /// = MainActor` build setting would otherwise make these statics
    /// MainActor-isolated, which trips a warning at every call site
    /// using them as default arguments to non-MainActor functions (e.g.
    /// `PromptStore.init`'s defaults). They're plain string literals
    /// with no actor-relevant state, so nonisolated is the honest mark.
    nonisolated static let service = "Hexaget.WriteLint"
    nonisolated static let anthropicAccount = "anthropicAPIKey"
    nonisolated static let openaiAccount = "openaiAPIKey"

    /// Back-compat alias kept so existing call sites that read
    /// `Keychain.anthropicService` still compile during the rename. Prefer
    /// `Keychain.service` for new code.
    nonisolated static let anthropicService = service

    /// Persist `value` for the given service/account pair. Overwrites any
    /// existing value transparently.
    static func set(_ value: String, service: String = anthropicService, account: String = anthropicAccount) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.decodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        // Try update first; if nothing exists yet, fall through to add.
        let attributes: [String: Any] = [
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Returns the stored string, or nil if no entry exists. A keychain
    /// failure other than "not found" is logged-and-ignored at the call site
    /// via the convenience overload below; throwing variant is here for tests
    /// that want to assert on real errors.
    static func getThrowing(service: String = anthropicService, account: String = anthropicAccount) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Convenience: returns the stored string or nil. Swallows every
    /// keychain error — call sites that need to distinguish "no key" from
    /// "keychain refused" should use `getThrowing`.
    static func get(service: String = anthropicService, account: String = anthropicAccount) -> String? {
        try? getThrowing(service: service, account: account)
    }

    /// Removes the entry. No-op if it doesn't exist.
    static func clear(service: String = anthropicService, account: String = anthropicAccount) throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
