import Foundation
@testable import FolioCore

enum CaptureFixtures {
    static func binding(project: UUID = UUID(), session: UUID = UUID(), note: UUID = UUID(), editor: UUID = UUID()) -> CaptureDocumentBinding {
        .init(workspace: .init(projectID: project, rootIdentity: "test-volume:test-inode", sessionID: session), noteID: note, editorID: editor)
    }
    static func target(_ text: String = "Existing note\n", binding: CaptureDocumentBinding? = nil, generation: Int = 1) throws -> CaptureTargetSnapshot {
        try .init(binding: binding ?? self.binding(), generation: generation, text: text)
    }
    static func request(_ target: CaptureTargetSnapshot, destination: CaptureDestination = .append,
                        input: String = "A useful thought to organise.", profile: SearchProfile = .balanced) throws -> PreparedCapture {
        var draft = CaptureDraft(target: target.binding)
        draft.editInput(input, kind: .typed); draft.setDestination(destination, target: target)
        return try CapturePreparation.prepare(draft, target: target, profile: profile)
    }
}
