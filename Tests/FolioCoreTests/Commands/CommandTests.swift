import XCTest
@testable import FolioCore

final class CommandTests: XCTestCase {
    func testDefaultsAreUniqueAndValid() throws {
        let defaults = try ShortcutPolicy.validated(ShortcutPolicy.defaults)
        XCTAssertEqual(Set(defaults.values).count, FolioCommandID.allCases.count)
    }
    func testTextEditingAndSystemShortcutsAreProtected() {
        for key in ["c", "v", "x", "a", "z", "q", "w", "h", "m", "f"] {
            XCTAssertThrowsError(try ShortcutPolicy.validate(.init(key: key, modifiers: [.command]), for: .searchNotes, in: [:]))
        }
        XCTAssertThrowsError(try ShortcutPolicy.validate(.init(key: "k", modifiers: [.command, .control, .option]), for: .searchNotes, in: [:]))
    }
    func testSingleLetterAndInvalidKeysAreRejected() {
        for shortcut in [CommandShortcut(key: "k", modifiers: []), .init(key: "kk", modifiers: [.command]), .init(key: "😀", modifiers: [.command])] {
            XCTAssertThrowsError(try ShortcutPolicy.validate(shortcut, for: .searchNotes, in: [:]))
        }
    }
    func testConflictsAreNamedNotSilentlyRebound() {
        XCTAssertThrowsError(try ShortcutPolicy.validate(FolioCommandID.save.defaultShortcut, for: .searchNotes, in: ShortcutPolicy.defaults)) { error in
            XCTAssertEqual(error as? ShortcutError, .duplicate("Save Note"))
        }
    }
    func testValidCustomBindingIsAccepted() throws {
        var changed = ShortcutPolicy.defaults
        changed[.searchNotes] = .init(key: "k", modifiers: [.command, .shift])
        let validated = try ShortcutPolicy.validated(changed)
        XCTAssertEqual(validated[.searchNotes]?.label, "⇧⌘K")
    }
    func testNoProjectDisablesDataCommandsButNotLauncher() {
        let context = CommandContext(hasProject: false, hasNote: false, busy: false)
        XCTAssertNotNil(context.disabledReason(for: .save))
        XCTAssertNotNil(context.disabledReason(for: .newNote))
        XCTAssertNotNil(context.disabledReason(for: .searchNotes))
        XCTAssertNil(context.disabledReason(for: .showLauncher))
    }
    func testFollowRequiresPreviewAndNeverImpliesAutoScroll() {
        let source = CommandContext(hasProject: true, hasNote: true, busy: false, editorMode: .source)
        XCTAssertNotNil(source.disabledReason(for: .followCursor))
        let split = CommandContext(hasProject: true, hasNote: true, busy: false, editorMode: .split)
        XCTAssertNil(split.disabledReason(for: .followCursor))
        XCTAssertTrue(EditorNavigationPolicy().previewFollowsOnlyOnExplicitAction)
    }
    func testCommandSearchUsesActionsNotNoteContent() {
        XCTAssertTrue(CommandCatalog.matches("recovery").contains(.recovery))
        XCTAssertEqual(CommandCatalog.matches("split"), [.showSplit])
        XCTAssertTrue(CommandCatalog.matches("some private document text").isEmpty)
    }
    func testBusyStateBlocksWrites() {
        let context = CommandContext(hasProject: true, hasNote: true, busy: true)
        XCTAssertNotNil(context.disabledReason(for: .save))
        XCTAssertNotNil(context.disabledReason(for: .openProject))
    }
    func testNoDeveloperExecutionCommandExists() {
        XCTAssertFalse(FolioCommandID.allCases.contains { $0.rawValue.lowercased().contains("execute") || $0.rawValue.lowercased().contains("foliodev") })
    }
    func testRepairLinksCommandIsReachableAndNoteScoped() {
        XCTAssertTrue(CommandCatalog.matches("repair").contains(.repairLinks))
        XCTAssertTrue(CommandCatalog.matches("broken link").contains(.repairLinks))
        let noNote = CommandContext(hasProject: true, hasNote: false, busy: false)
        XCTAssertNotNil(noNote.disabledReason(for: .repairLinks))
        let withNote = CommandContext(hasProject: true, hasNote: true, busy: false)
        XCTAssertNil(withNote.disabledReason(for: .repairLinks))
        XCTAssertNoThrow(try ShortcutPolicy.validate(FolioCommandID.repairLinks.defaultShortcut,
                                                     for: .repairLinks, in: ShortcutPolicy.defaults))
    }
}
