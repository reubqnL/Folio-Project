import XCTest
import Foundation
@testable import FolioCore

/// Increment 12 — benchmark corpora and statistics. These tests pin the
/// measurement fixtures (determinism, budgets, correctness on each corpus);
/// timings themselves are never asserted — measured evidence is recorded by
/// `FolioBenchmarkProbe` on the machine class that will sign the release.
final class MarkdownBenchmarkTests: XCTestCase {

    // MARK: - Corpora

    func testCorporaAreDeterministic() {
        let first = BenchmarkCorpora.standard()
        let second = BenchmarkCorpora.standard()
        XCTAssertEqual(first, second)
        for corpus in first {
            XCTAssertEqual(corpus.source, corpus.source, corpus.name)
            XCTAssertFalse(corpus.purpose.isEmpty, corpus.name)
        }
    }

    func testCorpusNamesAndEditMarkersAreUnique() {
        let corpora = BenchmarkCorpora.standard()
        XCTAssertEqual(Set(corpora.map(\.name)).count, corpora.count)
        for corpus in corpora {
            let occurrences = corpus.source.components(separatedBy: BenchmarkCorpora.editMarker).count - 1
            XCTAssertEqual(occurrences, 1, "\(corpus.name) must contain exactly one edit marker")
        }
    }

    func testCorpusSizesRespectTheBudgetsTheyTarget() throws {
        let corpora = Dictionary(uniqueKeysWithValues: BenchmarkCorpora.standard().map { ($0.name, $0) })
        // near-budget sits under the 512 KB parse budget, over-budget over it.
        let near = try XCTUnwrap(corpora["near-budget-note"])
        XCTAssertGreaterThan(near.utf8Bytes, 400 * 1024)
        XCTAssertLessThanOrEqual(near.utf8Bytes, 512 * 1024)
        let over = try XCTUnwrap(corpora["over-budget-note"])
        XCTAssertGreaterThan(over.utf8Bytes, 512 * 1024)
        // long-lines stays under the 32K per-line cap.
        let long = try XCTUnwrap(corpora["long-lines"])
        for line in long.source.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.utf16.count, 32 * 1024)
        }
    }

    func testCorporaParseAsIntended() throws {
        for corpus in BenchmarkCorpora.standard() {
            let document = MarkdownParser.parse(corpus.source)
            if corpus.name == "over-budget-note" {
                XCTAssertTrue(document.isLimited, corpus.name)
            } else {
                XCTAssertNil(document.limitation, corpus.name)
                XCTAssertFalse(document.blocks.isEmpty, corpus.name)
            }
        }
        let many = try XCTUnwrap(BenchmarkCorpora.standard().first { $0.name == "many-blocks" })
        let document = MarkdownParser.parse(many.source)
        XCTAssertLessThanOrEqual(document.blocks.count, 10_000)
        XCTAssertGreaterThan(document.blocks.count, 9_000)
    }

    func testIncrementalEditIsParseEqualOnEveryCorpus() {
        for corpus in BenchmarkCorpora.standard() {
            let edited = corpus.source.replacingOccurrences(of: BenchmarkCorpora.editMarker, with: "EDIT-DONE")
            var session = MarkdownReparseSession(source: corpus.source)
            let result = session.reparse(edited)
            XCTAssertEqual(result.document, MarkdownParser.parse(edited), corpus.name)
        }
    }

    func testLinkScanFindsMixedConstructs() {
        let mixed = BenchmarkCorpora.standard().first { $0.name == "mixed-constructs" }
        XCTAssertNotNil(mixed)
        guard let mixed else { return }
        let occurrences = NoteLinkRepair.occurrences(in: mixed.source)
        XCTAssertGreaterThan(occurrences.count, 200)
        for occurrence in occurrences {
            let slice = String(decoding: mixed.source.utf16.dropFirst(occurrence.targetSpan.location).prefix(occurrence.targetSpan.length), as: UTF16.self)
            XCTAssertEqual(slice, occurrence.target)
        }
    }

    // MARK: - Statistics

    func testMedianOddAndEven() {
        XCTAssertEqual(BenchmarkStatistics([3, 1, 2]).median, 2, accuracy: 1e-12)
        XCTAssertEqual(BenchmarkStatistics([4, 1, 3, 2]).median, 2.5, accuracy: 1e-12)
    }

    func testPercentileNearestRank() {
        // 20 samples: nearest-rank p95 index = ceil(0.95*20) - 1 = 18.
        let samples = (1...20).map(Double.init)
        let statistics = BenchmarkStatistics(samples)
        XCTAssertEqual(statistics.p95, 19, accuracy: 1e-12)
        XCTAssertEqual(statistics.minimum, 1, accuracy: 1e-12)
        XCTAssertEqual(statistics.samples, 20)
        // One sample: everything is that sample.
        let single = BenchmarkStatistics([7])
        XCTAssertEqual(single.p95, 7, accuracy: 1e-12)
        XCTAssertEqual(single.median, 7, accuracy: 1e-12)
    }

    func testStatisticsNeverTrapOnEmptyInput() {
        let empty = BenchmarkStatistics([])
        XCTAssertEqual(empty.samples, 0)
        XCTAssertEqual(empty.median, 0)
        XCTAssertEqual(empty.p95, 0)
        XCTAssertEqual(empty.minimum, 0)
    }
}
