import XCTest

/// Every translation in `Localizable.xcstrings` has to consume its format
/// arguments exactly the way the source string does.
///
/// A translation that reorders arguments without positional specifiers hands
/// an `Int` to a `%@`, and Foundation dereferences the integer as an object
/// pointer — a segfault on the main thread, only in that language. That
/// shipped once (`%lld%% left of the %@` in Turkish crashed 0.5.0 at launch),
/// so the whole catalog is checked here rather than the one string.
final class LocalizationFormatTests: XCTestCase {
    private struct Specifier: Hashable, Comparable {
        let position: Int
        let kind: Character

        static func < (lhs: Specifier, rhs: Specifier) -> Bool {
            (lhs.position, String(lhs.kind)) < (rhs.position, String(rhs.kind))
        }
    }

    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")

    // `%[n$][flags][width][.precision][length]conversion`
    private static let pattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp])"#
    )

    /// Normalises a string's specifiers to (argument position, argument kind),
    /// so `%1$lld %2$@` and `%2$@ … %1$lld` compare equal and `%@ … %lld`
    /// against `%lld … %@` does not.
    private static func specifiers(in string: String) -> [Specifier] {
        let text = string.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(text.startIndex..., in: text)
        var implicit = 0
        return pattern.matches(in: text, range: range).map { match in
            implicit += 1
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? implicit
            let conversion = Range(match.range(at: 2), in: text).map { text[$0].first! } ?? "?"
            let kind: Character
            switch conversion {
            case "@": kind = "@"
            case "f", "F", "e", "E", "g", "G", "a", "A": kind = "f"
            case "s", "S", "p": kind = "s"
            default: kind = "d"
            }
            return Specifier(position: position, kind: kind)
        }.sorted()
    }

    /// Every rendered value in one localization: the plain string unit plus
    /// every plural/device variation beneath it.
    private static func values(in node: Any) -> [String] {
        guard let dict = node as? [String: Any] else { return [] }
        var out: [String] = []
        if let unit = dict["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            out.append(value)
        }
        for key in ["variations", "substitutions"] {
            guard let groups = dict[key] as? [String: Any] else { continue }
            for group in groups.values {
                guard let cases = group as? [String: Any] else { continue }
                for value in cases.values { out += values(in: value) }
            }
        }
        return out
    }

    func testEveryTranslationConsumesArgumentsLikeTheSource() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)

        var failures: [String] = []
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            // A plural variation may legitimately drop the count ("one" → "a
            // file"), so a translation may use fewer specifiers — but every one
            // it does use must exist in the source with the same kind.
            let source = Set(Self.specifiers(in: key))
            for (language, node) in localizations {
                for value in Self.values(in: node) {
                    let used = Set(Self.specifiers(in: value))
                    if !used.isSubset(of: source) {
                        failures.append("[\(language)] \(key.debugDescription) → \(value.debugDescription)")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "Format specifiers disagree with the source:\n" + failures.sorted().joined(separator: "\n"))
    }

    /// The string that crashed 0.5.0, formatted the way the Turkish build does.
    func testTurkishUsageRemainingFormatsWithoutCrashing() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try XCTUnwrap((catalog["strings"] as? [String: Any])?["%lld%% left of the %@"] as? [String: Any])
        let tr = try XCTUnwrap(Self.values(in: (entry["localizations"] as? [String: Any])?["tr"] as Any).first)

        let formatted = String(format: tr, locale: Locale(identifier: "tr_TR"), Int64(5), "haftalık pencere")
        XCTAssertEqual(formatted, "haftalık pencere için 5% kaldı")
    }
}
