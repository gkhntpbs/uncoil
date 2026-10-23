import Foundation

@MainActor
struct SettingsDocument {
    private var original: [String: Any] = [:]
    private var protectedFields: [String: Any] = [:]
    private var fallback: [String: Any] = [:]
    private var baseline: [String: Any] = [:]
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

    mutating func captureBaseline(_ value: SettingsStore.Persisted) {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        baseline = object
    }

    func encode(_ value: SettingsStore.Persisted) -> Data? {
        guard !unreadable,
              let data = try? JSONEncoder().encode(value),
              let encoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var result = original
        for key in SettingsStore.Persisted.CodingKeys.allCases.map(\.rawValue) {
            if let original = original[key], equal(baseline[key], encoded[key]) {
                result[key] = original
            } else {
                result[key] = merge(original: original[key], baseline: fallback[key], updated: encoded[key])
            }
        }
        for (key, value) in protectedFields {
            if key == "accounts" || equal(encoded[key], baseline[key]) { result[key] = value }
        }
        if !unknownAccounts.isEmpty, !equal(encoded["accounts"], baseline["accounts"]),
           let accounts = result["accounts"] as? [[String: Any]] {
            result["accounts"] = accounts + unknownAccounts
        }
        return try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        (lhs as? NSObject) == (rhs as? NSObject)
    }

    private func merge(original: Any?, baseline: Any?, updated: Any?) -> Any? {
        if let original, equal(baseline, updated) { return original }
        if let source = original as? [String: Any],
           let previous = baseline as? [String: Any],
           let current = updated as? [String: Any] {
            var result = source.filter { previous[$0.key] == nil }
            for (key, value) in current {
                result[key] = merge(original: source[key], baseline: previous[key], updated: value)
            }
            return result
        }
        if let source = original as? [[String: Any]],
           let previous = baseline as? [[String: Any]],
           let current = updated as? [[String: Any]],
           current.allSatisfy({ $0["id"] is String }) {
            return current.map { item in
                let id = item["id"] as? String
                return merge(
                    original: source.first { $0["id"] as? String == id },
                    baseline: previous.first { $0["id"] as? String == id },
                    updated: item
                ) as? [String: Any] ?? item
            }
        }
        return updated
    }
}
