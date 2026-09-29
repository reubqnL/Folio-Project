import SwiftUI
import FolioCore

struct ConnectionsView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var graph: GraphController
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The title yields first and truncates on one line; the picker and
            // buttons keep their size so a narrow column cannot wrap a label
            // character by character or push a control out of the window.
            HStack(spacing: 12) {
                Text("Connections, not clutter.").font(.title2.weight(.semibold))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                Spacer(minLength: 8)
                Picker("Neighbourhood depth", selection: Binding(get: { graph.hops }, set: { graph.setHops($0) })) {
                    Text("1 hop").tag(1); Text("2 hops").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 145).fixedSize()
                Button { graph.showList.toggle() } label: { Label(graph.showList ? "Graph" : "List", systemImage: graph.showList ? "point.3.connected.trianglepath.dotted" : "list.bullet") }
                    .fixedSize()
                Button { graph.rebuild() } label: { Image(systemName: "arrow.clockwise") }.help("Rebuild saved-note connections")
                    .disabled(graph.isBuilding)
                    .fixedSize()
            }.padding(18)
            Divider()
            HStack(spacing: 14) {
                Label("Notes", systemImage: "circle.fill").foregroundStyle(.blue).fixedSize()
                Label("Roadmap items", systemImage: "square.fill").foregroundStyle(FolioStyle.gold).fixedSize()
                Text("Authored links, not AI guesses.").foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 8)
                if graph.isBuilding { ProgressView().controlSize(.small); Text("\(graph.processed)/\(graph.total)").fixedSize() }
                Text("\(graph.logical?.nodes.count ?? 0) entities").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }.font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
            if let failure = graph.failure {
                HStack(spacing: 10) {
                    Text(failure).font(.caption).lineLimit(3).layoutPriority(-1)
                    Spacer(minLength: 8)
                    Button("Use List") { graph.showList = true }.fixedSize()
                }.padding(10).background(Color.orange.opacity(0.08))
            }
            HStack(spacing: 0) {
                Group {
                    if graph.catalogue?.nodes.isEmpty != false {
                        ContentUnavailableView("Connect a note or roadmap item", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Wikilinks and explicit task-note/dependency links appear here. Nothing is inferred or written into your notes."))
                    } else if graph.showList { connectionList }
                    else { spatialView }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                Divider()
                inspector
                    .frame(minWidth: 240, idealWidth: 265, maxWidth: 300)
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
            Divider()
            HStack(spacing: 10) {
                if let projection = graph.projection, projection.omittedNodes > 0 {
                    Text("\(projection.omittedNodes) entities clustered · \(projection.omittedEdges) individual edges omitted")
                        .font(.caption).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                } else {
                    Text("Click to inspect · Open explicitly to navigate")
                        .font(.caption).lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if let catalogue = graph.catalogue, catalogue.unresolvedLinks > 0 || catalogue.omittedNoteBodies > 0 {
                    Text("\(catalogue.unresolvedLinks) unresolved links · \(catalogue.omittedNoteBodies) bodies omitted")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .help("Ambiguous/missing targets are not guessed. Oversized/unreadable note bodies and scan-budget overflow are explicitly omitted; roadmap links remain available.")
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if isActive { graph.buildIfNeeded() } }
        .onChange(of: isActive) { _, active in if active { graph.buildIfNeeded() } }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in if isActive { graph.adaptBudget() } }
    }

    private var spatialView: some View {
        VStack(spacing: 0) {
            // Icon buttons with tooltips rather than four text buttons: the row
            // has to survive a normal window without wrapping or clipping.
            HStack(spacing: 10) {
                Toggle("3D exploration", isOn: Binding(get: { graph.camera.threeDimensional }, set: { graph.camera.threeDimensional = $0 }))
                    .toggleStyle(.switch)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Optional 3D view. The 2D graph stays the default.")
                Button { graph.resetCamera() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset the graph view")
                    .accessibilityLabel("Reset view")
                    .fixedSize()
                Button { graph.resetClusters() } label: { Image(systemName: "square.grid.3x3") }
                    .help("Collapse expanded groups")
                    .accessibilityLabel("Collapse groups")
                    .disabled(graph.expanded.isEmpty)
                    .fixedSize()
                Spacer(minLength: 8)
                Button { graph.camera.zoom /= 1.15; graph.camera.sanitise() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                    .accessibilityLabel("Zoom out")
                    .fixedSize()
                Text("\(Int(graph.camera.zoom * 100))%").font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                Button { graph.camera.zoom *= 1.15; graph.camera.sanitise() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
                    .accessibilityLabel("Zoom in")
                    .fixedSize()
            }.controlSize(.small).padding(12)
            GeometryReader { geometry in
                ZStack {
                    if isActive {
                        MetalGraphView(graph: graph, openSelection: { session.openGraphSelection() })
                    } else { FolioStyle.canvas }
                    ForEach(labelNodes) { node in
                        if let position = graph.positions[node.id] {
                            let point = graph.camera.project(position, width: geometry.size.width, height: geometry.size.height)
                            Text(node.title).font(.system(size: 11, weight: node.id == graph.focus ? .semibold : .regular))
                                .foregroundStyle(node.id == graph.selected ? FolioStyle.gold : .secondary)
                                .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(FolioStyle.canvas.opacity(0.85))
                                .position(x: point.x, y: point.y + 22)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }.clipped()
            }
            Text(graph.camera.threeDimensional ? "Drag to orbit · Shift-drag/two-finger scroll to pan · pinch to zoom" : "Drag/two-finger scroll to pan · pinch or Option-scroll to zoom · 3D is optional")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Drag or two-finger scroll to pan. Pinch, or Option-scroll, to zoom.")
                .padding(10)
        }
    }
    private var labelNodes: [GraphNode] {
        let nodes = graph.projection?.nodes ?? []
        if nodes.count <= 32 { return nodes }
        return nodes.filter { $0.id == graph.selected || $0.id == graph.focus || $0.kind == .cluster }
    }
    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find an entity in this neighbourhood", text: $graph.listFilter).textFieldStyle(.roundedBorder)
            Text("The list includes the full logical neighbourhood, not just individually rendered nodes.").font(.caption).foregroundStyle(.secondary)
            List(graph.listNodes) { node in
                Button { graph.inspect(node.id) } label: {
                    HStack {
                        Image(systemName: node.kind == .note ? "doc.text" : "checklist")
                            .foregroundStyle(node.kind == .note ? Color.blue : FolioStyle.gold)
                        VStack(alignment: .leading, spacing: 4) { Text(node.title); Text(node.group).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if node.isMissing { Text("Missing").font(.caption).foregroundStyle(.orange) }
                        if node.id == graph.selected { Image(systemName: "checkmark") }
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain)
            }
        }.padding(16)
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SELECTED ENTITY").font(.caption2.weight(.semibold)).tracking(1.3).foregroundStyle(.secondary)
                if let node = graph.selectedNode {
                    Text(node.title).font(.title3.weight(.semibold))
                    Text(node.group).font(.caption).foregroundStyle(.secondary)
                    if node.kind == .cluster {
                        Text("\(node.members.count) underlying entities. Expanding is a view action; no notes are merged or removed.").font(.callout).foregroundStyle(.secondary)
                        Button("Expand Group") { graph.expandSelectedCluster() }.buttonStyle(.borderedProminent)
                        Button("Show Full List") { graph.showList = true }
                    } else {
                        Button(node.kind == .note ? "Open Note" : "Open Roadmap Item") { session.openGraphSelection() }
                            .buttonStyle(.borderedProminent).disabled(node.isMissing)
                        Button("Focus Here") { graph.focusHere(node.id) }
                        Divider()
                        Text("DIRECT CONNECTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(graph.selectedConnections) { edge in
                            let other = edge.from == node.id ? edge.to : edge.from
                            let related = graph.catalogue?.nodes[other]
                            Button { graph.inspect(other) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(related?.title ?? "Unresolved entity").font(.callout)
                                    Text(relationLabel(edge, selected: node.id)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                } else { Text("Select an entity to inspect its relationships. The editor will not change until you choose Open.").font(.callout).foregroundStyle(.secondary) }
                if let notice = graph.notice { Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }.padding(20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }.background(FolioStyle.sidebar)
    }
    private func relationLabel(_ edge: GraphEdge, selected: GraphEntityID) -> String {
        switch edge.kind {
        case .noteLink: return edge.from == selected ? "Links to this note" : "Backlink from this note"
        case .taskNote: return "Explicit task–note link"
        case .dependency: return edge.from == selected ? "Required before this successor" : "Depends on this prerequisite"
        }
    }
}
