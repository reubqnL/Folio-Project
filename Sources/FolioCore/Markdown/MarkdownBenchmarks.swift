import Foundation

// Increment 12 — large-file/long-line benchmarks (N02; decision 26 makes
// measured large-document performance a release gate; decision 50 gives the
// gate no waiver path).
//
// Corpora and statistics are deterministic pure functions so measurements are
// comparable across machines and runs. This module measures nothing itself —
// `FolioBenchmarkProbe` times the editor-critical paths over these corpora and
// records the results as evidence. Timings are never asserted in tests.

/// One named, deterministic benchmark input.
public struct BenchmarkCorpus: Equatable, Sendable {
    public let name: String
    public let purpose: String
    public let source: String
    public init(name: String, purpose: String, source: String) {
        self.name = name; self.purpose = purpose; self.source = source
    }
    public var utf8Bytes: Int { source.utf8.count }
}

public enum BenchmarkCorpora {
    /// Marker replaced during incremental-edit measurements. Corpora embed
    /// exactly one; replacement keeps length so offsets stay stable.
    public static let editMarker = "EDIT-MARK"

    /// Stable corpus set. Names and shapes are evidence API: recorded
    /// measurements refer to them by name and must remain comparable.
    ///
    /// Sizes are chosen against `MarkdownLimits` (512 KB utf8, 32K-line
    /// utf16, 10K blocks): `near-budget-note` sits just under the parse
    /// budget and `over-budget-note` just over it so the limitation path is
    /// measured too.
    public static func standard() -> [BenchmarkCorpus] {
        [
            smallNote(),
            largeNote(targetBytes: 256 * 1024),
            largeNote(targetBytes: 500 * 1024).renamed("near-budget-note", purpose: "Just under the 512 KB parse budget; the large-file edge editors must survive."),
            overBudgetNote(),
            longLines(),
            manyBlocks(),
            mixedConstructs(),
        ]
    }

    private static func smallNote() -> BenchmarkCorpus {
        let body = """
        ---
        tags: [benchmark, small]
        ---
        # Small note

        A realistic short note with **bold**, *italic*, a [[wiki link]] and a
        [markdown link](Other Note). The quick brown fox jumps over the lazy dog.

        - [ ] one task
        - [x] done task

        | Column | Value |
        | --- | --- |
        | rows | 1 |

        > A quotation with `inline code`.

        ```
        // a fence
        let value = 1
        ```

        Final paragraph holding the \(editMarker).
        """
        return .init(name: "small-note", purpose: "A realistic short note; baseline per-keystroke cost.", source: body + "\n")
    }

    /// Repeating section generator: heading, paragraphs, list, table, quote.
    private static func sections(count: Int, markerAtSection: Int) -> String {
        var out = ""
        for index in 0..<count {
            out += "## Section \(index)\n\n"
            out += "Paragraph \(index) with **bold** text and a [[Link \(index % 50)]] reference. "
            out += String(repeating: "Filler sentence for realistic density. ", count: 6) + "\n\n"
            out += "- item \(index)a\n- item \(index)b\n\n"
            out += "| a | b |\n| --- | --- |\n| \(index) | x |\n\n"
            out += "> quote line \(index)\n\n"
            if index == markerAtSection {
                out += "Marker paragraph \(editMarker) here.\n\n"
            }
        }
        return out
    }

    private static func largeNote(targetBytes: Int) -> BenchmarkCorpus {
        // Grow by fixed section batches until the byte target is reached;
        // overshoot is bounded by one batch, keeping near-budget under the cap.
        var body = ""
        while body.utf8.count < targetBytes {
            body += sections(count: 8, markerAtSection: -1)
        }
        body += "Marker paragraph \(editMarker) here.\n"
        return .init(name: "large-note-\(targetBytes / 1024)kb",
                     purpose: "Large document built from mixed constructs; editor responsiveness target.",
                     source: body)
    }

    private static func overBudgetNote() -> BenchmarkCorpus {
        var body = sections(count: 64, markerAtSection: 32)
        while body.utf8.count <= 512 * 1024 {
            body += sections(count: 8, markerAtSection: -1)
        }
        return .init(name: "over-budget-note",
                     purpose: "Just over the 512 KB parse budget; measures the limitation/excerpt path.",
                     source: body)
    }

    private static func longLines() -> BenchmarkCorpus {
        var lines: [String] = ["# Long lines", ""]
        for index in 0..<16 {
            let fill = String(repeating: "w", count: 30_000)
            lines.append("Line \(index) \(fill) tail.")
        }
        lines.append("")
        lines.append("End of long lines holding the \(editMarker).")
        return .init(name: "long-lines",
                     purpose: "16 lines of ~30K characters, just under the line-length cap and the size budget.",
                     source: lines.joined(separator: "\n") + "\n")
    }

    private static func manyBlocks() -> BenchmarkCorpus {
        var out = "# Many blocks\n\n"
        var index = 0
        while index < 9_990 {
            out += "Block \(index) text.\n\n"
            index += 1
        }
        out += "The final block holds the \(editMarker).\n"
        return .init(name: "many-blocks",
                     purpose: "Just under the 10,000-block rendering budget.",
                     source: out)
    }

    private static func mixedConstructs() -> BenchmarkCorpus {
        var out = "---\ntitle: Mixed\ntags: [a, b]\n---\n\n"
        out += "Setext heading \(editMarker)\n===\n\n"
        out += "## ATX\n\n"
        for index in 0..<200 {
            out += "Para \(index) with 🎉 emoji, [[Wiki \(index % 20)]], [md](Note \(index % 20)), `code`, ~~strike~~, **bold**.\n\n"
            out += "| h | i |\n| --- | --- |\n| \\| escaped | [[c\(index)]] |\n\n"
            out += "> quote [[q\(index)]]\n\n- list [[l\(index)]]\n\n"
            out += "```\nfenced [[f\(index)]]\n```\n\n"
        }
        return .init(name: "mixed-constructs",
                     purpose: "Front matter, setext, tables with escapes, emoji, wikilinks; link-scan and reparse stress.",
                     source: out)
    }
}

private extension BenchmarkCorpus {
    func renamed(_ name: String, purpose: String) -> BenchmarkCorpus {
        .init(name: name, purpose: purpose, source: source)
    }
}

/// Timing summary over repeated samples. Definitions (documented because
/// evidence must be reproducible):
/// - `median`: sorted middle value; for even counts the mean of the two
///   middle values.
/// - `p95`: nearest-rank — `sorted[ceil(0.95 * n) - 1]`.
/// Times are seconds. Empty input yields `samples == 0` and zeroed values;
/// statistics never trap.
public struct BenchmarkStatistics: Equatable, Sendable {
    public let samples: Int
    public let minimum: Double
    public let median: Double
    public let p95: Double

    public init(_ seconds: [Double]) {
        guard !seconds.isEmpty else {
            samples = 0; minimum = 0; median = 0; p95 = 0
            return
        }
        let sorted = seconds.sorted()
        samples = sorted.count
        minimum = sorted[0]
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        let p95Index = min(sorted.count - 1, max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1))
        p95 = sorted[p95Index]
    }
}
