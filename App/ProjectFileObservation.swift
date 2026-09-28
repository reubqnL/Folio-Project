import Foundation
import Dispatch
import Darwin

/// Development-stage active-file and parent-directory observation. This is not
/// yet the recursive, loss-reconciling FSEvents indexer required for large vaults.
/// A directory source notices atomic replacement; callers rebind after events.
final class ProjectFileObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []

    func observe(file: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        var created: [DispatchSourceFileSystemObject] = []
        for url in [file, file.deletingLastPathComponent()] {
            let fd = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
                queue: .main
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            created.append(source)
        }
        lock.lock(); sources = created; lock.unlock()
    }
    func stop() {
        lock.lock(); let old = sources; sources = []; lock.unlock()
        for source in old { source.setEventHandler(handler: nil); source.cancel() }
    }
    deinit { stop() }
}

/// Grant lifetime is kept for the complete project session, not merely the panel.
final class ScopedProjectFolder {
    let url: URL
    private let didStart: Bool
    init(_ url: URL) { self.url = url; didStart = url.startAccessingSecurityScopedResource() }
    deinit { if didStart { url.stopAccessingSecurityScopedResource() } }
}
