import SwiftUI

struct EncryptedProjectView: View {
    @Bindable var controller: EncryptedProjectController
    let onBack: () -> Void
    let onImportCurrent: (() -> Void)?
    let copyIsPreparing: Bool
    let copyCompleted: Int
    let copyTotal: Int
    let copyMessage: String
    let onCancelCopy: (() -> Void)?

    init(controller: EncryptedProjectController, onBack: @escaping () -> Void,
         onImportCurrent: (() -> Void)? = nil, copyIsPreparing: Bool = false,
         copyCompleted: Int = 0, copyTotal: Int = 0, copyMessage: String = "",
         onCancelCopy: (() -> Void)? = nil) {
        self.controller = controller
        self.onBack = onBack
        self.onImportCurrent = onImportCurrent
        self.copyIsPreparing = copyIsPreparing
        self.copyCompleted = copyCompleted
        self.copyTotal = copyTotal
        self.copyMessage = copyMessage
        self.onCancelCopy = onCancelCopy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(FolioStyle.canvas)
        .alert("Encrypted project", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Image(systemName: "lock.doc.fill").foregroundStyle(FolioStyle.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayName).font(.headline)
                Text("Encrypted .rdm project · development boundary")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isUnlocked {
                Button("Lock") { Task { await controller.lock() } }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(controller.isCheckpointing)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle: idleView
        case .creating: createView
        case .opening: openView
        case .recoveryReview: recoveryReview
        case .unlocked: unlockedView
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "lock.doc").font(.system(size: 48)).foregroundStyle(FolioStyle.gold)
            Text("Encrypted projects").font(.largeTitle.weight(.semibold))
            Text("Open or create an authenticated .rdm project. Its working search index stays in memory; it is not connected to the plain-vault search cache.")
                .foregroundStyle(.secondary).frame(maxWidth: 620, alignment: .leading)
            if copyIsPreparing {
                VStack(alignment: .leading, spacing: 9) {
                    ProgressView(value: copyTotal > 0 ? Double(copyCompleted) : nil,
                                 total: copyTotal > 0 ? Double(copyTotal) : 1)
                    HStack {
                        Text(copyTotal > 0 ? "Read \(copyCompleted) of \(copyTotal) notes" : copyMessage)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let onCancelCopy {
                            Button("Cancel", action: onCancelCopy)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button("Create encrypted project…") { controller.chooseToCreate() }
                        .buttonStyle(.borderedProminent)
                    Button("Open .rdm project…") { controller.chooseToOpen() }
                        .buttonStyle(.bordered)
                    if let onImportCurrent {
                        Button("Encrypt current project as a copy…", action: onImportCurrent)
                            .buttonStyle(.bordered)
                    }
                }
            }
            Text("Copying is explicit and non-destructive: the plain project is not deleted or rewritten. Mac Keychain, persistent encrypted index and runtime security validation remain separate gates. Do not use this build for sensitive data.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 620, alignment: .leading)
            Spacer()
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var createView: some View {
        credentialCard(title: "Create encrypted project", subtitle: "The passphrase unlocks this .rdm file. It is not saved by Folio.") {
            TextField("Project name", text: $controller.projectName)
                .textFieldStyle(.roundedBorder)
            SecureField("Passphrase", text: $controller.passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm passphrase", text: $controller.confirmation)
                .textFieldStyle(.roundedBorder)
            Toggle("Remember passphrase in this Mac’s locked Keychain", isOn: $controller.rememberPassphrase)
                .toggleStyle(.checkbox)
            Text("This is optional convenience storage bound to this exact file path. Recovery codes are never stored there.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { Task { await controller.close() } }
                Spacer()
                Button("Create") { Task { await controller.create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.passphrase.isEmpty || controller.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var openView: some View {
        credentialCard(title: "Unlock encrypted project", subtitle: controller.fileURL?.lastPathComponent ?? "Choose a credential") {
            if controller.credentialMode == .passphrase {
                SecureField("Passphrase", text: $controller.passphrase)
                    .textFieldStyle(.roundedBorder)
                Toggle("Remember passphrase in this Mac’s locked Keychain", isOn: $controller.rememberPassphrase)
                    .toggleStyle(.checkbox)
                HStack {
                    Button("Use saved passphrase") { Task { await controller.useSavedPassphrase() } }
                        .buttonStyle(.link)
                    Button("Forget saved passphrase") { controller.forgetSavedPassphrase() }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Use recovery code instead") { controller.useRecoveryCode() }
                    Button("Unlock") { Task { await controller.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.passphrase.isEmpty)
                }
            } else {
                TextField("Recovery code", text: $controller.recoveryCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button("Use passphrase instead") { controller.usePassphrase() }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Recover and unlock") { Task { await controller.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.recoveryCode.isEmpty)
                }
            }
            Button("Cancel") { Task { await controller.close() } }
                .buttonStyle(.borderless)
        }
    }

    private var recoveryReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Label("Store this recovery code securely", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(FolioStyle.gold)
            Text("Folio will not save this code, put it in the archive, or copy it automatically. If you lose both the passphrase and this code, the project cannot be opened.")
                .foregroundStyle(.secondary)
            Text(controller.pendingRecoveryCode ?? "Unavailable")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(FolioStyle.editor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Lock and discard") { Task { await controller.lock() } }
                Spacer()
                Button("I stored it securely") { controller.acknowledgeRecoveryCode() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(32).frame(maxWidth: 700, maxHeight: .infinity, alignment: .center)
    }

    private var unlockedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Unlocked in memory").font(.title2.weight(.semibold))
                Spacer()
                Button("New encrypted note") { controller.beginNewNote() }
                    .disabled(controller.isCheckpointing || controller.hasDraft)
                Text("Search runs from a memory-only index with an encrypted local cache")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if controller.needsWorkingReview {
                Button("Review local working copies") { Task { await controller.resolveWorkingStateNow() } }
                    .buttonStyle(.bordered)
            }
            HStack {
                TextField("Search encrypted notes in memory", text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await controller.search() } }
                Button("Search") { Task { await controller.search() } }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 0) {
                List(controller.searchHits, selection: $controller.selectedNoteID) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.title.isEmpty ? hit.path : hit.title).font(.headline)
                        Text(hit.path).font(.caption).foregroundStyle(.secondary)
                        Text(hit.excerpt).font(.caption).lineLimit(2)
                    }.tag(hit.id)
                }
                .frame(minWidth: 270)
                Divider()
                notePreview
            }
            Text("Draft text is stored only in the encrypted local working copy until you approve a checkpoint. Keychain storage and Mac runtime validation remain separate gates.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notePreview: some View {
        Group {
            if controller.hasDraft {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Note path", text: $controller.draftPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                            .onChange(of: controller.draftPath) { controller.draftTextDidChange() }
                        Spacer()
                        Button("Discard") { controller.cancelEditing() }
                        Button(controller.isCheckpointing ? "Writing…" : "Write encrypted checkpoint") {
                            Task { await controller.checkpointDraft() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isCheckpointing)
                    }
                    Text("This is an explicit draft. It is kept in the encrypted local working copy and joins the project only when you approve the checkpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $controller.draftMarkdown)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10).background(FolioStyle.editor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: controller.draftMarkdown) { controller.draftTextDidChange() }
                }
                .padding(18)
            } else if let note = controller.selectedNote {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(note.path).font(.headline)
                        Spacer()
                        Button("Edit reviewed draft") { controller.beginEditingSelectedNote() }
                    }
                    ScrollView {
                        Text(note.markdown).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(22)
            } else {
                ContentUnavailableView("No note selected", systemImage: "doc.text")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func credentialCard<Content: View>(title: String, subtitle: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
        }
        .padding(26).frame(width: 520).background(FolioStyle.editor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
