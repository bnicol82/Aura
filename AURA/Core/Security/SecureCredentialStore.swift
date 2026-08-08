import Foundation
import Security

/// A secret AURA may need to hold.
///
/// An enum rather than free-form strings so a typo cannot silently create a second, empty slot —
/// which would present as "the key I entered stopped working".
enum CredentialKey: String, CaseIterable, Sendable {
    case claudeAPIKey = "provider.anthropic.apiKey"
    case openAIAPIKey = "provider.openai.apiKey"
    /// Bearer token for a first-party backend, once one exists (§51).
    case auraBackendToken = "backend.aura.token"

    var displayName: String {
        switch self {
        case .claudeAPIKey: return "Claude API key"
        case .openAIAPIKey: return "OpenAI API key"
        case .auraBackendToken: return "AURA service token"
        }
    }
}

/// Keychain-backed storage for secrets (§51).
///
/// ### What belongs here and what does not
/// API keys, tokens, anything that grants access. Not memories, not the profile, not conversations —
/// those are SwiftData's job. Secrets must never be written to SwiftData or CloudKit records, where
/// they would be mirrored, backed up, and visible in a database browser.
///
/// ### On user-entered API keys
/// Supported for development, as §51 allows, and treated as exactly that. A shipping build should not
/// ask a person to paste a provider key into an app: the key is billable, unscoped, and unrevocable
/// from the device. The production shape is a token minted by a backend, which is why
/// `.auraBackendToken` exists alongside the raw keys. The UI that collects a key says so plainly.
protocol SecureCredentialStoring: Sendable {
    func store(_ secret: String, for key: CredentialKey) throws
    func secret(for key: CredentialKey) throws -> String?
    func hasSecret(for key: CredentialKey) -> Bool
    func delete(_ key: CredentialKey) throws
    /// Wipes every secret. Part of "Clear all assistant data" (§49).
    func deleteAll() throws
}

/// `SecureCredentialStoring` on top of the iOS Keychain.
struct KeychainCredentialStore: SecureCredentialStoring {

    /// Namespaces AURA's items so they cannot collide with another app's in a shared access group.
    private let service: String

    /// - Parameter service: keychain service name. Defaults to the bundle identifier.
    init(service: String? = nil) {
        self.service = service ?? (Bundle.main.bundleIdentifier ?? "com.aura.assistant")
    }

    func store(_ secret: String, for key: CredentialKey) throws {
        guard let data = secret.data(using: .utf8) else {
            throw AuraError.keychainFailure(status: errSecParam)
        }

        // Update-then-add rather than delete-then-add: a delete that succeeds followed by an add that
        // fails would leave the user with no key and no error they can act on.
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            AuraLog.security.info("Updated keychain item \(key.rawValue, privacy: .public)")
            return
        case errSecItemNotFound:
            var attributes = baseQuery(for: key)
            attributes[kSecValueData as String] = data
            // `afterFirstUnlock` rather than `whenUnlocked`: a background refresh or a scheduled
            // briefing needs the key while the device is locked.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                AuraLog.security.error("Keychain add failed: \(addStatus, privacy: .public)")
                throw AuraError.keychainFailure(status: addStatus)
            }
            AuraLog.security.info("Stored keychain item \(key.rawValue, privacy: .public)")
        default:
            AuraLog.security.error("Keychain update failed: \(updateStatus, privacy: .public)")
            throw AuraError.keychainFailure(status: updateStatus)
        }
    }

    func secret(for key: CredentialKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                return nil
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            AuraLog.security.error("Keychain read failed: \(status, privacy: .public)")
            throw AuraError.keychainFailure(status: status)
        }
    }

    func hasSecret(for key: CredentialKey) -> Bool {
        // Deliberately non-throwing: callers use this to decide whether to show "Configured", and a
        // keychain hiccup should render as "not configured" rather than as an error alert.
        (try? secret(for: key)) != nil
    }

    func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AuraLog.security.error("Keychain delete failed: \(status, privacy: .public)")
            throw AuraError.keychainFailure(status: status)
        }
        AuraLog.security.info("Deleted keychain item \(key.rawValue, privacy: .public)")
    }

    func deleteAll() throws {
        // Each key individually rather than one service-wide delete, so a single failure does not
        // leave the rest silently in place.
        var firstFailure: OSStatus?
        for key in CredentialKey.allCases {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, firstFailure == nil {
                firstFailure = status
            }
        }
        if let firstFailure {
            throw AuraError.keychainFailure(status: firstFailure)
        }
    }

    private func baseQuery(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

/// An in-memory credential store for tests and previews.
///
/// The keychain is unavailable in some test environments and shared across runs in others, either of
/// which makes tests that touch it flaky. This keeps them honest.
final class InMemoryCredentialStore: SecureCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialKey: String] = [:]

    init(seed: [CredentialKey: String] = [:]) {
        storage = seed
    }

    func store(_ secret: String, for key: CredentialKey) throws {
        lock.withLock { storage[key] = secret }
    }

    func secret(for key: CredentialKey) throws -> String? {
        lock.withLock { storage[key] }
    }

    func hasSecret(for key: CredentialKey) -> Bool {
        lock.withLock { storage[key] != nil }
    }

    func delete(_ key: CredentialKey) throws {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    func deleteAll() throws {
        lock.withLock { storage.removeAll() }
    }
}
