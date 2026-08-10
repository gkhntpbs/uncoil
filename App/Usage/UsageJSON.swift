import Foundation

/// Shared JSON reading for the usage providers.
///
/// Every helper here accepts several spellings of the same field. That is not
/// defensiveness for its own sake: these payloads are not published schemas.
/// They are the wire format between a vendor's CLI and its own backend, and the
/// same quantity arrives as `used_percent` from one route and `usedPercent`
/// from another of the *same* provider. A parser pinned to one spelling breaks
/// on a CLI update and reports it as "usage unavailable", which is the failure
/// mode hardest to tell from a real one.
///
/// The rule kept throughout: an absent field yields `nil`, never zero. Zero is
/// a real reading and must only ever come from the provider.
enum UsageJSON {

    // MARK: - Field access

    /// First present, non-null value among `keys`.
    static func value(_ object: [String: JSONValue], _ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = object[key], value != .null { return value }
        }
        return nil
    }

    static func double(_ object: [String: JSONValue], _ keys: [String]) -> Double? {
        guard let value = value(object, keys) else { return nil }
        // Some fields arrive as strings ("87.5"); a numeric string is still a
        // number, and refusing it would drop a window we can read.
        let number = value.doubleValue ?? value.stringValue.flatMap(Double.init)
        // An infinity or a NaN is not a reading. Dropping it here means no
        // window is built from it at all, which is the honest outcome: a
        // percentage nobody can interpret must not become one that looks
        // interpretable.
        guard let number, number.isFinite else { return nil }
        return number
    }

    static func int(_ object: [String: JSONValue], _ keys: [String]) -> Int? {
        guard let value = value(object, keys) else { return nil }
        if let number = value.intValue { return number }
        if let text = value.stringValue { return Int(text) }
        return nil
    }

    static func string(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        guard let text = value(object, keys)?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    static func object(_ object: [String: JSONValue], _ keys: [String]) -> [String: JSONValue]? {
        value(object, keys)?.objectValue
    }

    static func array(_ object: [String: JSONValue], _ keys: [String]) -> [JSONValue]? {
        value(object, keys)?.arrayValue
    }

    // MARK: - Dates

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    /// An absolute instant, from whichever of the three forms a provider used.
    ///
    /// The relative form is the one that matters most and is the easiest to get
    /// wrong: `resets_in_seconds` is measured from when the *response* was
    /// produced, so it has to be added to the time of the reading rather than
    /// to the time somebody later looks at the screen.
    static func date(_ object: [String: JSONValue], absolute: [String], relativeSeconds: [String], now: Date) -> Date? {
        if let value = value(object, absolute) {
            if let text = value.stringValue {
                for formatter in isoFormatters {
                    if let date = formatter.date(from: text) { return date }
                }
                // A numeric string in an "at" field is an epoch, not a date.
                if let number = Double(text) { return epochDate(number) }
            }
            if let number = value.doubleValue { return epochDate(number) }
        }
        if let seconds = double(object, relativeSeconds) {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    /// Seconds or milliseconds. A value past the year 5138 in seconds is a
    /// millisecond timestamp; nothing this layer reads is scheduled that far
    /// out, so the ambiguity resolves cleanly.
    static func epochDate(_ value: Double) -> Date {
        value > 100_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }

    // MARK: - Windows

    /// Reads one rate-limit window.
    ///
    /// Returns `nil` when the object carries no percentage at all. A window
    /// with a reset time and no number is not a window — showing it would put
    /// a countdown on screen next to nothing to count down.
    static func window(
        _ object: [String: JSONValue],
        id: String,
        title: String,
        modelID: String? = nil,
        now: Date
    ) -> UsageWindow? {
        let resetsAt = date(
            object,
            absolute: ["resets_at", "resetsAt", "reset_at", "resetTime", "reset_time", "resets"],
            relativeSeconds: ["resets_in_seconds", "resetsInSeconds", "reset_in_seconds", "secondsUntilReset"],
            now: now
        )
        let windowMinutes = int(object, ["window_minutes", "windowMinutes", "window_size_minutes"])

        if let used = double(object, ["used_percent", "usedPercent", "utilization_percent", "percent_used"]) {
            return UsageWindow(
                id: id, title: title, usedPercent: used,
                resetsAt: resetsAt, windowMinutes: windowMinutes, modelID: modelID
            )
        }
        if let remainingPercent = double(object, ["remaining_percent", "remainingPercent", "percent_remaining"]) {
            return UsageWindow(
                id: id, title: title, usedPercent: 100 - remainingPercent,
                resetsAt: resetsAt, windowMinutes: windowMinutes, modelID: modelID
            )
        }
        if let fraction = double(object, ["remaining_fraction", "remainingFraction"]) {
            return UsageWindow.fromRemainingFraction(
                id: id, title: title, remainingFraction: fraction,
                resetsAt: resetsAt, windowMinutes: windowMinutes, modelID: modelID
            )
        }
        if let fraction = double(object, ["used_fraction", "usedFraction", "utilization"]) {
            return UsageWindow(
                id: id, title: title, usedPercent: fraction * 100,
                resetsAt: resetsAt, windowMinutes: windowMinutes, modelID: modelID
            )
        }
        return nil
    }

    /// A window title from its length, when the provider names only the span.
    /// Five hours and seven days are what the two vendors actually use; the
    /// general fallback keeps an unfamiliar span readable rather than dropping
    /// the window for want of a name.
    static func titleForWindow(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        switch minutes {
        case 300: return "5-hour limit"
        case 1440: return "Daily limit"
        case 10080: return "Weekly limit"
        case 43200: return "Monthly limit"
        default: break
        }
        if minutes % 10080 == 0 { return "\(minutes / 10080)-week limit" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }
}
