import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Generated-data integration smoke test. Never accepts a user vault path.
@main
struct ReadingProbe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-reading-probe-" + UUID().uuidString)
        let vault = root.appendingPathComponent("vault"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 1000
        for number in 0..<count {
            let title = String(format: "Note-%04d", number)
            let text = """
            ---
            tags: [product, batch\(number % 10)]
            ---
            # \(title)

            café reading workflow with unique needle\(number).
            Search and commands remain separate. A source cursor stays anchored.

            - [ ] Review this note
            - [x] Keep its original Markdown

            | Feature | State |
            | --- | --- |
            | Preview | Native |

            ```swift
            let greeting = "👩🏽‍💻 مرحبا 日本語"
            ```
            """
            try Data(text.utf8).write(to: vault.appendingPathComponent(title + ".md"))
        }
        var checks: [String] = []
        let store = try await PlainVaultStore.open(at: vault, createIfMissing: true)
        let notes = try await store.scan()
        try require(notes.count == count, "Real Markdown import count")
        checks.append("1,000 generated Markdown files imported without rewriting")
        let project = try await store.project()
        let index = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault,
            projectID: project.id, rootIdentity: store.rootIdentity)
        let started = Date()
        let generation = try await index.beginRebuild()
        for note in notes {
            let lease = try await index.reserveUpdate(for: note.id)
            let snapshot = try await store.readNote(id: note.id)
            _ = try await index.upsert(IndexedNote(snapshot: snapshot), ticket: lease, rebuild: generation)
        }
        _ = try await index.finishRebuild(generation)
        let indexingMS = Date().timeIntervalSince(started) * 1000
        try await index.verifyIntegrity()
        checks.append("FTS5 external-content cache built outside the vault and passed integrity check")
        let match = try await index.search("\"needle42\"")
        try require(match.count == 1 && match[0].title == "Note-0042", "Unique content search")
        checks.append("Full-text query finds the expected saved note")
        let titleMatch = try await index.search("Note-0042", scope: .titles)
        try require(titleMatch.first?.id == match[0].id, "Title/path query")
        checks.append("Title/path query resolves to the same stable note ID")
        let original = try await store.readNote(id: match[0].id)
        let changed = original.markdown.replacingOccurrences(of: "needle42", with: "replacementneedle")
        guard case .written(let saved) = try await store.save(original, markdown: changed) else { throw ProbeFailure.failed("Unexpected conflict in isolated fixture") }
        let update = try await index.reserveUpdate(for: saved.note.id)
        _ = try await index.upsert(IndexedNote(snapshot: saved), ticket: update)
        let old = try await index.search("\"needle42\"")
        let fresh = try await index.search("replacementneedle")
        try require(old.isEmpty && fresh.first?.id == saved.note.id, "Incremental FTS update")
        checks.append("Saving updates the cache and removes superseded search terms")
        let preview = MarkdownParser.parse(saved.markdown)
        let codeOffset = (saved.markdown as NSString).range(of: "let greeting").location
        guard case .code = preview.block(atUTF16Offset: codeOffset)?.kind else { throw ProbeFailure.failed("UTF-16 cursor-to-code mapping") }
        checks.append("Preview maps a source cursor into its code block without changing source bytes")
        try require(try Data(contentsOf: vault.appendingPathComponent(saved.note.relativePath)) == Data(changed.utf8), "Preview leaves the file intact")
        checks.append("Preview generation leaves authored Markdown byte-identical")
        let tagged = try await index.search("batch2", scope: .tags, limit: 200)
        try require(tagged.count == 100, "Tag-scope count")
        checks.append("Tag scope returns the expected 100 notes")
        _ = try ShortcutPolicy.validated(ShortcutPolicy.defaults)
        try require(CommandCatalog.matches("split").contains(.showSplit), "Command registry")
        checks.append("Typed command registry and native-safe shortcuts validate independently of notes")

        var timings: [Double] = []
        for number in 0..<30 {
            let start = Date()
            _ = try await index.search("\"needle\(number + 100)\"")
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        timings.sort()
        let fileURL = index.fileURL
        await index.close()
        let reopened = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault,
            projectID: project.id, rootIdentity: store.rootIdentity)
        let persisted = try await reopened.search("replacementneedle")
        try require(persisted.count == 1, "Reopened index")
        checks.append("Cache reopens with its binding and updated query results intact")
        await reopened.close()
        try await LocalSearchIndex.discardCacheAfterConfirmation(cacheDirectory: cache, vaultRoot: vault,
            projectID: project.id, rootIdentity: store.rootIdentity)
        try require(!FileManager.default.fileExists(atPath: fileURL.path), "Disposable cache removal")
        try require(try Data(contentsOf: vault.appendingPathComponent(saved.note.relativePath)) == saved.bytes, "Cache removal does not alter notes")
        checks.append("Explicit cache disposal removes no Markdown or recovery data")
        await store.close()
        let report: [String: Any] = [
            "status": "PASS", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "generated_note_count": count, "check_count": checks.count, "checks": checks,
            "timings_ms": ["index_1000_notes": indexingMS, "warm_query_median": timings[timings.count / 2], "warm_query_p95": timings[Int(Double(timings.count - 1) * 0.95)]],
            "scope": "Generated temporary files; actual store, SQLite FTS5, Markdown parser and command policy",
            "not_proven": ["Mac UI/IME/undo/accessibility", "minimum-Mac energy/memory/frame budgets", "100k-note performance", "complete CommonMark/GFM conformance", "release security"]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: bytes, as: UTF8.self))
    }
    enum ProbeFailure: Error { case failed(String) }
    static func require(_ condition: Bool, _ label: String) throws { if !condition { throw ProbeFailure.failed(label) } }
}
