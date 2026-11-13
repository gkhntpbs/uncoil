import Foundation
import Security
import LocalAuthentication

/// Reads the credentials the coding agents already own.
///
/// The rule the whole usage layer is built on: monitoring reuses the login the
/// user already performed. Asking someone to authenticate a second time so a
/// percentage can be drawn would cost more than the percentage is worth, and a
/// background refresh that can raise a login prompt is a background refresh
/// that will raise one at the wrong moment.
///
/// Nothing here writes. The agents own these files; a monitor that repaired,
/// refreshed in place or reformatted one would be able to log its owner out.
enum UsageCredentials {

    // MARK: - Files

    /// Reads and parses a JSON credential file. A missing file is not an error
    /// worth a message — it is the ordinary state of an agent nobody has logged
    /// into.
    static func readJSONFile(at url: URL) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageFetchError(.credentialsMissing, detail: nil)
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw UsageFetchError(.credentialsMissing, detail: "unreadable")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            // The path is safe to name; the contents are not.
            throw UsageFetchError(.malformedResponse, detail: "credential file is not JSON")
        }
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Keychain

    /// The only Keychain services this layer will ever read.
    ///
    /// An allowlist rather than a search: a usage monitor that can be pointed
    /// at an arbitrary service is a credential reader with a friendly name, and
    /// the list of things it is allowed to see should be readable in one place.
    static let allowedKeychainServices: Set<String> = [
        "Claude Code-credentials",
    ]

    /// Generic-password lookup by service name.
    ///
    static func readKeychainString(service: String, allowInteraction: Bool = false) -> String? {
        readKeychain(service: service, allowInteraction: allowInteraction).value
    }

    struct KeychainRead {
        var value: String?
        var status: OSStatus

        /// A readable name for the status, for the usage log.
        var statusText: String {
            switch status {
            case errSecSuccess: "ok"
            case errSecItemNotFound: "no item (is Claude Code logged in on this Mac?)"
            case errSecInteractionNotAllowed: "would need to ask"
            case errSecAuthFailed, errSecUserCanceled: "access denied"
            default:
                (SecCopyErrorMessageString(status, nil) as String?).map { "\($0) (\(status))" } ?? "OSStatus \(status)"
            }
        }
    }

    /// Like `readKeychainString`, with the status kept for the log.
    ///
    /// Without `allowInteraction` the read can never put a dialog up: both the
    /// authentication context and the legacy keychain's own interaction
    /// switch are turned off for the call, so an item Uncoil was not already
    /// allowed to read fails with `errSecInteractionNotAllowed` instead.
    static func readKeychain(service: String, allowInteraction: Bool) -> KeychainRead {
        guard allowedKeychainServices.contains(service) else {
            return KeychainRead(value: nil, status: errSecParam)
        }
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if !allowInteraction { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(true) } }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        context.localizedReason = String(localized: "Read Claude Code account usage.")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return KeychainRead(value: nil, status: status)
        }
        return KeychainRead(value: String(data: data, encoding: .utf8), status: status)
    }

    /// The legacy interaction switch is process-wide; one read at a time.
    private static let keychainLock = NSLock()

    // MARK: - Expiry

    /// Whether a token whose expiry is known has already passed it.
    ///
    /// Providers state expiry in milliseconds since the epoch in every file
    /// this layer reads; seconds are accepted too, because a value that small
    /// cannot be a plausible millisecond timestamp and guessing wrong in that
    /// direction would treat a live token as expired forever.
    static func expiryDate(fromEpoch value: Double) -> Date {
        value > 100_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }

    /// A token is treated as expired slightly before it is, so a refresh that
    /// takes a second does not start with a token that dies mid-flight.
    static func isExpired(_ expiry: Date, now: Date, leeway: TimeInterval = 60) -> Bool {
        expiry.addingTimeInterval(-leeway) <= now
    }

    // MARK: - Redaction

    /// Removes anything that looks like a credential from a string bound for a
    /// log or an error message.
    ///
    /// Written as a shape match rather than a value match on purpose: redacting
    /// only the tokens we happen to hold would miss the one in a response body
    /// nobody expected to contain one, which is exactly the case that ends up
    /// in a bug report.
    static func redacted(_ text: String) -> String {
        var result = text
        // The character class has to include `/`, `+` and `=`. Google's refresh
        // tokens begin `1//`, and anything base64 carries the other two; a class
        // of only word characters stops at the first slash, which leaves the
        // whole of `1//abcdef…` in the text while appearing to have matched.
        let secret = #"[A-Za-z0-9._\-\/+=]"#
        let patterns = [
            #"(?i)(bearer\s+)\#(secret){8,}"#,
            #"(?i)("?(access|refresh|id)_?token"?\s*[:=]\s*"?)\#(secret){8,}"#,
            #"(?i)("?session_?key"?\s*[:=]\s*"?)\#(secret){8,}"#,
            #"\bsk-\#(secret){8,}"#,
            #"\bey\#(secret){20,}"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1«redacted»"
            )
        }
        return result
    }
}
