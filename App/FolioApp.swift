import SwiftUI
import AppKit
import Combine
import FolioCore

@main
@MainActor
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(FolioApplicationDelegate.self) private var appDelegate
    @State private var session = WorkspaceSession()

    var body: some Scene {
        Window("Folio", id: "main") {
            RootView(session: session)
                .frame(
                    minWidth: WorkspaceLayoutPolicy.minimumWindowWidth,
                    minHeight: WorkspaceLayoutPolicy.minimumWindowHeight
                )
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.session = session }
        }
        .defaultSize(
            width: WorkspaceLayoutPolicy.defaultWindowWidth,
            height: WorkspaceLayoutPolicy.defaultWindowHeight
        )
        // Without this the window can be dragged narrower than the content
        // minimum. AppKit then clips the content view, which is how toolbar and
        // pane controls ended up outside the window where they could not be
        // seen or clicked. `contentMinSize` refuses the resize instead.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                MappedCommandButton(session: session, command: .openProject)
                MappedCommandButton(session: session, command: .newNote)
            }
            CommandGroup(after: .newItem) { MappedCommandButton(session: session, command: .save) }
            CommandGroup(after: .textEditing) {
                Button("Find in Note…") { session.findInNoteRequest = UUID() }
                    .keyboardShortcut("f")
                    .disabled(session.selectedDocument == nil || session.selectedDocument?.editorPresentation == .preview)
            }
            CommandMenu("Navigate") {
                MappedCommandButton(session: session, command: .searchNotes)
                MappedCommandButton(session: session, command: .commandPalette)
                MappedCommandButton(session: session, command: .capture)
                Divider()
                MappedCommandButton(session: session, command: .showRoadmap)
                MappedCommandButton(session: session, command: .showConnections)
                MappedCommandButton(session: session, command: .newRoadmapItem)
                MappedCommandButton(session: session, command: .undoRoadmap)
                MappedCommandButton(session: session, command: .redoRoadmap)
                Divider()
                MappedCommandButton(session: session, command: .refresh)
                MappedCommandButton(session: session, command: .recovery)
                MappedCommandButton(session: session, command: .rebuildSearch)
                Divider()
                MappedCommandButton(session: session, command: .showLauncher)
            }
            // Deliberately not called "View": macOS already supplies a View
            // menu, and a second one with the same title is worse than a clear name.
            CommandMenu("Workspace") {
                // The workspace panes are hidden only when asked for here or in
                // the toolbar. Nothing disappears because a window was resized.
                // Deliberately no hard-coded shortcut: `ShortcutPolicy` owns the
                // chord table, and ⌥⌘1/⌥⌘2/⌥⌘3 already mean Source/Preview/Split.
                // A menu item here can never shadow a remapped command.
                Button(session.showsExplorer ? "Hide Project Sidebar" : "Show Project Sidebar") {
                    session.showsExplorer.toggle()
                }
                .disabled(session.destination != .notes)
                Button(session.showsAssistant ? "Hide Capture Panel" : "Show Capture Panel") {
                    session.showsAssistant.toggle()
                }
                .disabled(session.destination != .notes)
                Divider()
                Button(session.showsExplorer && session.showsAssistant ? "Hide Both Panels" : "Show Both Panels") {
                    let show = !(session.showsExplorer && session.showsAssistant)
                    session.showsExplorer = show
                    session.showsAssistant = show
                }
                .disabled(session.destination != .notes)
            }
            CommandMenu("Editor") {
                MappedCommandButton(session: session, command: .showSource)
                MappedCommandButton(session: session, command: .showPreview)
                MappedCommandButton(session: session, command: .showSplit)
                Divider()
                MappedCommandButton(session: session, command: .followCursor)
            }
        }
        Settings {
            FolioSettingsView(session: session)
                .preferredColorScheme(.dark).tint(FolioStyle.gold)
                .onAppear { session.clearPasteNotice() }
        }
    }
}

@MainActor
final class FolioApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var session: WorkspaceSession?
    private var terminationPending = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { session?.destination = .launcher }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        session.stopVoiceBeforeQuit()
        if terminationPending { return .terminateLater }
        if session.isOpening || session.showingNewNote || session.planning.isSaving || session.planning.editRequest != nil || session.capture.isApplying { return .terminateCancel }
        guard session.hasUnwrittenChanges || session.hasOpenEncryptedProject else { return .terminateNow }
        terminationPending = true
        Task { @MainActor [weak self] in
            let saved = await session.prepareToQuit()
            var quit = saved
            if !saved {
                let alert = NSAlert()
                alert.messageText = "Some changes have not been written safely."
                alert.informativeText = "A save error, external conflict or unapplied capture/transcript is still unresolved. Recovery copies may be available for note edits, but capture text may exist only in memory. Keep working to resolve the issue or copy your text."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Keep Working")
                alert.addButton(withTitle: "Discard Unwritten Edits and Quit")
                quit = alert.runModal() == .alertSecondButtonReturn
            }
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}

struct RootView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch session.destination {
            case .launcher: LauncherView(session: session)
            case .notes: NotesWorkspaceView(session: session)
            case .encrypted:
                EncryptedProjectView(controller: session.encrypted,
                    onBack: {
                        Task {
                            await session.encrypted.lock()
                            session.destination = .launcher
                        }
                    },
                    onImportCurrent: session.project == nil ? nil : { session.preparePlainProjectForEncryptedCopy() },
                    copyIsPreparing: session.preparingEncryptedCopy,
                    copyCompleted: session.encryptedCopyCompleted,
                    copyTotal: session.encryptedCopyTotal,
                    copyMessage: session.encryptedCopyMessage,
                    onCancelCopy: { session.cancelEncryptedCopyPreparation() })
            }
        }
        .background(FolioStyle.canvas).tint(FolioStyle.gold)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.destination)
        .sheet(isPresented: $session.showingNewNote) { NewNoteSheet(session: session) }
        .sheet(isPresented: $session.showingRecovery) { RecoveryView(session: session) }
        .sheet(isPresented: $session.showingSearch) { NoteSearchView(session: session, search: session.search) }
        .sheet(isPresented: $session.showingCommands) { CommandPaletteView(session: session) }
        .sheet(isPresented: $session.capture.showingComposer, onDismiss: { session.captureComposerDidClose() }) {
            VStack(alignment: .trailing, spacing: 0) {
                Button("Close Composer") { session.capture.showingComposer = false }.keyboardShortcut(.cancelAction).padding(12)
                CapturePanel(session: session, capture: session.capture)
            }.frame(width: 610, height: 780)
        }
        .sheet(isPresented: $session.capture.showingReview) { CaptureReviewView(session: session, capture: session.capture) }
        .sheet(isPresented: $session.speech.showingRecorder) { VoiceCaptureView(session: session, speech: session.speech) }
        .sheet(item: $session.linkChoice) { NoteLinkChoiceView(session: session, choice: $0) }
        .sheet(isPresented: $session.showingLinkRepair) { LinkRepairView(session: session) }
        .alert("Folio needs your attention", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await session.refreshProject() }
        }
    }
}

enum FolioStyle {
    static let canvas = Color(red: 0.082, green: 0.09, blue: 0.11)
    static let editor = Color(red: 0.11, green: 0.118, blue: 0.141)
    static let sidebar = Color(red: 0.098, green: 0.106, blue: 0.129)
    static let gold = Color(red: 0.922, green: 0.765, blue: 0.42)
}
