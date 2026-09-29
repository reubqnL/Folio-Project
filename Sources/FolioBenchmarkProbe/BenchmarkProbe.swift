import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Large-file/long-line benchmark probe (N02; decision 26 — measured
/// large-document performance is a release gate with no waiver path,
/// decision 50).
///
/// Measures the editor-critical paths over deterministic corpora
/// (`BenchmarkCorpora`): full parse, one-keystroke incremental reparse,
/// link scan and excerpt. Timings are printed as evidence and NEVER asserted;
/// run this on the machine class that will sign the release and record the
/// output with its machine details. Never accepts a user vault path.
///
/// Usage:
///   FolioBenchmarkProbe [--json] [--samples N] [--warmup N]
/// `--json` writes one machine-readable object to stdout (the human table
/// goes to stderr so stdout stays parseable).
@main
struct BenchmarkProbe {
    struct Measurement {
        let corpus: String
        let operation: String
        let utf8Bytes: Int
        let notes: String
        let statistics: BenchmarkStatistics
        let usedFullParse: Bool?
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }

    static func run() throws {
        var json = false, samples = 7, warmup = 2
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            switch arguments.removeFirst() {
            case "--json": json = true
            case "--samples":
                guard !arguments.isEmpty, let value = Int(arguments.removeFirst()), (1...200).contains(value) else {
                    throw Failure("—samples must be an integer in 1...200")
                }
                samples = value
            case "--warmup":
                guard !arguments.isEmpty, let value = Int(arguments.removeFirst()), (0...50).contains(value) else {
                    throw Failure("—warmup must be an integer in 0...50")
                }
                warmup = value
            case let other: throw Failure("Unknown argument: \(other)")
            }
        }

        var measurements: [Measurement] = []
        for corpus in BenchmarkCorpora.standard() {
            let edited = corpus.source.replacingOccurrences(of: BenchmarkCorpora.editMarker, with: "EDIT-DONE")
            let linkTargets = NoteLinkRepair.occurrences(in: corpus.source).count

            measurements.append(try measure(corpus, "full-parse", samples: samples, warmup: warmup, notes: "MarkdownParser.parse") {
                _ = MarkdownParser.parse(corpus.source)
            })
            // Allocation-honest keystroke cost including the session's initial
            // parse; the splice-only figure is recorded separately below.
            measurements.append(try measure(corpus, "incremental-edit", samples: samples, warmup: warmup, notes: "session init + one-edit reparse") {
                var session = MarkdownReparseSession(source: corpus.source)
                _ = session.reparse(edited)
            })
            measurements.append(try measure(corpus, "link-scan", samples: samples, warmup: warmup, notes: "NoteLinkRepair.occurrences (\(linkTargets) links)") {
                _ = NoteLinkRepair.occurrences(in: corpus.source)
            })
            if corpus.utf8Bytes <= 128 * 1024 {
                measurements.append(try measure(corpus, "excerpt", samples: samples, warmup: warmup, notes: "MarkdownParser.excerpt") {
                    _ = MarkdownParser.excerpt(corpus.source)
                })
            }
        }

        // Per-keystroke splice cost alone — the number editor latency cares
        // about — on the largest parseable corpus. The session alternates
        // between the original and the one-edit variant so every sample is a
        // real single-edit reparse in both directions.
        if let large = BenchmarkCorpora.standard().first(where: { $0.name == "near-budget-note" }) {
            let edited = large.source.replacingOccurrences(of: BenchmarkCorpora.editMarker, with: "EDIT-DONE")
            var session = MarkdownReparseSession(source: large.source)
            var flip = false
            measurements.append(try measure(large, "incremental-edit-splice-only", samples: samples, warmup: warmup, notes: "reparse of one edit; session pre-built") {
                flip.toggle()
                _ = session.reparse(flip ? edited : large.source)
            })
        }

        let host = ProcessInfo.processInfo
        let header = """
        Folio benchmark probe — \(measurements.count) measurements, \(samples) samples each after \(warmup) warmups.
        Host: \(host.operatingSystemVersionString), processors \(host.activeProcessorCount), \
        processors-usable \(host.activeProcessorCount). Timings are per-machine evidence \
        (decision 26); record them with the machine class that will sign the release.
        """
        if json {
            FileHandle.standardError.write(Data((header + "\n").utf8))
            let records: [[String: Any]] = measurements.map { m in
                [
                    "corpus": m.corpus, "operation": m.operation, "utf8_bytes": m.utf8Bytes,
                    "notes": m.notes, "samples": m.statistics.samples,
                    "min_ms": m.statistics.minimum * 1000,
                    "median_ms": m.statistics.median * 1000,
                    "p95_ms": m.statistics.p95 * 1000,
                ]
            }
            let output: [String: Any] = [
                "schema": "folio-benchmarks-1",
                "host": host.operatingSystemVersionString,
                "samples": samples, "warmup": warmup,
                "measurements": records,
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
            }
            var table = header + "\n\n"
            table += pad("corpus", 20) + pad("operation", 30) + pad("median ms", 12) + pad("p95 ms", 12) + pad("min ms", 12) + "\n"
            for m in measurements {
                table += pad(m.corpus, 20) + pad(m.operation, 30)
                    + pad(String(format: "%.3f", m.statistics.median * 1000), 12)
                    + pad(String(format: "%.3f", m.statistics.p95 * 1000), 12)
                    + pad(String(format: "%.3f", m.statistics.minimum * 1000), 12) + "\n"
            }
            FileHandle.standardOutput.write(Data(table.utf8))
        }
    }

    /// Times `work` over `samples` runs after `warmup` runs; the sample is the
    /// wall time of one run. Returns one measurement record.
    static func measure(_ corpus: BenchmarkCorpus, _ operation: String, samples: Int, warmup: Int,
                        notes: String, _ work: () -> Void) throws -> Measurement {
        for _ in 0..<warmup { work() }
        var times: [Double] = []
        times.reserveCapacity(samples)
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            let end = DispatchTime.now().uptimeNanoseconds
            times.append(Double(end - start) / 1_000_000_000)
        }
        return .init(corpus: corpus.name, operation: operation, utf8Bytes: corpus.utf8Bytes,
                     notes: notes, statistics: BenchmarkStatistics(times), usedFullParse: nil)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
