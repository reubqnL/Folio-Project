import SwiftUI
import AppKit
import MetalKit
import FolioCore

@MainActor
struct MetalGraphView: NSViewRepresentable {
    @Bindable var graph: GraphController
    var openSelection: () -> Void

    func makeCoordinator() -> MetalGraphRenderer { MetalGraphRenderer() }
    func makeNSView(context: Context) -> GraphMetalSurface {
        let view = GraphMetalSurface(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.082, 0.09, 0.11, 1)
        view.delegate = context.coordinator
        context.coordinator.configure(view)
        view.onInspect = { id in graph.inspect(id) }
        view.onOpen = openSelection
        view.onCamera = { camera in graph.camera = camera }
        view.onExpand = { graph.expandSelectedCluster() }
        view.setAccessibilityLabel("Connections graph. Use the list toggle for equivalent non-spatial navigation.")
        return view
    }
    func updateNSView(_ view: GraphMetalSurface, context: Context) {
        view.projection = graph.projection
        view.positions = graph.positions
        view.camera = graph.camera
        view.selected = graph.selected
        view.onOpen = openSelection
        context.coordinator.projection = graph.projection
        context.coordinator.positions = graph.positions
        context.coordinator.camera = graph.camera
        context.coordinator.selected = graph.selected
        view.needsDisplay = true
        if let problem = context.coordinator.failure, graph.failure != problem {
            Task { @MainActor in graph.failure = problem }
        }
    }
}

@MainActor
final class GraphMetalSurface: MTKView {
    var projection: GraphProjection?
    var positions: [GraphEntityID: GraphPoint3] = [:]
    var camera = GraphCamera()
    var selected: GraphEntityID?
    var onInspect: ((GraphEntityID) -> Void)?
    var onOpen: (() -> Void)?
    var onCamera: ((GraphCamera) -> Void)?
    var onExpand: (() -> Void)?
    private var initial: NSPoint?
    private var previous: NSPoint?
    private var didDrag = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        initial = point; previous = point; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let prior = previous else { return }
        if let initial, hypot(point.x - initial.x, point.y - initial.y) > 3 { didDrag = true }
        var next = camera
        if camera.threeDimensional && !event.modifierFlags.contains(.shift) {
            next.yaw += Double(point.x - prior.x) * 0.009
            next.pitch -= Double(point.y - prior.y) * 0.009
        } else {
            let scale = max(1, min(bounds.width, bounds.height)) * 0.42 * camera.zoom
            next.panX += Double(point.x - prior.x) / scale
            next.panY += Double(point.y - prior.y) / scale
        }
        next.sanitise(); previous = point; onCamera?(next)
    }
    override func mouseUp(with event: NSEvent) {
        defer { previous = nil; initial = nil }
        guard !didDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = camera.hitTest(x: point.x, y: point.y, positions: positions, width: bounds.width, height: bounds.height) {
            onInspect?(hit)
            if event.clickCount > 1 {
                if projection?.nodes.first(where: { $0.id == hit })?.kind == .cluster { onExpand?() }
                else { onOpen?() }
            }
        }
    }
    override func magnify(with event: NSEvent) {
        var next = camera; next.zoom *= 1 + Double(event.magnification); next.sanitise(); onCamera?(next)
    }
    override func scrollWheel(with event: NSEvent) {
        var next = camera
        if event.modifierFlags.contains(.option) || !event.hasPreciseScrollingDeltas {
            next.zoom *= exp(-Double(event.scrollingDeltaY) * 0.025)
        } else {
            let scale = max(1, min(bounds.width, bounds.height)) * 0.42 * camera.zoom
            next.panX += Double(event.scrollingDeltaX) / scale
            next.panY += Double(event.scrollingDeltaY) / scale
        }
        next.sanitise(); onCamera?(next)
    }
    override func keyDown(with event: NSEvent) {
        let nodes = projection?.nodes.sorted { $0.id < $1.id } ?? []
        switch event.keyCode {
        case 36, 76:
            if projection?.nodes.first(where: { $0.id == selected })?.kind == .cluster { onExpand?() } else { onOpen?() }
        case 123, 124, 125, 126:
            guard !nodes.isEmpty else { return }
            let current = nodes.firstIndex { $0.id == selected } ?? 0
            let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
            onInspect?(nodes[(current + delta + nodes.count) % nodes.count].id)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class MetalGraphRenderer: NSObject, MTKViewDelegate {
    private struct Vertex { var position: SIMD2<Float>; var color: SIMD4<Float> }
    var projection: GraphProjection?
    var positions: [GraphEntityID: GraphPoint3] = [:]
    var camera = GraphCamera()
    var selected: GraphEntityID?
    var failure: String?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private final class FrameResources {
        var buffer: MTLBuffer?
        var capacity = 0
        var inUse = false
    }
    private var frames = [FrameResources(), FrameResources(), FrameResources()]
    private var pendingRedraw = false
    private let noteColor = SIMD4<Float>(0.52, 0.68, 0.96, 1)
    private let taskColor = SIMD4<Float>(0.92, 0.76, 0.42, 1)

    func configure(_ view: MTKView) {
        guard let device = view.device else { failure = "Metal is unavailable. Use the connection list; graph data is unchanged."; return }
        queue = device.makeCommandQueue()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float2 position; float4 color; };
        struct Raster { float4 position [[position]]; float4 color; };
        vertex Raster folio_vertex(const device Vertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
            Raster out; out.position = float4(vertices[id].position, 0, 1); out.color = vertices[id].color; return out;
        }
        fragment float4 folio_fragment(Raster in [[stage_in]]) { return in.color; }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "folio_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "folio_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = view.colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { failure = "Metal graph setup failed. Use the list view. " + error.localizedDescription }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }
    func draw(in view: MTKView) {
        guard let device = view.device, let queue, let pipeline,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        guard let frameIndex = frames.firstIndex(where: { !$0.inUse }) else { pendingRedraw = true; return }
        let resources = frames[frameIndex]
        let width = max(1, Double(view.bounds.width)), height = max(1, Double(view.bounds.height))
        var vertices: [Vertex] = []
        let projected = positions.mapValues { camera.project($0, width: width, height: height) }
        func vertex(_ x: Double, _ y: Double, _ color: SIMD4<Float>) -> Vertex {
            .init(position: .init(Float(x / width * 2 - 1), Float(1 - y / height * 2)), color: color)
        }
        func line(_ a: GraphScreenPoint, _ b: GraphScreenPoint, thickness: Double, color: SIMD4<Float>) {
            let length = hypot(b.x-a.x, b.y-a.y); guard length > 0.01 else { return }
            let dx = -(b.y-a.y) / length * thickness, dy = (b.x-a.x) / length * thickness
            let p = vertex(a.x+dx,a.y+dy,color), q = vertex(a.x-dx,a.y-dy,color)
            let r = vertex(b.x+dx,b.y+dy,color), s = vertex(b.x-dx,b.y-dy,color)
            vertices += [p,q,r,q,s,r]
        }
        func disc(_ point: GraphScreenPoint, radius: Double, color: SIMD4<Float>, sides: Int) {
            for side in 0..<sides {
                let a = Double(side) / Double(sides) * Double.pi * 2
                let b = Double(side+1) / Double(sides) * Double.pi * 2
                vertices += [vertex(point.x,point.y,color), vertex(point.x+cos(a)*radius,point.y+sin(a)*radius,color), vertex(point.x+cos(b)*radius,point.y+sin(b)*radius,color)]
            }
        }
        for edge in projection?.edges ?? [] {
            guard let a = projected[edge.from], let b = projected[edge.to] else { continue }
            let highlighted = edge.from == selected || edge.to == selected
            let color = highlighted ? SIMD4<Float>(0.92,0.76,0.42,0.65) : SIMD4<Float>(0.37,0.44,0.58,0.3)
            line(a,b,thickness: highlighted ? 1 : 0.6,color: color)
            // Direction marker, not a label on every edge.
            let length = hypot(b.x-a.x,b.y-a.y)
            if length > 30 {
                let ux = (b.x-a.x)/length, uy = (b.y-a.y)/length
                let tipX = b.x-ux*12, tipY = b.y-uy*12
                vertices += [vertex(tipX,tipY,color), vertex(tipX-ux*6-uy*3,tipY-uy*6+ux*3,color), vertex(tipX-ux*6+uy*3,tipY-uy*6-ux*3,color)]
            }
        }
        let nodes = (projection?.nodes ?? []).sorted { (projected[$0.id]?.depth ?? 0) < (projected[$1.id]?.depth ?? 0) }
        for node in nodes {
            guard let point = projected[node.id] else { continue }
            let radius = node.kind == .cluster ? 12.0 : node.id == projection?.focus ? 9 : 6
            if node.id == selected { disc(point, radius: radius+4, color: SIMD4<Float>(0.92,0.76,0.42,0.3), sides: 28) }
            let color = node.isMissing ? SIMD4<Float>(0.65,0.45,0.45,1) : node.kind == .note ? noteColor : taskColor
            if node.kind == .task {
                let p = vertex(point.x-radius,point.y-radius,color), q = vertex(point.x+radius,point.y-radius,color)
                let r = vertex(point.x-radius,point.y+radius,color), s = vertex(point.x+radius,point.y+radius,color)
                vertices += [p,q,r,q,s,r]
            } else { disc(point, radius: radius, color: color, sides: node.kind == .cluster ? 6 : 24) }
        }
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        if byteCount > resources.capacity {
            resources.capacity = max(4096, byteCount * 2)
            resources.buffer = device.makeBuffer(length: resources.capacity, options: .storageModeShared)
        }
        if byteCount > 0, let vertexBuffer = resources.buffer {
            vertices.withUnsafeBufferPointer { buffer in memcpy(vertexBuffer.contents(), buffer.baseAddress!, byteCount) }
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let vertexBuffer = resources.buffer, !vertices.isEmpty {
            encoder.setRenderPipelineState(pipeline); encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        resources.inUse = true
        command.addCompletedHandler { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self else { return }
                self.frames[frameIndex].inUse = false
                if self.pendingRedraw { self.pendingRedraw = false; view?.needsDisplay = true }
            }
        }
        command.present(drawable); command.commit()
    }
}
