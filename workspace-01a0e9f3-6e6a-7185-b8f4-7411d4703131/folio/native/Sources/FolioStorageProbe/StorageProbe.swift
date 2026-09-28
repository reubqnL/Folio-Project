import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Developer-only executable exercising the SAME store as the app, not a UI
/// substitute. Tests use only fresh temporary folders. Never point crash tests
/// at real user work. --crash-at intentionally exits without Swift cleanup.
@main
struct StorageProbe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: folio-storage-probe <init|list|create|read|save|recover> <folder> [path/text] [--crash-at=<stage>]")
            exit(2)
        }
        do {
            let command = args[0], root = URL(fileURLWithPath: args[1], isDirectory: true)
            let store = try await PlainVaultStore.open(at: root, createIfMissing: command == "init")
            let crashName = args.first(where: { $0.hasPrefix("--crash-at=") })?.components(separatedBy: "=").last
            let pauseName = args.first(where: { $0.hasPrefix("--pause-at=") })?.components(separatedBy: "=").last
            let hooks = VaultTestHooks { stage in
                if stage.rawValue == crashName { fflush(nil); _exit(91) }
                if stage.rawValue == pauseName {
                    FileHandle.standardOutput.write(Data(("PAUSED " + stage.rawValue + "\n").utf8))
                    fflush(nil)
                    while true { _ = pause() } // Test parent must send SIGKILL.
                }
            }
            let recovery = try await store.recover()
            if command == "recover" {
                try emit(["replayed": recovery.replayed, "review": recovery.review.map { $0.explanation }])
            } else if command == "init" {
                let p = try await store.project(); try emit(["projectID": p.id.uuidString, "name": p.name])
            } else {
                let notes = try await store.scan()
                switch command {
                case "list": try emit(["notes": notes.map { ["id": $0.id.uuidString, "path": $0.relativePath] }])
                case "create":
                    guard args.count >= 4 else { throw VaultError.invalidPath }
                    let result = try await store.createNote(title: args[2], folder: "Notes", markdown: args[3], hooks: hooks)
                    try report(result)
                case "read", "save":
                    guard args.count >= 3, let n = notes.first(where: { $0.relativePath == args[2] }) else { throw VaultError.missingNote }
                    let base = try await store.readNote(id: n.id)
                    if command == "read" { try emit(["path": n.relativePath, "text": base.markdown, "revision": base.revision]) }
                    else {
                        guard args.count >= 4 else { throw VaultError.invalidPath }
                        try report(try await store.save(base, markdown: args[3], hooks: hooks))
                    }
                default: throw VaultError.invalidPath
                }
            }
            await store.close()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    static func report(_ result: VaultSaveResult) throws {
        switch result {
        case .written(let snapshot): try emit(["status": "written", "id": snapshot.note.id.uuidString, "path": snapshot.note.relativePath, "revision": snapshot.revision])
        case .conflict(let conflict): try emit(["status": "conflict", "recoveryID": conflict.id.uuidString, "explanation": conflict.explanation])
        }
    }
    static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
