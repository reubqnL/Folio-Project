import XCTest
import Foundation
@testable import FolioCore

/// Increment 10 — incremental reparse. The contract in every scenario:
/// `session.reparse(newSource).document` is byte-equivalent to
/// `MarkdownParser.parse(newSource)`, and untouched blocks keep their ids.
final class MarkdownIncrementalTests: XCTestCase {

    // MARK: - Harness

    private func splice(_ source: String, replacing range: Range<Int>, with replacement: String) -> String {
        var out = [UInt16](source.utf16)
        out.replaceSubrange(range, with: replacement.utf16)
        return String(decoding: out, as: UTF16.self)
    }

    /// UTF-16-offset range of the first occurrence of `needle`.
    private func range(of needle: String, in haystack: String) -> Range<Int> {
        let h = [UInt16](haystack.utf16), n = [UInt16](needle.utf16)
        guard !n.isEmpty, h.count >= n.count else { XCTFail("needle not found"); return 0..<0 }
        outer: for start in 0...(h.count - n.count) {
            for j in 0..<n.count where h[start + j] != n[j] { continue outer }
            return start..<(start + n.count)
        }
        XCTFail("needle \(needle) not found")
        return 0..<0
    }

    /// Applies a sequence of edits; after each one the incremental document
    /// must equal a full parse of the current source. Each edit is a closure
    /// over the current text, so offsets are never stale.
    private func assertChain(
        initial: String,
        edits: [(String) -> (Range<Int>, String)],
        _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var session = MarkdownReparseSession(source: initial)
        var current = initial
        XCTAssertEqual(session.document, MarkdownParser.parse(initial), "\(label): initial", file: file, line: line)
        for (index, edit) in edits.enumerated() {
            let (editRange, replacement) = edit(current)
            current = splice(current, replacing: editRange, with: replacement)
            let result = session.reparse(current)
            let full = MarkdownParser.parse(current)
            XCTAssertEqual(
                result.document, full,
                "\(label) edit \(index): incremental != full parse",
                file: file, line: line
            )
            if full.isLimited {
                XCTAssertTrue(result.metrics.usedFullParse, "\(label) edit \(index): limited source must fall back", file: file, line: line)
            }
        }
    }

    private func assertSingle(_ before: String, _ after: String, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        assertChain(initial: before, edits: [{ source in (0..<source.utf16.count, after) }], label, file: file, line: line)
    }

    // MARK: - Adversarial splice swallows

    private static let spine = """
    Intro paragraph one.\n\
    \n\
    ## Heading\n\
    \n\
    Body paragraph with **bold**.\n\
    \n\
    | a | b |\n\
    | --- | --- |\n\
    | 1 | 2 |\n\
    \n\
    > quoted line\n\
    \n\
    Final paragraph.\n
    """

    func testFenceSwallowingSplicePoint() {
        assertChain(initial: Self.spine, edits: [
            { t in (self.range(of: "Final paragraph.", in: t), "```\nopened inside\n") },
        ], "fence swallow")
    }

    func testTableSwallowingSplicePoint() {
        assertChain(initial: Self.spine, edits: [
            { t in (self.range(of: "> quoted line", in: t), "| c | d |\n| --- | --- |\n| 3 | 4 |") },
        ], "table swallow")
    }

    func testQuoteSwallowingSplicePoint() {
        assertChain(initial: Self.spine, edits: [
            { t in (self.range(of: "Final", in: t), "> quoted") },
        ], "quote swallow")
    }

    func testUnclosedFenceToEOF() {
        let before = Self.spine + "\n```\nopen forever\n"
        assertChain(initial: before, edits: [
            { t in ((t.utf16.count - 1)..<(t.utf16.count - 1), "still inside\n") },
        ], "unclosed fence append")
    }

    func testClosingFenceAppearingLater() {
        let before = Self.spine + "\n```\nopen forever\n"
        assertChain(initial: before, edits: [
            { t in ((t.utf16.count)..<(t.utf16.count), "title line\n---\n```\nAfter fence.\n") },
        ], "closing fence later")
    }

    func testSetextPartnerChangeAcrossSplice() {
        assertSingle("title: x\n---\nparagraph\n", "title: x\ntext\nparagraph\n", "setext partner change")
        assertSingle("para one\n---\n\n", "para one\n===\n\n", "setext level change")
        assertSingle("## t\n\nx\n---\n===\n\n", "## t\n\nx\n---\n~~~\n===\n\n", "fence opens above setext partner")
        assertSingle("## t\n\nx\n---\n~~~\n===\n\n", "## t\n\nx\n---\n===\n\n", "fence closes above setext partner")
    }

    // MARK: - Front matter

    func testFrontMatterCloserAdded() {
        // Fuzz regression: deleting the opener + blank reveals a closer below.
        assertSingle("a\n\n---\nb\n---\nq\n", "---\nb\n---\nq\n", "front matter via deletion")
    }

    func testFrontMatterCloserInsertedInsideScanRange() {
        // Fuzz regression: a closer appearing at line 4 swallows kept prefix.
        assertSingle("---\ntitle\nA\nB\nC\n", "---\ntitle\nA\nB\n---\nC\n", "front matter closer insert")
    }

    func testFrontMatterRemoved() {
        assertSingle("---\ntitle: a\n---\nBody\n", "\nBody\n", "front matter removal")
        assertSingle("---\ntitle: a\n---\nBody\n", "---\ntitle: a\nBody\n", "closer gone")
    }

    func testMidDocumentDashesAreNotFrontMatter() {
        // Fuzz regression: a window starting on `---` must not form metadata.
        assertSingle(
            "title:-2\n---\n---\ntitle: 4\n---\n---\ntitle:-2\n---\n---\ntitle: 4\n---\npara 1 with **bold** text\n| --- | --- |\n| a0 | b |\n\n",
            "title:-2\n---\n---\ntitle: 4\n---\n---\ntitle:-2\n---\n---\ntitle: 4\n---\npara 2 with **bold** text\n| --- | --- |\n| a0 | b |\n\n",
            "mid-document dashes"
        )
    }

    func testMetadataNeverSuffixReused() {
        // Fuzz regression: inserting lines above front matter must reparse it
        // as ordinary blocks mid-document, not reuse the metadata record.
        let before = "---\ntitle:-2\n---\n---\ntitle: 4\n---\npara 1\n"
        assertSingle(before, "\n\n\n\n\n" + before, "metadata suffix reuse")
    }

    func testFrontMatterShrinkingAcrossSplice() {
        // Fuzz regression: old metadata straddling the window end loses its tail.
        assertSingle("---\n---\n---\ntitle\nbody\n---\ntail\n",
                     "---\n---\ntitle\nbody\n---\ntail\n",
                     "metadata shrink")
    }

    // MARK: - Paragraph lookahead and boundary proofs

    func testTwoLineLookaheadHazard() {
        // Fuzz regression: a paragraph ending at prefix-2 flips when `---` changes.
        assertSingle("a\n\n\nt\n\n\np one\n\np two\n---\n~~~\nq\n",
                     "a\n\n\nt\n\n\np one\n\np two\n---\nzzz\nq\n",
                     "lookahead rule flip")
        assertSingle("a\n\n\nt\n\n\np one\n\np two\n---\nzzz\nq\n",
                     "a\n\n\nt\n\n\np one\n\np two\n---\n~~~\nq\n",
                     "lookahead rule flip back")
    }

    func testParagraphBreakInsertion() {
        assertChain(initial: Self.spine, edits: [
            { t in (self.range(of: "Body paragraph", in: t).lowerBound..<(self.range(of: "Body paragraph", in: t).lowerBound), "\n") },
            { t in (self.range(of: "Body paragraph", in: t).lowerBound..<(self.range(of: "Body paragraph", in: t).lowerBound), "\n\n") },
            { t in (self.range(of: "Body paragraph", in: t).lowerBound..<(self.range(of: "Body paragraph", in: t).lowerBound + 2), "") },
        ], "paragraph break")
    }

    // MARK: - Identity

    func testUntouchedBlocksKeepIDs() {
        var session = MarkdownReparseSession(source: Self.spine)
        let before = session.document.blocks
        let edited = splice(Self.spine, replacing: range(of: "**bold**", in: Self.spine), with: "*italic*")
        let result = session.reparse(edited)
        let after = result.document.blocks
        XCTAssertEqual(before.count, after.count)
        for (old, new) in zip(before, after) {
            let text = String(decoding: edited.utf16.dropFirst(new.source.location).prefix(new.source.length), as: UTF16.self)
            if text.contains("italic") { continue } // the edited block
            XCTAssertEqual(old.id, new.id, "block at lines of kind \(old.kind) changed identity without an edit")
        }
    }

    func testDuplicateBlockRenumberingMatchesFullParse() {
        // Three identical paragraphs: the contract is parse equality, which
        // includes occurrence renumbering of the duplicate content ids.
        let text = "same\n\nsame\n\nsame\n\n"
        var session = MarkdownReparseSession(source: text)
        let edited = splice(text, replacing: range(of: "same", in: text), with: "diff")
        let result = session.reparse(edited)
        XCTAssertEqual(result.document, MarkdownParser.parse(edited))
        XCTAssertEqual(result.document.blocks.count, 3)
        XCTAssertTrue(result.document.blocks.allSatisfy { block in
            if case .paragraph = block.kind { return true }
            return false
        })
    }

    func testEditThenUndoRestores() {
        assertChain(initial: Self.spine, edits: [
            { t in (self.range(of: "Final paragraph.", in: t), "Changed.") },
            { t in (self.range(of: "Changed.", in: t), "Final paragraph.") },
            { t in (self.range(of: "Body paragraph", in: t), "Corpus paragraph") },
            { t in (self.range(of: "Corpus paragraph", in: t), "Body paragraph") },
        ], "edit then undo")
    }

    // MARK: - Empty, CRLF, budget

    func testEmptyDocuments() {
        assertSingle("", "", "empty")
        assertSingle("", "\n", "empty to newline")
        assertSingle("a\n", "", "collapse to empty")
    }

    func testCRLFAndEmojiSpans() {
        let crlf = "# t\r\n\r\npara with 🎉 emoji\r\n\r\n- item 🎉\r\n"
        assertChain(initial: crlf, edits: [
            { t in (self.range(of: "para", in: t), "text") },
        ], "crlf emoji")
    }

    func testBudgetFallbacks() {
        // Over-budget source falls back to a full parse with the limitation.
        let big = String(repeating: "word ", count: 130_000) // ~650 KB utf8
        var session = MarkdownReparseSession(source: "small\n")
        let result = session.reparse(big)
        XCTAssertTrue(result.metrics.usedFullParse)
        XCTAssertNotNil(result.document.limitation)
        // A long line alone trips the line budget.
        let longLine = String(repeating: "x", count: 70_000) + "\n"
        XCTAssertTrue(MarkdownParser.parse(longLine).isLimited)
    }

    func testExcerptBudgetDocument() {
        // Inside the size budget but over the line budget -> excerpt limitation.
        let big = String(repeating: "w\n\n", count: 40_000) // 80K lines > 32K cap
        var session = MarkdownReparseSession(source: "small\n")
        let result = session.reparse(big)
        XCTAssertTrue(result.metrics.usedFullParse)
        XCTAssertTrue(result.document.isLimited)
    }

    // MARK: - Metrics

    func testMetricsOnLargeDocument() {
        var parts: [String] = []
        for index in 0..<2_000 {
            parts.append("Paragraph number \(index) with some **content**.\n\n## Heading \(index)\n\n")
        }
        let big = parts.joined()
        var session = MarkdownReparseSession(source: big)
        XCTAssertEqual(session.document.blocks.count, 4_000)

        let target = "Paragraph number 1000 with some **content**."
        let edited = splice(big, replacing: range(of: target, in: big), with: "Paragraph number 1000 with other **content**.")

        let start = Date()
        let result = session.reparse(edited)
        let elapsed = Date().timeIntervalSince(start)
        print("incremental reparse of 4000-block document: reparsed \(result.metrics.blocksReparsed) blocks, reused \(result.metrics.blocksReused), \(String(format: "%.2f", elapsed * 1000)) ms")

        XCTAssertEqual(result.document, MarkdownParser.parse(edited))
        XCTAssertLessThanOrEqual(result.metrics.blocksReparsed, 6)
        XCTAssertGreaterThanOrEqual(result.metrics.blocksReused, 3_990)
        XCTAssertFalse(result.metrics.usedFullParse)
    }

    func testNoOpReparseReusesEverything() {
        var session = MarkdownReparseSession(source: Self.spine)
        let result = session.reparse(Self.spine)
        XCTAssertEqual(result.metrics.blocksReparsed, 0)
        XCTAssertFalse(result.metrics.usedFullParse)
        XCTAssertEqual(result.document, MarkdownParser.parse(Self.spine))
    }
}
