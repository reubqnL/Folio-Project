import Foundation

public struct NoteLinkCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let tags: [String]
    public let modifiedAt: Date
    public init(id: UUID, title: String, path: String, tags: [String] = [], modifiedAt: Date) {
        self.id = id; self.title = title; self.path = path; self.tags = tags; self.modifiedAt = modifiedAt
    }
}
public enum NoteLinkResolution: Equatable, Sendable {
    case missing
    case unique(NoteLinkCandidate)
    case ambiguous([NoteLinkCandidate])
}
public enum NoteLinkResolver {
    public static func resolve(_ rawTarget: String, from sourcePath: String, candidates: [NoteLinkCandidate]) -> NoteLinkResolution {
        let target = rawTarget.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .note = MarkdownLinkPolicy.classify(target) else { return .missing }
        let name = stripExtension(target)
        let folder = (sourcePath as NSString).deletingLastPathComponent
        let relative = folder.isEmpty ? name : folder + "/" + name
        let exact = candidates.filter {
            let path = NoteSearchQuery.fold(stripExtension($0.path))
            return path == NoteSearchQuery.fold(name) || path == NoteSearchQuery.fold(relative)
        }
        let explicitPath = name.contains("/") || target.lowercased().hasSuffix(".md") || target.lowercased().hasSuffix(".markdown")
        if explicitPath { return result(exact) }
        return result(candidates.filter { NoteSearchQuery.fold($0.title) == NoteSearchQuery.fold(name) })
    }
    private static func stripExtension(_ value: String) -> String {
        value.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
    private static func result(_ input: [NoteLinkCandidate]) -> NoteLinkResolution {
        let sorted = input.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if sorted.isEmpty { return .missing }
        if sorted.count == 1 { return .unique(sorted[0]) }
        return .ambiguous(sorted)
    }
}
