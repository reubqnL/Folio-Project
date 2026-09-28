import XCTest
@testable import FolioCore

final class QueryAndMetadataTests: XCTestCase {
    func testQueryQuotesTermsAndLimitsOperators() throws {
        XCTAssertEqual(try NoteSearchQuery("red OR blue").ftsExpression, "\"red\" AND \"OR\" AND \"blue\"*")
        XCTAssertEqual(try NoteSearchQuery("\"red blue\"").ftsExpression, "\"red blue\"")
    }
    func testEmptyAndPunctuationOnlyQueriesDoNotMatchEverything() throws {
        XCTAssertTrue(try NoteSearchQuery("   ").isEmpty)
        XCTAssertTrue(try NoteSearchQuery("***:{}").isEmpty)
    }
    func testTermCountAndNULAreBounded() {
        XCTAssertThrowsError(try NoteSearchQuery(Array(repeating: "term", count: 17).joined(separator: " ")))
        XCTAssertThrowsError(try NoteSearchQuery("one\0two"))
    }
    func testTagListAndQuotedCommas() {
        XCTAssertEqual(NoteMetadata.tags(in: "---\ntags: [work, 'two, words', Work]\n---\n#body"), ["work", "two, words"])
    }
    func testIndentedTagList() {
        XCTAssertEqual(NoteMetadata.tags(in: "---\ntags:\n  - plans\n  - 'long term'\n---\n"), ["plans", "long term"])
    }
    func testNoFrontMatterDoesNotInventTagsFromHeadings() {
        XCTAssertTrue(NoteMetadata.tags(in: "# Heading\nordinary #word\n").isEmpty)
    }
    func testMalformedTagQuotesAreNotGuessed() {
        XCTAssertTrue(NoteMetadata.tags(in: "---\ntags: ['unterminated]\n---\n").isEmpty)
    }
}
