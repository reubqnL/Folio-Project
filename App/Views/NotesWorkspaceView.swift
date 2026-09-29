import SwiftUI
import FolioCore

/// The workspace shell: status header, panes, footer and toolbar.
///
/// Layout rules that keep this stable at every supported window size:
/// - `WorkspaceLayout` decides pane widths. Panes narrow toward a minimum and
///   are hidden only by an explicit user action, so resizing or switching
///   sections can never move a control out from under the pointer.
/// - Every pane and the section stack clamp their own width with
///   `minWidth: 0` plus `.clipped()`, so a wide child (a table, a timeline or a
///   long label) cannot inflate its parent and push a sibling off the window.
/// - Single-line labels carry `.lineLimit(1)`; controls carry `.fixedSize()`.
///   That is what stops toolbar and navigation text wrapping character by
///   character when space runs out: text truncates, controls do not compress.
struct NotesWorkspaceView: View {
    @Bindable var session: WorkspaceSession
    @State private var filter = ""
    /// The note picker's own filter. It deliberately does not share `filter`:
    /// both fields are labelled "Filter filenames", and one `@State` string
    /// meant typing in the toolbar popover silently narrowed the sidebar list
    /// too, so closing the popover left the project list filtered by text the
    /// user could no longer see.
    @State private var pickerFilter = ""
    @State private var showingNotePicker = false

    private var filteredNotes: [VaultNote] {
        filter.isEmpty ? session.notes : session.notes.filter { $0.relativePath.localizedStandardContains(filter) }
    }
    private var pickerNotes: [VaultNote] {
        pickerFilter.isEmpty ? session.notes : session.notes.filter { $0.relativePath.localizedStandardContains(pickerFilter) }
    }

    /// The capture panel belongs to the Notes section only, so its column is
    /// only reserved there. Reserving space for a pane that is not drawn is how
    /// the writing surface used to lose width for no visible reason.
    private var assistantVisible: Bool {
        session.showsAssistant && session.workspaceSection == .notes
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if let notice = session.notice {
                noticeBanner(notice)
            }
            workspacePanes
            Divider()
            statusFooter
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { session.destination = .launcher } label: {
                    Label("Launcher", systemImage: "square.grid.2x2")
                }
                .help("Return to the Folio launcher")
            }
            ToolbarItem(placement: .principal) {
                Picker("Workspace section", selection: Binding(
                    get: { session.workspaceSection },
                    set: { session.setWorkspaceSection($0) }
                )) {
                    Text("Notes").tag(WorkspaceSession.WorkspaceSection.notes)
                    Text("Roadmap").tag(WorkspaceSession.WorkspaceSection.roadmap)
                    Text("Connections").tag(WorkspaceSession.WorkspaceSection.connections)
                }
                .pickerStyle(.segmented)
                // A segmented Picker draws its label beside the segments. In a
                // tight row that label is compressed to a few points and wraps
                // one character per line, which is what produced the vertical
                // text in the editor header. The segments already say what the
                // control is; `labelsHidden` keeps the title for VoiceOver while
                // taking it out of the layout.
                .labelsHidden()
                .frame(width: 300)
                .fixedSize()
                .disabled(session.project == nil)
                .help("Switch between Notes, Roadmap and Connections")
            }
            // Only three toolbar items on the right. The previous ten could not
            // fit a normal window, and AppKit hid the overflow behind a chevron;
            // the secondary commands now live in one always-visible menu (and in
            // the menu bar) instead of disappearing.
            ToolbarItemGroup(placement: .primaryAction) {
                notePickerButton
                newNoteButton
                moreMenu
            }
        }
    }

    // MARK: - Header, footer and notice

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Label("Plain vault", systemImage: "folder")
                .font(.callout.weight(.semibold))
                .foregroundStyle(FolioStyle.gold)
                .lineLimit(1)
                .fixedSize()
            Text(session.project?.name ?? "No project open")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if session.speech.isMicrophoneActive {
                Label("Microphone on", systemImage: "mic.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize()
                Button("Stop") { session.speech.haltForDisappearance() }
                    .controlSize(.small)
                    .fixedSize()
            }
            Text("Folio sync off · .rdm unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .help("Notes, recovery copies and the private app search cache are plaintext. The search cache is outside the vault. Other applications may read or sync the folder. Folio encryption and collaboration are not implemented.")
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 12) {
            Text(notice)
                .font(.caption)
                .lineLimit(3)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Button { session.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Dismiss project notice")
                .fixedSize()
        }
        .padding(10)
        .background(FolioStyle.gold.opacity(0.07))
    }

    private var statusFooter: some View {
        HStack(spacing: 12) {
            if session.isOpening {
                ProgressView().controlSize(.small)
                Text("Opening project…").lineLimit(1)
            } else {
                Text(session.workspaceSection == .roadmap ? session.planning.status : session.selectedDocument?.status ?? "Choose a local project folder")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.selectedDocument?.statusExplanation ?? "")
            }
            Spacer(minLength: 12)
            if session.selectedDocument != nil {
                Text(VaultRemoteState.unavailable.label)
                    .lineLimit(1)
                    .help(VaultRemoteState.unavailable.explanation)
            }
            Text("Development build · use copies")
                .foregroundStyle(FolioStyle.gold)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Panes

    private var workspacePanes: some View {
        GeometryReader { geometry in
            // While the user has chosen Split in the Notes section, the panes
            // narrow slightly rather than the request being refused: the writing
            // surface keeps enough width for two usable editor panes.
            let wantsSplit = session.workspaceSection == .notes
                && session.selectedDocument?.editorPresentation == .split
            let layout = WorkspaceLayout.resolve(
                availableWidth: geometry.size.width,
                showingExplorer: session.showsExplorer,
                showingAssistant: assistantVisible,
                editorMinimumWidth: wantsSplit
                    ? WorkspaceLayoutPolicy.minimumSplitWidth + WorkspaceLayoutPolicy.paneRoundingSlack
                    : WorkspaceLayoutPolicy.minimumEditorWidth
            )
            HStack(spacing: 0) {
                if let width = layout.explorerWidth {
                    explorer
                        .frame(width: width)
                        .clipped()
                    Divider()
                }
                sectionStack
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if let width = layout.assistantWidth, assistantVisible {
                    Divider()
                    assistant
                        .frame(width: width)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The editor stays mounted while Roadmap or Connections is shown so that
    /// switching sections never destroys the NSTextView, its selection or its
    /// undo stack. Each section clamps its own width so none of them can resize
    /// the shared column when it is layered in.
    private var sectionStack: some View {
        ZStack(alignment: .topLeading) {
            editor
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .id("editor-area")
                .opacity(session.workspaceSection == .notes ? 1 : 0)
                .allowsHitTesting(session.workspaceSection == .notes)
                .accessibilityHidden(session.workspaceSection != .notes)
            if session.workspaceSection == .roadmap {
                RoadmapView(session: session, planning: session.planning)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.workspaceSection == .connections {
                ConnectionsView(session: session, graph: session.connections, isActive: true)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("PROJECT").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.top, 18)
                .lineLimit(1)
            Text(session.project?.name ?? "Open a project").font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(WorkspaceSession.WorkspaceSection.allCases, id: \.self) { section in
                Button { session.setWorkspaceSection(section) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section == .notes ? "doc.text" : section == .roadmap ? "calendar" : "point.3.connected.trianglepath.dotted")
                        Text(section.rawValue.capitalized).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.callout).padding(8)
                    .contentShape(Rectangle())
                    .background(session.workspaceSection == section ? FolioStyle.gold.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(session.project == nil)
            }
            Divider()
            TextField("Filter filenames", text: $filter).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter project note filenames")
            if session.notes.isEmpty {
                Text(session.project == nil ? "Your project keeps its own notes and file locations." : "No Markdown notes yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if filteredNotes.isEmpty {
                // A filter that matches nothing used to leave an empty list with
                // no explanation, which looks identical to a project whose
                // notes all disappeared.
                HStack(spacing: 8) {
                    Text("No filename contains “\(filter)”.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Clear") { filter = "" }.controlSize(.small).fixedSize()
                }
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
                            .contentShape(Rectangle())
                            .background(note.id == session.selectedNoteID ? Color.white.opacity(0.08) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("\(session.notes.count) notes · \(session.search.message)")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 0, alignment: .leading)
        .background(FolioStyle.sidebar)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let document = session.selectedDocument {
                HStack(spacing: 12) {
                    Label(document.baseline.note.title, systemImage: "doc.text")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Picker("Editor presentation", selection: Binding(
                        get: { document.editorPresentation },
                        set: { document.editorPresentation = $0 }
                    )) {
                        ForEach(EditorPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    // Without this the Picker's own label ("Editor
                    // presentation") is drawn to the left of the segments. In a
                    // squeezed row it was compressed to a couple of points and
                    // wrapped one character per line, standing as a tall column
                    // of letters beside Source/Preview/Split.
                    .labelsHidden()
                    .frame(width: 240)
                    .fixedSize()
                    .help("Source, Preview or Split for this note")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                if let conflict = document.conflict {
                    ConflictReviewView(session: session, document: document, conflict: conflict)
                }
                if let message = document.failure {
                    HStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption).lineLimit(3).layoutPriority(-1)
                        Spacer(minLength: 8)
                        Button("Recovery…") { Task { await session.recoverProject() } }.fixedSize()
                        Button("Save Copy…") { session.saveLocalAsNewNote() }.fixedSize()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                }
                if let notice = session.pasteMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                        Text(notice).font(.caption).lineLimit(2).layoutPriority(-1)
                        Spacer(minLength: 8)
                        Button("Undo") { session.undoConvertedPaste() }.fixedSize()
                        Button { session.clearPasteNotice() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Dismiss paste notice")
                            .fixedSize()
                    }
                    .padding(11)
                    .background(FolioStyle.gold.opacity(0.1))
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
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(FolioStyle.editor)
    }

    private var assistant: some View {
        CapturePanel(session: session, capture: session.capture)
            .frame(minWidth: 0)
    }

    // MARK: - Toolbar items

    private var notePickerButton: some View {
        Button { showingNotePicker.toggle() } label: {
            Label("Open Note", systemImage: "doc.text.magnifyingglass")
        }
        .disabled(session.notes.isEmpty)
        .help("Search this project's notes by filename")
        .popover(isPresented: $showingNotePicker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Project notes").font(.headline)
                TextField("Filter filenames", text: $pickerFilter).textFieldStyle(.roundedBorder)
                if pickerNotes.isEmpty {
                    Text(session.notes.isEmpty ? "This project has no Markdown notes yet." : "No filenames match “\(pickerFilter)”.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(pickerNotes) { note in
                        Button(note.relativePath) {
                            showingNotePicker = false
                            Task { await session.selectNote(note.id) }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(16)
            .frame(width: 430, height: 420)
            .onDisappear { pickerFilter = "" }
        }
    }

    private var newNoteButton: some View {
        Button { session.creationSeed = nil; session.showingNewNote = true } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .disabled(!session.canCreateNote)
    }

    /// One menu that always fits, holding the commands that used to overflow the
    /// toolbar and vanish behind a chevron in a normal-sized window.
    private var moreMenu: some View {
        Menu {
            Toggle("Project Sidebar", isOn: $session.showsExplorer)
            Toggle("Capture Panel", isOn: $session.showsAssistant)
            Divider()
            Button("Open Project…") { Task { await session.chooseProject() } }
                .disabled(session.isOpening || session.showingNewNote)
            Button("Search Notes…") { session.runCommand(.searchNotes) }
                .disabled(session.project == nil)
            Button("Command Palette…") { session.runCommand(.commandPalette) }
            Button("Capture & Review…") { session.runCommand(.capture) }
                .disabled(session.selectedDocument == nil || session.isOpening)
            Divider()
            Button("Refresh Project") { Task { await session.refreshProject() } }
                .disabled(session.project == nil || session.isRefreshing)
            Button("Recovery…") { Task { await session.recoverProject() } }
                .disabled(session.project == nil)
            Button("Repair Links…") { session.runCommand(.repairLinks) }
                .disabled(session.project == nil)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("Project, search, capture and maintenance commands")
    }
}
