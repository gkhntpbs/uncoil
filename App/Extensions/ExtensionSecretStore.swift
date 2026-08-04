import Foundation
import Security

/// Keychain-backed secrets for MCP extensions.
///
/// A value lives only in the Keychain: it is never written to an agent config,
/// a manifest, a diff, a log or an export. The launcher asks the running app for
/// it at start-up, which is why the app is required to run an extension that
/// needs a secret.
@MainActor
struct ExtensionSecretStore {
    static let service = "com.gokhantopbas.uncoil.extensions.v1"

    /// Which extension a secret belongs to is part of the account name, so the
    /// UI can answer "which MCP reaches which secret?" without reading values.
    static func account(extensionID: String, key: String) -> String {
        "\(extensionID)#\(key)"
    }

    static func parseAccount(_ account: String) -> (extensionID: String, key: String)? {
        guard let separator = account.lastIndex(of: "#") else { return nil }
        let extensionID = String(account[..<separator])
        let key = String(account[account.index(after: separator)...])
        guard !extensionID.isEmpty, !key.isEmpty else { return nil }
        return (extensionID, key)
    }

    var service: String = ExtensionSecretStore.service

    func save(extensionID: String, key: String, value: String) {
        let account = Self.account(extensionID: extensionID, key: key)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var match = identity
        match[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        if SecItemUpdate(match as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var query = identity
            attributes.forEach { query[$0.key] = $0.value }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    func read(extensionID: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(extensionID: extensionID, key: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never prompt: a launcher waiting on a dialog would hang the agent.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(extensionID: String, key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(extensionID: extensionID, key: key),
        ] as CFDictionary)
    }

    /// Every stored secret, as extension → key names. Values are never returned.
    func inventory() -> [String: [String]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:]
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  let parsed = Self.parseAccount(account) else { continue }
            result[parsed.extensionID, default: []].append(parsed.key)
        }
        return result.mapValues { $0.sorted() }
    }

    /// Environment to inject for one extension. Missing keys are reported so a
    /// half-configured server fails with a clear reason instead of a puzzle.
    func environment(
        for extensionID: String,
        keys: [String]
    ) -> (environment: [String: String], missing: [String]) {
        var environment: [String: String] = [:]
        var missing: [String] = []
        for key in keys {
            if let value = read(extensionID: extensionID, key: key) {
                environment[key] = value
            } else {
                missing.append(key)
            }
        }
        return (environment, missing)
    }

    /// Redacts every known secret value in a piece of text, for logs and error
    /// messages that may quote a command line.
    static func masked(_ text: String, values: [String]) -> String {
        var result = text
        for value in values where value.count >= 4 {
            result = result.replacingOccurrences(of: value, with: "«gizli»")
        }
        return result
    }
}
