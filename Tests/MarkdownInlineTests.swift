import XCTest
@testable import Uncoil

final class MarkdownInlineTests: XCTestCase {
    func testStripsBoldAndItalic() {
        XCTAssertEqual(MarkdownInline.plain("**Ship the importer**"), "Ship the importer")
        XCTAssertEqual(MarkdownInline.plain("*soon*"), "soon")
        XCTAssertEqual(MarkdownInline.plain("__loud__"), "loud")
        XCTAssertEqual(MarkdownInline.plain("_quiet_"), "quiet")
        XCTAssertEqual(MarkdownInline.plain("***both***"), "both")
    }

    func testStripsCodeSpansLinksAndStrikethrough() {
        XCTAssertEqual(MarkdownInline.plain("`MonthDetailView` inside"), "MonthDetailView inside")
        XCTAssertEqual(MarkdownInline.plain("see [the plan](docs/PLAN.md)"), "see the plan")
        XCTAssertEqual(MarkdownInline.plain("![shot](a.png) after"), "shot after")
        XCTAssertEqual(MarkdownInline.plain("~~dropped~~"), "dropped")
        XCTAssertEqual(MarkdownInline.plain("<https://example.com>"), "https://example.com")
    }

    /// The screenshot that started this: a real task line from a user's file.
    func testStripsTheMarksAroundAMixedLine() {
        XCTAssertEqual(
            MarkdownInline.plain("**Esnek haftalık izin düzenleme (mevcut ay)** — `MonthDetailView` içinde"),
            "Esnek haftalık izin düzenleme (mevcut ay) — MonthDetailView içinde"
        )
    }

    /// Arithmetic and snake_case are not emphasis, and a lone mark is not a pair.
    func testLeavesNonEmphasisAlone() {
        XCTAssertEqual(MarkdownInline.plain("2 * 3 * 4"), "2 * 3 * 4")
        XCTAssertEqual(MarkdownInline.plain("call some_helper_name"), "call some_helper_name")
        XCTAssertEqual(MarkdownInline.plain("a * b"), "a * b")
        XCTAssertEqual(MarkdownInline.plain("100% done"), "100% done")
    }

    /// The point of the whole thing: the file is never the one that changes.
    func testTheTaskKeepsItsMarkdownAndOnlyDisplayDropsIt() {
        let document = TodoParser.parse("- [ ] **Ship it** now\n", path: "/repo/TODO.md")
        guard let task = document.tasks.first else { return XCTFail("no task parsed") }
        XCTAssertEqual(task.text, "**Ship it** now")
        XCTAssertEqual(task.displayText, "Ship it now")
    }
}
