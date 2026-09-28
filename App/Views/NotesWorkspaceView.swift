import SwiftUI
import FolioCore

struct NotesWorkspaceView: View {
    @Bindable var session: WorkspaceSession
    @State private var filter = ""
    @State private var showingNotePicker = false

    private var filteredNotes: [VaultNote] {
        filter.isEmpty ? session.notes : session.notes.filter { $0.relativePath.localizedStandardContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label("Plain vault", systemImage: "folder")
                    .font(.callout.weight(.semibold)).foregroundStyle(FolioStyle.gold)
                Text(session.project?.name ?? "No project open").font(.callout)
                Spacer()
                if session.speech.isMicrophoneActive {
                    Label("Microphone on", systemImage: "mic.fill").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    Button("Stop") { session.speech.haltForDisappearance() }.controlSize(.small)
                }
                Text("Folio sync off · .rdm unavailable").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .help("Notes, recovery copies and the private app search cache are plaintext. The search cache is outside the vault. Other applications may read or sync the folder. Folio encryption and collaboration are not implemented.")
            Divider()
            if let notice = session.notice {
                HStack {
                    Text(notice).font(.caption).lineLimit(3)
                    Spacer()
                    Button { session.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("Dismiss project notice")
                }.padding(10).background(FolioStyle.gold.opacity(0.07))
            }
            GeometryReader { geometry in
                let panes = PaneVisibility.writingFirst(availableWidth: Double(geometry.size.width))
                HStack(spacing: 0) {
                    if panes.explorer { explorer.frame(width: 240); Divider() }
                    ZStack {
                        editor.frame(maxWidth: .infinity, maxHeight: .infinity).id("editor-area")
                            .opacity(session.workspaceSection == .notes ? 1 : 0)
                            .allowsHitTesting(session.workspaceSection == .notes)
                            .accessibilityHidden(session.workspaceSection != .notes)
                        if session.workspaceSection == .roadmap { RoadmapView(session: session, planning: session.planning) }
                        if session.workspaceSection == .connections { ConnectionsView(session: session, graph: session.connections, isActive: true) }
                    }
                    if panes.assistant && session.workspaceSection == .notes { Divider(); assistant.frame(width: 250) }
                }
            }
            Divider()
            HStack {
                if session.isOpening { ProgressView().controlSize(.small); Text("Opening project…") }
                else { Text(session.workspaceSection == .roadmap ? session.planning.status : session.selectedDocument?.status ?? "Choose a local project folder") }
                Spacer()
                Text("Development build · use copies").foregroundStyle(FolioStyle.gold)
            }
            .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { session.destination = .launcher } label: { Label("Launcher", systemImage: "square.grid.2x2") }
            }
            ToolbarItem(placement: .principal) {
                Picker("Workspace section", selection: Binding(get: { session.workspaceSection }, set: { session.setWorkspaceSection($0) })) {
                    Text("Notes").tag(WorkspaceSession.WorkspaceSection.notes)
                    Text("Roadmap").tag(WorkspaceSession.WorkspaceSection.roadmap)
                    Text("Connections").tag(WorkspaceSession.WorkspaceSection.connections)
                }.pickerStyle(.segmented).frame(width: 275).disabled(session.project == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await session.chooseProject() } } label: { Label("Open Project", systemImage: "folder.badge.plus") }
                    .disabled(session.isOpening || session.showingNewNote)
                Button { session.runCommand(.searchNotes) } label: { Label("Search Notes", systemImage: "magnifyingglass") }
                    .disabled(session.project == nil)
                Button { session.runCommand(.commandPalette) } label: { Label("Commands", systemImage: "command") }
                Button { session.runCommand(.capture) } label: { Label("Capture", systemImage: "sparkles") }
                    .disabled(session.selectedDocument == nil || session.isOpening)
                Button { showingNotePicker.toggle() } label: { Label("Open Note", systemImage: "doc.text.magnifyingglass") }
                    .disabled(session.notes.isEmpty)
                    .popover(isPresented: $showingNotePicker) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Project notes").font(.headline)
                            TextField("Filter filenames", text: $filter).textFieldStyle(.roundedBorder)
                            List(filteredNotes) { note in
                                Button(note.relativePath) {
                                    showingNotePicker = false
                                    Task { await session.selectNote(note.id) }
                                }.buttonStyle(.plain)
                            }
                        }.padding(16).frame(width: 430, height: 420)
                    }
                Button { Task { await session.refreshProject() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(session.project == nil || session.isRefreshing)
                Button { Task { await session.recoverProject() } } label: { Label("Recovery", systemImage: "clock.arrow.circlepath") }
                    .disabled(session.project == nil)
                Button { session.creationSeed = nil; session.showingNewNote = true } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .disabled(!session.canCreateNote)
            }
        }
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("PROJECT").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.top, 18)
            Text(session.project?.name ?? "Open a project").font(.headline)
            ForEach(WorkspaceSession.WorkspaceSection.allCases, id: \.self) { section in
                Button { session.setWorkspaceSection(section) } label: {
                    HStack {
                        Image(systemName: section == .notes ? "doc.text" : section == .roadmap ? "calendar" : "point.3.connected.trianglepath.dotted")
                        Text(section.rawValue.capitalized); Spacer()
                    }.font(.callout).padding(8)
                        .background(session.workspaceSection == section ? FolioStyle.gold.opacity(0.08) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).disabled(session.project == nil)
            }
            Divider()
            TextField("Filter filenames", text: $filter).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter project note filenames")
            if session.notes.isEmpty {
                Text(session.project == nil ? "Your project keeps its own notes and file locations." : "No Markdown notes yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredNotes) { note in
                        Button { Task { await session.selectNote(note.id) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.title).lineLimit(1)
                                    Text(note.folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if session.documents[note.id]?.isDirty == true {
                                    Circle().fill(FolioStyle.gold).frame(width: 5, height: 5)
                                        .accessibilityLabel("Changes waiting to save")
                                }
                            }
                            .font(.callout).padding(9)
                            .background(note.id == session.selectedNoteID ? Color.white.opacity(0.08) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("\(session.notes.count) notes · \(session.search.message)")
                .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 12)
        }
        .padding(.horizontal, 14).background(FolioStyle.sidebar)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let document = session.selectedDocument {
                HStack {
                    Label(document.baseline.note.title, systemImage: "doc.text")
                    Spacer()
                    Picker("Editor presentation", selection: Binding(get: { document.editorPresentation }, set: { document.editorPresentation = $0 })) {
                        ForEach(EditorPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 240)
                }.padding(16)
                Divider()
                if let conflict = document.conflict {
                    ConflictReviewView(session: session, document: document, conflict: conflict)
                }
                if let message = document.failure {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle").font(.caption).lineLimit(3)
                        Spacer()
                        Button("Recovery…") { Task { await session.recoverProject() } }
                        Button("Save Copy…") { session.saveLocalAsNewNote() }
                    }.padding(10).background(Color.red.opacity(0.1))
                }
                if let notice = session.pasteMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                        Text(notice).font(.caption)
                        Spacer()
                        Button("Undo") { session.undoConvertedPaste() }
                        Button { session.clearPasteNotice() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss paste notice")
                    }.padding(11).background(FolioStyle.gold.opacity(0.1))
                }
                EditorPanes(session: session, document: document)
            } else {
                ContentUnavailableView {
                    Label(session.project == nil ? "A project begins with a folder" : "A place for your next thought", systemImage: "folder")
                } description: {
                    Text(session.project == nil ? "Open a local folder to work with its Markdown. Use a disposable copy while native validation is pending." : "Choose a title and location to create a Markdown note.")
                } actions: {
                    if session.project == nil {
                        Button("Open Project Folder…") { Task { await session.chooseProject() } }
                            .buttonStyle(.borderedProminent).disabled(session.isOpening)
                    } else {
                        Button("New Note…") { session.creationSeed = nil; session.showingNewNote = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }.background(FolioStyle.editor)
    }

    private var assistant: some View {
        CapturePanel(session: session, capture: session.capture)
    }
}
