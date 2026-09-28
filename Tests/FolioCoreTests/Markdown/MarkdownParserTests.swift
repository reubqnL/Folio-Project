import XCTest
@testable import FolioCore

final class MarkdownParserTests: XCTestCase {
    func testHeadingsParagraphsAndSetext() {
        let document = MarkdownParser.parse("# Heading\n\nA paragraph.\n\nSubheading\n---\n")
        XCTAssertEqual(document.blocks.count, 3)
        guard case .heading(let level, let tokens) = document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(level, 1); XCTAssertEqual(MarkdownText.plain(tokens), "Heading")
        guard case .heading(let sublevel, _) = document.blocks[2].kind else { return XCTFail() }
        XCTAssertEqual(sublevel, 2)
    }
    func testFencedCodeDoesNotCreateLinksOrHeadings() {
        let doc = MarkdownParser.parse("```swift\n# not a heading\n[[not a link]]\n```\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .code(let language, let text) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(language, "swift"); XCTAssertTrue(text.contains("[[not a link]]"))
    }
    func testLongerFenceCanContainShorterFence() {
        let doc = MarkdownParser.parse("````md\n```\nexample\n```\n````\n")
        guard case .code(_, let text) = doc.blocks.first?.kind else { return XCTFail() }
        XCTAssertEqual(text, "```\nexample\n```")
    }
    func testUnclosedFenceIsExplicitAndBounded() {
        let doc = MarkdownParser.parse("~~~text\ncontent\n")
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertFalse(doc.warnings.isEmpty)
    }
    func testCRLFAndEmojiSourceOffsetsUseUTF16() {
        let text = "# 👩🏽‍💻\r\n\r\nSecond 😀 paragraph\r\n"
        let doc = MarkdownParser.parse(text)
        XCTAssertEqual(doc.sourceUTF16Length, text.utf16.count)
        let offset = (text as NSString).range(of: "Second").location
        XCTAssertEqual(doc.blocks[1].source.location, offset)
        XCTAssertEqual(doc.block(atUTF16Offset: offset + 2)?.id, doc.blocks[1].id)
        XCTAssertEqual(doc.block(atUTF16Offset: -100)?.id, doc.blocks[0].id)
        XCTAssertEqual(doc.block(atUTF16Offset: Int.max)?.id, doc.blocks.last?.id)
    }
    func testTableAndTaskList() {
        let doc = MarkdownParser.parse("| Name | State |\n| :--- | ---: |\n| A | Done |\n\n- [x] Ship\n- [ ] Review\n")
        guard case .table(let headings, let rows, let align) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(headings.count, 2); XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(align, [.left, .right])
        guard case .listItem(_, _, let checked, _) = doc.blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(checked, true)
    }
    func testEscapedPipeAndCodePipeDoNotSplitTableCells() {
        let doc = MarkdownParser.parse("| A | B |\n| --- | --- |\n| x\\|y | `a|b` |\n")
        guard case .table(_, let rows, _) = doc.blocks.first?.kind else { return XCTFail() }
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(MarkdownText.plain(rows[0][0]), "x|y")
        XCTAssertEqual(MarkdownText.plain(rows[0][1]), "a|b")
    }
    func testRawHTMLRemainsLiteral() {
        let doc = MarkdownParser.parse("<script src=\"https://example.invalid/steal\">boom</script>\n")
        guard case .literalHTML(let text) = doc.blocks.first?.kind else { return XCTFail() }
        XCTAssertTrue(text.contains("<script")); XCTAssertFalse(doc.warnings.isEmpty)
    }
    func testImagesAreOnlyPlaceholderNodes() {
        let tokens = MarkdownInlineParser.parse("![Private image](https://example.invalid/track.png)")
        XCTAssertEqual(tokens, [.image(alt: "Private image", destination: "https://example.invalid/track.png")])
    }
    func testUnsafeURLsAndCredentialsAreBlocked() {
        for value in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "https://user:secret@example.com/", "mailto:a@b.invalid%0d%0aBcc:other@x.invalid", "../outside.md", "/absolute.md"] {
            guard case .blocked = MarkdownLinkPolicy.classify(value) else { XCTFail(value); continue }
        }
        guard case .external = MarkdownLinkPolicy.classify("https://example.com/path") else { return XCTFail() }
    }
    func testWikilinkAliasAndSafeMarkdownLink() {
        let wiki = MarkdownInlineParser.parse("[[Launch plan|the plan]]")
        XCTAssertEqual(wiki, [.link(label: [.text("the plan")], destination: .note("Launch plan"))])
        let link = MarkdownInlineParser.parse("[Example](https://example.com)")
        XCTAssertEqual(link, [.link(label: [.text("Example")], destination: .external("https://example.com"))])
    }
    func testInlineFormattingAndEscapes() {
        let tokens = MarkdownInlineParser.parse("**bold** *italic* ~~gone~~ `code` \\*literal\\*")
        XCTAssertTrue(tokens.contains(.strong([.text("bold")])))
        XCTAssertTrue(tokens.contains(.emphasis([.text("italic")])))
        XCTAssertTrue(tokens.contains(.strike([.text("gone")])))
        XCTAssertTrue(tokens.contains(.code("code")))
        XCTAssertTrue(MarkdownText.plain(tokens).contains("*literal*"))
    }
    func testFrontMatterStaysSeparateWithoutRewritingSource() {
        let input = "\u{FEFF}---\r\ntags: [work, plan]\r\ncustom: !something\r\n---\r\n# Note\r\n"
        let document = MarkdownParser.parse(input)
        guard case .metadata(let metadata) = document.blocks.first?.kind else { return XCTFail() }
        XCTAssertTrue(metadata.contains("custom: !something"))
        XCTAssertEqual(document.sourceUTF16Length, input.utf16.count)
    }
    func testStableBlockIDsSurviveEarlierInsertion() {
        let before = MarkdownParser.parse("# First\n\nParagraph unchanged.\n")
        let after = MarkdownParser.parse("Intro\n\n# First\n\nParagraph unchanged.\n")
        XCTAssertEqual(before.blocks.last?.id, after.blocks.last?.id)
        XCTAssertNotEqual(before.blocks.last?.source.location, after.blocks.last?.source.location)
    }
    func testRepeatedIdenticalBlocksHaveDistinctIDs() {
        let doc = MarkdownParser.parse("Repeat\n\nRepeat\n\nRepeat\n")
        XCTAssertEqual(Set(doc.blocks.map(\.id)).count, 3)
    }
    func testLargeNoteRequiresExplicitPreviewChoice() {
        var limits = MarkdownLimits(); limits.maximumUTF8Bytes = 10
        let doc = MarkdownParser.parse("Longer than ten bytes", limits: limits)
        XCTAssertTrue(doc.isLimited); XCTAssertTrue(doc.blocks.isEmpty)
    }
    func testLongLineRequiresExplicitPreviewChoice() {
        var limits = MarkdownLimits(); limits.maximumLineUTF16 = 8
        XCTAssertTrue(MarkdownParser.parse("0123456789", limits: limits).isLimited)
    }
    func testExcerptDoesNotSplitGraphemeCluster() {
        let emoji = "👩🏽‍💻"
        XCTAssertEqual(MarkdownParser.excerpt("A" + emoji + "B", maximumUTF8Bytes: 4), "A")
        XCTAssertEqual(MarkdownParser.excerpt(emoji + "B", maximumUTF8Bytes: emoji.utf8.count), emoji)
    }
    func testAdversarialUnclosedDelimitersRemainLiteral() {
        let text = String(repeating: "[", count: 30_000)
        let parsed = MarkdownInlineParser.parse(text)
        XCTAssertEqual(MarkdownText.plain(parsed), text)
    }
    func testEmptyDocumentHasNoFollowTarget() {
        let doc = MarkdownParser.parse("")
        XCTAssertTrue(doc.blocks.isEmpty); XCTAssertNil(doc.block(atUTF16Offset: 0))
    }
    func testBareDuplicateTitlesRequireChooser() {
        let notes = [
            NoteLinkCandidate(id: UUID(), title: "Plan", path: "A/Plan.md", modifiedAt: .now),
            NoteLinkCandidate(id: UUID(), title: "Plan", path: "B/Plan.md", modifiedAt: .now)
        ]
        guard case .ambiguous(let matches) = NoteLinkResolver.resolve("Plan", from: "A/Current.md", candidates: notes) else { return XCTFail() }
        XCTAssertEqual(matches.count, 2)
        guard case .unique(let chosen) = NoteLinkResolver.resolve("B/Plan.md", from: "A/Current.md", candidates: notes) else { return XCTFail() }
        XCTAssertEqual(chosen.path, "B/Plan.md")
    }
    func testLinkResolutionNeverOpensAnUnknownPath() {
        XCTAssertEqual(NoteLinkResolver.resolve("../secret.md", from: "Notes/Here.md", candidates: []), .missing)
        XCTAssertEqual(NoteLinkResolver.resolve("Missing", from: "Notes/Here.md", candidates: []), .missing)
    }
    func testExplicitExcerptAlsoHandlesOneExtremelyLongLine() {
        let text = String(repeating: "x", count: 40_000)
        XCTAssertTrue(MarkdownParser.parse(text).isLimited)
        let excerpt = MarkdownParser.excerpt(text)
        XCTAssertLessThanOrEqual(excerpt.utf16.count, 8192)
        XCTAssertFalse(MarkdownParser.parse(excerpt).isLimited)
    }

}
