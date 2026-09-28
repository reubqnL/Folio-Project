import Foundation

public struct GraphPoint3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double = 0) { self.x = x; self.y = y; self.z = z }
}
public struct GraphScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let depth: Double
}
public enum GraphLayout {
    /// Deterministic bounded CPU layout. No continuous physics/render loop.
    public static func positions(for projection: GraphProjection) -> [GraphEntityID: GraphPoint3] {
        var output: [GraphEntityID: GraphPoint3] = [:]
        output[projection.focus] = .init(x: 0, y: 0)
        let neighbours = projection.nodes.filter { $0.id != projection.focus }.sorted { $0.id < $1.id }
        let rings = max(1, Int(ceil(Double(neighbours.count) / 28)))
        for (index, node) in neighbours.enumerated() {
            let ring = index / 28, position = index % 28
            let onRing = min(28, neighbours.count - ring * 28)
            let angle = Double(position) / Double(max(1, onRing)) * .pi * 2 + Double(ring) * 0.17
            let radius = 0.30 + 0.5 * Double(ring + 1) / Double(rings)
            let digest = ContentDigest.sha256(Data(node.id.rawValue.utf8))
            let seed = Int(digest.prefix(4), radix: 16) ?? 0
            output[node.id] = .init(x: cos(angle) * radius, y: sin(angle) * radius, z: (Double(seed) / 65535 - 0.5) * 0.65)
        }
        return output
    }
}
public struct GraphCamera: Equatable, Sendable {
    public var zoom: Double = 1
    public var panX: Double = 0
    public var panY: Double = 0
    public var yaw: Double = 0
    public var pitch: Double = 0
    public var threeDimensional: Bool = false
    public init() {}
    public mutating func sanitise() {
        zoom = zoom.isFinite ? min(5, max(0.25, zoom)) : 1
        panX = panX.isFinite ? min(3, max(-3, panX)) : 0
        panY = panY.isFinite ? min(3, max(-3, panY)) : 0
        yaw = yaw.isFinite ? yaw.truncatingRemainder(dividingBy: .pi * 2) : 0
        let pitchLimit: Double = Double.pi / 2.0 - 0.05
        pitch = pitch.isFinite ? min(pitchLimit, max(-pitchLimit, pitch)) : 0
    }
    public func project(_ point: GraphPoint3, width: Double, height: Double) -> GraphScreenPoint {
        var camera = self; camera.sanitise()
        let w = width.isFinite ? min(16384, max(1, width)) : 1, h = height.isFinite ? min(16384, max(1, height)) : 1
        var x = point.x.isFinite ? min(10, max(-10, point.x)) : 0
        var y = point.y.isFinite ? min(10, max(-10, point.y)) : 0
        var z = 0.0
        if camera.threeDimensional {
            let pz = point.z.isFinite ? min(10, max(-10, point.z)) : 0
            let rx = x * cos(camera.yaw) + pz * sin(camera.yaw)
            let rz = -x * sin(camera.yaw) + pz * cos(camera.yaw)
            let ry = y * cos(camera.pitch) - rz * sin(camera.pitch)
            z = y * sin(camera.pitch) + rz * cos(camera.pitch)
            let perspective = 3 / max(1, 3 - z)
            x = rx * perspective; y = ry * perspective
        }
        let scale = min(w, h) * 0.42 * camera.zoom
        return .init(x: w / 2 + (x + camera.panX) * scale,
                     y: h / 2 + (y + camera.panY) * scale, depth: z)
    }
    public func hitTest(x: Double, y: Double, positions: [GraphEntityID: GraphPoint3], width: Double, height: Double, radius: Double = 14) -> GraphEntityID? {
        guard x.isFinite, y.isFinite else { return nil }
        var nearest: GraphEntityID?
        var bestDistance = max(1.0, radius)
        for (id, point) in positions {
            let screen = project(point, width: width, height: height)
            let distance = hypot(screen.x - x, screen.y - y)
            if distance < bestDistance || (distance == bestDistance && (nearest == nil || id < nearest!)) {
                nearest = id; bestDistance = distance
            }
        }
        return nearest
    }
}
