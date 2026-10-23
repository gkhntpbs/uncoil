import Foundation

@MainActor
struct SettingsDocument {
    private var original: [String: Any] = [:]
    private var protectedFields: [String: Any] = [:]
    private var fallback: [String: Any] = [:]
    private var unknownAccounts: [[String: Any]] = []
    private var unreadable = false
    private(set) var requiresBackup = false

    mutating func decode(_ data: Data) -> SettingsStore.Persisted? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(SettingsStore.Persisted()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else {
            unreadable = true
            return nil
        }
        original = object
        var compatible = defaults
        for key in SettingsStore.Persisted.CodingKeys.allCases.map(\.rawValue) {
            guard let value = object[key] else { continue }
            var candidate = defaults
            candidate[key] = value
            if key == "accounts", let accounts = value as? [[String: Any]] {
                candidate[key] = accounts.filter { account in
                    guard let data = try? JSONSerialization.data(withJSONObject: account),
                          (try? JSONDecoder().decode(AccountProfile.self, from: data)) != nil
                    else {
                        unknownAccounts.append(account)
                        requiresBackup = true
                        return false
                    }
                    return true
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: candidate),
                  (try? JSONDecoder().decode(SettingsStore.Persisted.self, from: data)) != nil
            else {
                protectedFields[key] = value
                requiresBackup = true
                continue
            }
            compatible[key] = candidate[key]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: compatible),
              let decoded = try? JSONDecoder().decode(SettingsStore.Persisted.self, from: data),
              let encoded = try? JSONEncoder().encode(decoded),
              let fallback = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            unreadable = true
            return nil
        }
        self.fallback = fallback
        return decoded
    }

    func encode(_ value: SettingsStore.Persisted) -> Data? {
        guard !unreadable,
              let data = try? JSONEncoder().encode(value),
              let encoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var result = original
        for key in SettingsStore.Persisted.CodingKeys.allCases.map(\.rawValue) {
            result[key] = encoded[key]
        }
        for (key, value) in protectedFields {
            let current = encoded[key] as? NSObject
            let initial = fallback[key] as? NSObject
            if key == "accounts" || current == initial { result[key] = value }
        }
        if !unknownAccounts.isEmpty, let accounts = result["accounts"] as? [[String: Any]] {
            result["accounts"] = accounts + unknownAccounts
        }
        return try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
}
