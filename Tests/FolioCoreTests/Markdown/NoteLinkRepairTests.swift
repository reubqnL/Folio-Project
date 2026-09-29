import XCTest
import Foundation
@testable import FolioCore

/// Increment 11 — compact link repair. The scanner must recognise exactly the
/// authored note links the inline parser and the knowledge graph recognise,
/// at exact source spans; repairs rewrite one confirmed link and nothing else.
final class NoteLinkRepairTests: XCTestCase {

    // MARK: - Helpers

    private func slice(_ source: String, _ span: SourceSpan) -> String {
        String(decoding: source.utf16.dropFirst(span.location).prefix(span.length), as: UTF16.self)
    }

    private func collectTargets(_ nodes: [MarkdownInline]) -> [String] {
        var out: [String] = []
        func walk(_ nodes: [MarkdownInline]) {
            for node in nodes {
                switch node {
                case .link(_, .note(let target)): out.append(target) // labels are not descended into
                case .strong(let inner), .emphasis(let inner), .strike(let inner): walk(inner)
                default: break
                }
            }
        }
        walk(nodes)
        return out
    }

    private func paragraphTargets(_ text: String) -> [String] {
        collectTargets(MarkdownInlineParser.parse(text))
    }

    /// Single-paragraph corpus: the scanner must agree with
    /// `MarkdownInlineParser` on inline semantics exactly.
    private let inlineCorpus: [String] = [
        "See [[Alpha]] and [[Beta|the beta page]].",
        "Path links: [a](Folder/Note.md) and [b](Other) and ![img](Pic.png).",
        "Outside: [x](https://example.com/a) [m](mailto:a@b.c) [t](#top) [bad](/etc/passwd).",
        "Code hides [[Inside]] and `[[Ticks]]` links.",
        "Escaped \\[[NotALink]] stays text.",
        "**bold [[InBold]]** and _em [[InEmphasis]]_ and ~~gone [[InStrike]]~~.",
        "A ] inside a label breaks the outer link: [outer [[Inner]] label](Target).",
        "snake_case_name [[After]] more_text_here.",
        "Mixed [[One]] then [Two](two) then [[Three#section]].",
        "",
        "unclosed [[Alpha and [label](x)",
        "duplicate [[Alpha]] and again [[Alpha]] here.",
    ]

    /// Document-level corpus adds block kinds whose contexts differ from raw
    /// inline text (fences and literal HTML hide links from the graph).
    private let corpus: [String] = [
        "| a | b |\n| --- | --- |\n| [[Cell]] | x |",
        "# Heading [[InHeading]]\n\n> quote [[InQuote]]\n\n- item [[InItem]]\n",
        "title line [[InSetext]]\n===\n",
        "```\nfenced [[InFence]]\n```\n",
        "<div>\nraw [[InHTML]]\n</div>\n",
    ]

    // MARK: - Scanner equivalence

    func testScannerMatchesInlineParserTargets() {
        for text in inlineCorpus {
            let expected = paragraphTargets(text).sorted()
            let scanned = NoteLinkRepair.occurrences(in: text).map(\.target).sorted()
            XCTAssertEqual(scanned, expected, "scanner != inline parser for \(text)")
        }
    }

    func testScannerMatchesGraphLinkExtractor() {
        for text in inlineCorpus + corpus {
            let expected = Set(GraphLinkExtractor.targets(in: text).targets)
            let scanned = Set(NoteLinkRepair.occurrences(in: text).map(\.target))
            XCTAssertEqual(scanned, expected, "scanner != graph extractor for \(text)")
        }
    }

    func testEverySpanRoundTrips() {
        for text in inlineCorpus + corpus {
            for occurrence in NoteLinkRepair.occurrences(in: text) {
                XCTAssertEqual(slice(text, occurrence.targetSpan), occurrence.target,
                               "span does not round-trip in \(text)")
            }
        }
    }

    // MARK: - Recognition rules

    func testWikilinkForms() {
        let source = "[[Alpha]] [[Beta|label]] [[Folder/Page]] [[Page#sec]] [[ spaced ]] [[#anchor]]\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.target), ["Alpha", "Beta", "Folder/Page", "Page#sec", "spaced"])
        XCTAssertEqual(occurrences.map(\.form), [.wikilink, .wikilink, .wikilink, .wikilink, .wikilink])
    }

    func testMarkdownLinkForms() {
        let source = "[a](Target) [b]( Folder/Note.md ) [c](https://x.com) ![d](Pic.png) [e](#sec) [f](~root)\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.target), ["Target", "Folder/Note.md"])
        XCTAssertEqual(occurrences.map(\.form), [.markdown, .markdown])
    }

    func testCodeAndEscapesHideLinks() {
        let source = "`[[A]]` and ``[[B]]`` and \\[[C]] and [[D]]\n"
        XCTAssertEqual(NoteLinkRepair.occurrences(in: source).map(\.target), ["D"])
    }

    func testLinksInsideEmphasisCount() {
        let source = "**[[A]]** _[[B]]_ ~~[[C]]~~ snake_case [[D]]\n"
        XCTAssertEqual(NoteLinkRepair.occurrences(in: source).map(\.target), ["A", "B", "C", "D"])
    }

    func testLinksInsideLabelsDoNotCount() {
        // A `]` inside a label breaks the outer `[label](target)` form in this
        // parser; the inner wikilink becomes a top-level link and is counted.
        // A clean markdown link is counted once, not by its label content.
        let broken = "[outer [[Inner]] label](Target) plain [[Real]]\n"
        XCTAssertEqual(NoteLinkRepair.occurrences(in: broken).map(\.target), ["Inner", "Real"])
        XCTAssertEqual(paragraphTargets(broken), ["Inner", "Real"])
        let clean = "[outer *em* label](Target)\n"
        XCTAssertEqual(NoteLinkRepair.occurrences(in: clean).map(\.target), ["Target"])
    }

    func testBlockKindsPolicy() {
        let source = "# H [[A]]\n\n> q [[B]]\n\n- item [[C]]\n\n```\ncode [[D]]\n```\n\npara [[E]]\n"
        XCTAssertEqual(NoteLinkRepair.occurrences(in: source).map(\.target), ["A", "B", "C", "E"])
    }

    func testTablePolicy() {
        // A wikilink with a label pipe splits at the pipe inside tables — the
        // parser sees separate cells and no wikilink; the scanner must agree.
        // An escaped pipe keeps the cell whole, so its link is repairable.
        let source = "| head [[H]] |\n| --- |\n| body [[Cell]] |\n| [[a|b]] |\n| x \\| [[Esc]] |\n"
        let scanned = NoteLinkRepair.occurrences(in: source).map(\.target)
        XCTAssertEqual(scanned, ["H", "Cell", "Esc"])
        XCTAssertEqual(Set(GraphLinkExtractor.targets(in: source).targets), Set(scanned))
    }

    func testCRLFAndEmojiSpans() {
        let source = "# t\r\n\r\npara 🎉 with [[Al🎉pha]] link\r\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.target), ["Al🎉pha"])
        XCTAssertEqual(slice(source, occurrences[0].targetSpan), "Al🎉pha")
    }

    func testLimitedDocumentYieldsNoOccurrences() {
        let big = String(repeating: "word [[A]] ", count: 60_000) // over the 512 KB budget
        XCTAssertTrue(NoteLinkRepair.occurrences(in: big).isEmpty)
    }

    // MARK: - Inspection

    func testInspectResolutions() {
        let candidates = [
            NoteLinkCandidate(id: UUID(), title: "Alpha", path: "Alpha.md", tags: ["t"], modifiedAt: Date(timeIntervalSince1970: 1)),
            NoteLinkCandidate(id: UUID(), title: "Alpha", path: "Sub/Alpha.md", tags: [], modifiedAt: Date(timeIntervalSince1970: 2)),
            NoteLinkCandidate(id: UUID(), title: "Gamma", path: "Gamma.md", tags: [], modifiedAt: Date(timeIntervalSince1970: 3)),
        ]
        let source = "[[Alpha]] [[Gamma]] [[Nope]] [[Sub/Alpha.md]]\n"
        let inspections = NoteLinkRepair.inspect(source: source, sourcePath: "Folder/Note.md", candidates: candidates)
        XCTAssertEqual(inspections.map(\.occurrence.target), ["Alpha", "Gamma", "Nope", "Sub/Alpha.md"])
        guard case .ambiguous(let matches) = inspections[0].resolution else {
            return XCTFail("duplicate titles must be ambiguous")
        }
        XCTAssertEqual(matches.count, 2)
        guard case .unique = inspections[1].resolution else { return XCTFail("Gamma must be unique") }
        guard case .missing = inspections[2].resolution else { return XCTFail("Nope must be missing") }
        guard case .unique = inspections[3].resolution else { return XCTFail("explicit path must be unique") }
    }

    // MARK: - Replacement text

    func testReplacementTargetKeepsAuthoredForm() {
        let candidate = NoteLinkCandidate(id: UUID(), title: "New Title", path: "Sub/New Title.md", tags: [], modifiedAt: Date())
        let cases: [(String, String)] = [
            ("Old", "New Title"),                    // by title stays a title
            ("Sub/Old.md", "Sub/New Title.md"),      // explicit path keeps extension
            ("Sub/Old", "Sub/New Title"),            // explicit path without extension
            ("Old#part", "New Title#part"),          // anchors preserved
            ("Sub/Old.md#part", "Sub/New Title.md#part"),
        ]
        for (authored, expected) in cases {
            let source = "[[\(authored)]]\n"
            let occurrence = NoteLinkRepair.occurrences(in: source)[0]
            XCTAssertEqual(NoteLinkRepair.replacementTarget(candidate, for: occurrence), expected, authored)
        }
    }

    // MARK: - Confirmed edits

    func testEditRewritesOnlyTheConfirmedOccurrence() throws {
        let source = "See [[Alpha]] twice [[Alpha]] and [[Alpha#sec]].\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.target), ["Alpha", "Alpha", "Alpha#sec"])
        let edit = try NoteLinkRepair.edit(replacing: occurrences[0], with: "Beta", in: source)
        let result = try NoteLinkRepair.apply(edit, to: source)
        XCTAssertEqual(result, "See [[Beta]] twice [[Alpha]] and [[Alpha#sec]].\n")
        XCTAssertEqual(NoteLinkRepair.occurrences(in: result).map(\.target), ["Beta", "Alpha", "Alpha#sec"])
    }

    func testEditPreservesLinkLabels() throws {
        let source = "[the label](Old) and [[Old|the label]]\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.target), ["Old", "Old"])
        XCTAssertEqual(occurrences.map(\.form), [.markdown, .wikilink])
        let markdownEdit = try NoteLinkRepair.edit(replacing: occurrences[0], with: "New", in: source)
        XCTAssertEqual(try NoteLinkRepair.apply(markdownEdit, to: source), "[the label](New) and [[Old|the label]]\n")
        let wikiEdit = try NoteLinkRepair.edit(replacing: occurrences[1], with: "New", in: source)
        XCTAssertEqual(try NoteLinkRepair.apply(wikiEdit, to: source), "[the label](Old) and [[New|the label]]\n")
    }

    func testStaleEditRefused() throws {
        let source = "before [[Alpha]] after\n"
        let occurrence = NoteLinkRepair.occurrences(in: source)[0]
        let edit = try NoteLinkRepair.edit(replacing: occurrence, with: "Beta", in: source)
        let changed = "changed [[Alpha]] after\n"
        XCTAssertThrowsError(try NoteLinkRepair.apply(edit, to: changed)) { error in
            XCTAssertEqual(error as? NoteLinkRepairError, .staleSource)
        }
    }

    func testSpanMismatchRefused() throws {
        let source = "before [[Alpha]] after\n"
        let occurrence = NoteLinkRepair.occurrences(in: source)[0]
        var edit = try NoteLinkRepair.edit(replacing: occurrence, with: "Beta", in: source)
        edit = .init(occurrenceID: edit.occurrenceID, beforeTarget: edit.beforeTarget, afterTarget: edit.afterTarget,
                     targetSpan: .init(location: 0, length: edit.beforeTarget.utf16.count),
                     expectedSourceDigest: edit.expectedSourceDigest, resultingSourceDigest: edit.resultingSourceDigest)
        XCTAssertThrowsError(try NoteLinkRepair.apply(edit, to: source)) { error in
            XCTAssertEqual(error as? NoteLinkRepairError, .spanMismatch)
        }
    }

    func testBlockedReplacementsRefused() throws {
        let source = "[[Alpha]] and [b](Target)\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        for bad in ["a|b", "a]]", "", "  padded  "] {
            XCTAssertThrowsError(try NoteLinkRepair.edit(replacing: occurrences[0], with: bad, in: source), bad) { error in
                XCTAssertEqual(error as? NoteLinkRepairError, .blockedReplacement)
            }
        }
        XCTAssertThrowsError(try NoteLinkRepair.edit(replacing: occurrences[1], with: "a)b", in: source)) { error in
            XCTAssertEqual(error as? NoteLinkRepairError, .blockedReplacement)
        }
    }

    func testEditThroughParserForms() throws {
        // Headings, quotes, list items and table cells all repair in place.
        let source = "# h [[A]]\n\n> q [[B]]\n\n- i [[C]]\n\n| h2 |\n| --- |\n| [[D]] |\n"
        var working = source
        for expected in ["A", "B", "C", "D"] {
            let occurrence = try XCTUnwrap(NoteLinkRepair.occurrences(in: working).first { $0.target == expected })
            XCTAssertEqual(occurrence.target, expected)
            let edit = try NoteLinkRepair.edit(replacing: occurrence, with: expected + "x", in: working)
            working = try NoteLinkRepair.apply(edit, to: working)
        }
        XCTAssertEqual(working, "# h [[Ax]]\n\n> q [[Bx]]\n\n- i [[Cx]]\n\n| h2 |\n| --- |\n| [[Dx]] |\n")
    }

    func testAnchorAndFormRoundTrip() throws {
        let source = "[[Page#sec]]\n"
        let occurrence = NoteLinkRepair.occurrences(in: source)[0]
        let candidate = NoteLinkCandidate(id: UUID(), title: "Renamed", path: "Renamed.md", tags: [], modifiedAt: Date())
        let target = NoteLinkRepair.replacementTarget(candidate, for: occurrence)
        XCTAssertEqual(target, "Renamed#sec")
        let edit = try NoteLinkRepair.edit(replacing: occurrence, with: target, in: source)
        XCTAssertEqual(try NoteLinkRepair.apply(edit, to: source), "[[Renamed#sec]]\n")
    }

    func testOccurrencesAreOrderedWithStableIDs() {
        let source = "[[B]] mid [[A]] end [c](C)\n"
        let occurrences = NoteLinkRepair.occurrences(in: source)
        XCTAssertEqual(occurrences.map(\.id), [0, 1, 2])
        XCTAssertEqual(occurrences.map(\.target), ["B", "A", "C"])
        XCTAssertEqual(occurrences.map(\.targetSpan.location), occurrences.map(\.targetSpan.location).sorted())
    }
}
