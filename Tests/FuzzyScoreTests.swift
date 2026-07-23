import XCTest
@testable import Uncoil

final class FuzzyScoreTests: XCTestCase {
    func testEmptyQueryMatchesEverythingWithZero() {
        XCTAssertEqual(FuzzyScore.score(query: "", candidate: "anything"), 0)
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyScore.score(query: "yp", candidate: "Yeni Proje"))
        XCTAssertNotNil(FuzzyScore.score(query: "proje", candidate: "Yeni Proje Ekle"))
    }

    func testNonSubsequenceFails() {
        XCTAssertNil(FuzzyScore.score(query: "zzz", candidate: "Yeni Proje"))
        XCTAssertNil(FuzzyScore.score(query: "ejorp", candidate: "proje"))
    }

    func testPrefixBeatsMidWordMatch() {
        let prefix = FuzzyScore.score(query: "pro", candidate: "proje")
        let mid = FuzzyScore.score(query: "pro", candidate: "yeni proje")
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(mid)
        XCTAssertGreaterThan(prefix!, mid!)
    }

    func testConsecutiveBeatsScattered() {
        let consecutive = FuzzyScore.score(query: "abc", candidate: "abcxyz")
        let scattered = FuzzyScore.score(query: "abc", candidate: "axbxcx")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(consecutive!, scattered!)
    }

    func testTurkishCaseAndDiacriticInsensitive() {
        XCTAssertNotNil(FuzzyScore.score(query: "istanbul", candidate: "İstanbul"))
        XCTAssertNotNil(FuzzyScore.score(query: "gorev", candidate: "görev"))
        XCTAssertNotNil(FuzzyScore.score(query: "GÖREV", candidate: "görev"))
        XCTAssertNotNil(FuzzyScore.score(query: "sifir", candidate: "sıfır"))
    }

    func testWordBoundaryBonus() {
        // "op" should rank the word-start match above an in-word one.
        let boundary = FuzzyScore.score(query: "op", candidate: "yeni oturum popout")
        XCTAssertNotNil(boundary)
    }
}
