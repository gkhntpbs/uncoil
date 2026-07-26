import Foundation

/// Small, pure, testable fuzzy matcher for the command palette.
///
/// A query matches a candidate when its characters appear as an in-order
/// subsequence of the candidate. Matching is case- and diacritic-insensitive
/// and folds the Turkish dotted/dotless i pair so "istanbul" matches
/// "İstanbul" and "gorev" matches "görev". A higher score is a better match;
/// bonuses reward prefix, word-boundary, and consecutive hits.
enum FuzzyScore {
    /// Case/diacritic-insensitive normalization with explicit Turkish i folding.
    /// Kept deterministic and locale-stable (folding under an English locale)
    /// so tests and runtime agree regardless of the user's system locale.
    static func normalize(_ string: String) -> String {
        var text = string
        for (from, to) in [("i", "i"), ("I", "i"), ("I", "i")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US"))
            .lowercased()
    }

    /// Returns a score for `query` against `candidate`, or `nil` when the query
    /// is not a subsequence. An empty query matches everything with score 0.
    static func score(query: String, candidate: String) -> Int? {
        let q = Array(normalize(query))
        guard !q.isEmpty else { return 0 }
        let c = Array(normalize(candidate))
        guard q.count <= c.count else { return nil }

        var qi = 0
        var total = 0
        var previousMatch = -2

        for (index, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var bonus = 1
            if index == 0 {
                bonus += 15                              // prefix
            } else if !isWordChar(c[index - 1]) {
                bonus += 10                              // word boundary
            }
            if index == previousMatch + 1 {
                bonus += 8                               // consecutive run
            }
            total += bonus
            previousMatch = index
            qi += 1
        }

        guard qi == q.count else { return nil }
        // Prefer tighter matches: mild penalty for the ungap­ped tail length.
        total -= (c.count - q.count) / 4
        return total
    }

    /// Convenience: does `query` match `candidate` at all?
    static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
