import SwiftUI
import FolioCore

struct PreviewFollowRequest {
    let id = UUID()
    let sourceOffset: Int?
    let heading: String?
}

private struct PreviewRenderKey: Hashable {
    let document: UUID
    let generation: Int
    let visible: Bool
    let excerpt: Bool
}

/// A reparse session is only valid for one document in one preview mode;
/// switching between full preview and excerpt rebuilds it from scratch.
private struct PreviewParseMode: Hashable {
    let document: UUID
    let excerpt: Bool
}

struct MarkdownPreviewView: View {
    @Bindable var document: OpenNoteDocument
    @Bindable var session: WorkspaceSession
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("editorPointSize") private var pointSize = EditorPreferences.defaultPointSize
    @State private var parsed: MarkdownDocument?
    @State private var parsedDocumentID: UUID?
    @State private var parsing = false
    @State private var excerptApproved = false
    @State private var previewNotice: String?
    @State private var reparseSession: MarkdownReparseSession?
    @State private var reparseMode: PreviewParseMode?

    private var currentPreview: MarkdownDocument? { parsedDocumentID == document.id ? parsed : nil }
    private var renderKey: PreviewRenderKey {
        .init(document: document.id, generation: document.editGeneration, visible: isVisible, excerpt: excerptApproved)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(excerptApproved ? "Reading preview · excerpt" : "Reading preview").font(.caption.weight(.semibold))
                if parsing { ProgressView().controlSize(.mini) }
                Spacer()
                Button { session.followSourceCursor() } label: { Label("Follow cursor", systemImage: "scope") }
                    .controlSize(.small)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let parsed = currentPreview, parsed.isLimited {
                ContentUnavailableView {
                    Label("Choose how to preview this note", systemImage: "doc.text.magnifyingglass")
                } description: { Text(parsed.limitation ?? "Preview budget exceeded.") } actions: {
                    Button("Preview an Excerpt") { excerptApproved = true }
                    Button("Keep Source View") { document.editorPresentation = .source }
                }
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 15) {
                            if let parsed = currentPreview {
                                ForEach(parsed.blocks) { block in
                                    MarkdownBlockView(block: block, pointSize: EditorPreferences.clampedPointSize(pointSize))
                                        .id(block.id).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !parsed.warnings.isEmpty {
                                    Text(parsed.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if excerptApproved {
                                Text("Only an explicitly requested excerpt is shown. The source file is unchanged.")
                                    .font(.caption).foregroundStyle(FolioStyle.gold)
                            }
                        }.padding(24)
                    }
                    .textSelection(.enabled)
                    .onChange(of: document.previewRequest?.id) { _, _ in follow(using: reader) }
                    .onChange(of: parsed) { _, _ in follow(using: reader) }
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "folio-note", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let target = components.queryItems?.first(where: { $0.name == "target" })?.value {
                            session.activatePreviewLink(.note(target))
                        } else if url.scheme == "folio-anchor", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                                  let target = components.queryItems?.first(where: { $0.name == "target" })?.value {
                            session.activatePreviewLink(.anchor(target))
                        } else { session.activatePreviewLink(MarkdownLinkPolicy.classify(url.absoluteString)) }
                        return .handled
                    })
                }
            }
            if let previewNotice { Text(previewNotice).font(.caption).foregroundStyle(FolioStyle.gold).padding(10) }
        }
        .background(FolioStyle.editor)
        .accessibilityLabel("Markdown reading preview")
        .task(id: renderKey) {
            guard isVisible else { return }
            parsing = true
            let key = renderKey
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            // Read the prior session on the main actor before detaching; the
            // detached task reuses it on a local copy and hands it back.
            let source = document.text
            let mode = PreviewParseMode(document: key.document, excerpt: key.excerpt)
            let prior = reparseMode == mode ? reparseSession : nil
            let work = Task.detached(priority: .userInitiated) {
                let input = key.excerpt ? MarkdownParser.excerpt(source) : source
                if var session = prior {
                    let result = session.reparse(input)
                    return (result.document, session)
                }
                let session = MarkdownReparseSession(source: input)
                return (session.document, session)
            }
            let (result, session) = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, key == renderKey else { return }
            parsed = result; parsedDocumentID = document.id; parsing = false
            reparseSession = session; reparseMode = mode
        }
        .onChange(of: document.id) { _, _ in
            excerptApproved = false; parsed = nil; parsedDocumentID = nil; previewNotice = nil
            reparseSession = nil; reparseMode = nil
        }
    }

    private func follow(using reader: ScrollViewProxy) {
        guard isVisible, !parsing, let request = document.previewRequest,
              request.id != document.consumedPreviewRequest, let parsed = currentPreview, !parsed.isLimited else { return }
        document.consumedPreviewRequest = request.id
        let target: MarkdownBlock?
        if let offset = request.sourceOffset {
            if excerptApproved && offset > parsed.sourceUTF16Length {
                previewNotice = "The source cursor is outside this excerpt. No source selection was moved."
                return
            }
            target = parsed.block(atUTF16Offset: offset)
        } else if let heading = request.heading {
            target = parsed.blocks.first {
                guard case .heading(_, let tokens) = $0.kind else { return false }
                return MarkdownText.slug(MarkdownText.plain(tokens)) == MarkdownText.slug(heading.removingPercentEncoding ?? heading)
            }
        } else { target = nil }
        guard let target else { previewNotice = "No matching preview block was found."; return }
        previewNotice = nil
        if reduceMotion { reader.scrollTo(target.id, anchor: .top) }
        else { withAnimation(.easeOut(duration: 0.16)) { reader.scrollTo(target.id, anchor: .top) } }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let pointSize: Double
    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            rich(text).font(.system(size: pointSize * (level == 1 ? 1.8 : level == 2 ? 1.45 : 1.15), weight: .semibold))
                .accessibilityAddTraits(.isHeader).padding(.top, level < 3 ? 9 : 3)
        case .paragraph(let text): rich(text).font(.system(size: pointSize + 1)).lineSpacing(4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(FolioStyle.gold.opacity(0.6)).frame(width: 3)
                rich(text).foregroundColor(.secondary).font(.system(size: pointSize))
            }.fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty { Text(language).font(.caption2).foregroundStyle(.secondary) }
                ScrollView(.horizontal) { Text(text).font(.system(size: max(11, pointSize - 1), design: .monospaced)).fixedSize(horizontal: true, vertical: false) }
            }.padding(13).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6))
        case .listItem(let depth, let number, let checked, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let checked { Image(systemName: checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "Completed task" : "Incomplete task") }
                else { Text(number.map { "\($0)." } ?? "•").foregroundStyle(.secondary) }
                rich(text).font(.system(size: pointSize + 1))
            }.padding(.leading, CGFloat(depth * 18))
        case .rule: Divider().padding(.vertical, 6)
        case .metadata(let text):
            DisclosureGroup("Front matter · source preserved") { Text(text).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .font(.caption).foregroundStyle(.secondary)
        case .literalHTML(let text):
            VStack(alignment: .leading, spacing: 5) {
                Text("Literal HTML · not executed").font(.caption2).foregroundStyle(.secondary)
                Text(text).font(.system(size: 12, design: .monospaced))
            }.padding(10).background(Color.white.opacity(0.03))
        case .table(let headers, let rows, let alignment):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { ForEach(headers.indices, id: \.self) { index in rich(headers[index]).bold().frame(minWidth: 90, alignment: nativeAlignment(alignment[index])) } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow { ForEach(rows[row].indices, id: \.self) { column in rich(rows[row][column]).frame(minWidth: 90, alignment: nativeAlignment(alignment[column])) } }
                    }
                }.font(.system(size: pointSize)).padding(10)
            }.background(Color.white.opacity(0.025))
        }
    }
    private func nativeAlignment(_ value: TableAlignment) -> Alignment {
        switch value { case .left: .leading; case .centre: .center; case .right: .trailing }
    }
    private func rich(_ nodes: [MarkdownInline]) -> Text {
        nodes.reduce(Text("")) { result, node in
            let next: Text
            switch node {
            case .text(let text): next = Text(text)
            case .code(let text): next = Text(text).font(.system(size: pointSize, design: .monospaced)).foregroundColor(FolioStyle.gold)
            case .strong(let inner): next = rich(inner).bold()
            case .emphasis(let inner): next = rich(inner).italic()
            case .strike(let inner): next = rich(inner).strikethrough()
            case .image(let alt, _): next = Text("[Image not loaded: \(alt)]").italic().foregroundColor(.secondary)
            case .link(let label, let destination):
                var text = AttributedString(MarkdownText.plain(label))
                switch destination {
                case .blocked: text.foregroundColor = .secondary
                case .external(let value): text.link = URL(string: value); text.foregroundColor = FolioStyle.gold
                case .note(let value), .anchor(let value):
                    var url = URLComponents()
                    if case .anchor = destination { url.scheme = "folio-anchor" } else { url.scheme = "folio-note" }
                    url.host = "open"; url.queryItems = [.init(name: "target", value: value)]
                    text.link = url.url; text.foregroundColor = FolioStyle.gold
                }
                next = Text(text)
            }
            return result + next
        }
    }
}
