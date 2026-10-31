import CoreGraphics
import Foundation

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

struct TrafficGraphCurve: Equatable, Sendable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func point(at progress: CGFloat) -> CGPoint {
        let t = min(1, max(0, progress))
        let inverse = 1 - t
        let x = inverse * inverse * inverse * start.x
            + 3 * inverse * inverse * t * control1.x
            + 3 * inverse * t * t * control2.x
            + t * t * t * end.x
        let y = inverse * inverse * inverse * start.y
            + 3 * inverse * inverse * t * control1.y
            + 3 * inverse * t * t * control2.y
            + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    /// A parallel lane, perpendicular to the relationship's chord. Sent and received share a relationship without
    /// painting two colours on top of each other, and the geometry remains stable because counters never enter it.
    func offset(by distance: CGFloat) -> TrafficGraphCurve {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let shift = CGPoint(x: -dy / length * distance, y: dx / length * distance)
        return TrafficGraphCurve(
            start: CGPoint(x: start.x + shift.x, y: start.y + shift.y),
            control1: CGPoint(x: control1.x + shift.x, y: control1.y + shift.y),
            control2: CGPoint(x: control2.x + shift.x, y: control2.y + shift.y),
            end: CGPoint(x: end.x + shift.x, y: end.y + shift.y)
        )
    }
}

struct TrafficGraphParticle: Equatable, Sendable {
    enum Direction: Sendable {
        case received
        case sent
        case invocation
    }

    var position: CGPoint
    var direction: Direction
    var radius: CGFloat
}

struct TrafficGraphLayoutSnapshot: Sendable {
    var nodeFrames: [TrafficGraphNodeID: CGRect]
    var edgeCurves: [TrafficGraphEdgeID: TrafficGraphCurve]

    func edge(at point: CGPoint, tolerance: CGFloat = 12) -> TrafficGraphEdgeID? {
        edgeCurves
            .map { id, curve in
                let distance = stride(from: 0, through: 1, by: 0.025)
                    .map { curve.point(at: CGFloat($0)).distance(to: point) }
                    .min() ?? .greatestFiniteMagnitude
                return (id, distance)
            }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    func particles(for edge: TrafficGraphEdge, at time: TimeInterval, reduceMotion: Bool) -> [TrafficGraphParticle] {
        guard !reduceMotion, edge.relationship == .observed,
              let curve = edgeCurves[edge.id] else { return [] }
        var result: [TrafficGraphParticle] = []
        appendParticles(direction: .sent, bytes: edge.counters.bytesOut, curve: curve.offset(by: 2.5), reverse: false,
                        edgeID: edge.id, time: time, into: &result)
        appendParticles(direction: .received, bytes: edge.counters.bytesIn, curve: curve.offset(by: -2.5), reverse: true,
                        edgeID: edge.id, time: time, into: &result)
        return result
    }

    private func appendParticles(direction: TrafficGraphParticle.Direction, bytes: Int64, curve: TrafficGraphCurve,
                                 reverse: Bool, edgeID: TrafficGraphEdgeID, time: TimeInterval,
                                 into result: inout [TrafficGraphParticle]) {
        guard bytes > 0 else { return }
        let count = max(1, min(4, Int(log10(Double(bytes) / 1_000_000 + 1).rounded())))
        let duration = max(2.2, 5.3 - log10(Double(bytes) / 1_000_000 + 1) * 0.65)
        let seed = Double(Self.stableHash(edgeID.rawValue) % 997) / 997
        for index in 0..<count {
            var progress = (time / duration + Double(index) / Double(count) + seed).truncatingRemainder(dividingBy: 1)
            if progress < 0 { progress += 1 }
            if reverse { progress = 1 - progress }
            result.append(TrafficGraphParticle(position: curve.point(at: CGFloat(progress)), direction: direction, radius: 2.8))
        }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

enum TrafficGraphLayout {
    private struct Placement {
        var id: TrafficGraphNodeID
        var size: CGSize
        var anchor: CGPoint
        var rank: Int
    }

    static let appSize = CGSize(width: 142, height: 104)
    static let destinationSize = CGSize(width: 152, height: 82)

    static func layout(snapshot: TrafficGraphSnapshot, in bounds: CGRect) -> TrafficGraphLayoutSnapshot {
        guard !snapshot.nodes.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
        }

        let insetBounds = bounds.insetBy(dx: 18, dy: 18)
        let apps = snapshot.nodes.filter { $0.kind == .app || $0.kind == .agent }.sorted { $0.id < $1.id }
        let tools = snapshot.nodes.filter { $0.kind == .tool || $0.kind == .mcp }.sorted { $0.id < $1.id }
        let destinations = snapshot.nodes.filter { $0.kind == .destination || $0.kind == .service }.sorted { $0.id < $1.id }
        let appColumn = insetBounds.minX + appSize.width / 2
        let toolColumn = insetBounds.midX
        let destinationColumn = insetBounds.maxX - destinationSize.width / 2

        var placements: [Placement] = []
        placements += seeded(apps, column: appColumn, size: appSize, in: insetBounds)
        placements += seeded(tools, column: toolColumn, size: destinationSize, in: insetBounds)
        placements += seeded(destinations, column: destinationColumn, size: destinationSize, in: insetBounds)
        var frames: [TrafficGraphNodeID: CGRect] = [:]
        var placedFrames: [CGRect] = []

        for placement in placements.sorted(by: { $0.rank < $1.rank || ($0.rank == $1.rank && $0.id < $1.id) }) {
            let frame = resolve(placement: placement, within: insetBounds, avoiding: placedFrames)
            frames[placement.id] = frame
            placedFrames.append(frame)
        }

        var curves: [TrafficGraphEdgeID: TrafficGraphCurve] = [:]
        for edge in snapshot.edges {
            guard let source = frames[edge.source], let target = frames[edge.target] else { continue }
            curves[edge.id] = curve(from: source, to: target, seed: stableHash(edge.id.rawValue))
        }
        return TrafficGraphLayoutSnapshot(nodeFrames: frames, edgeCurves: curves)
    }

    static func edgeWidth(bytes: Int64, maximum: Int64) -> CGFloat {
        guard bytes > 0, maximum > 0 else { return 1.5 }
        let normalized = log10(Double(bytes) + 1) / log10(Double(maximum) + 1)
        return 1.5 + CGFloat(normalized) * 7.5
    }

    private static func seeded(_ nodes: [TrafficGraphNode], column: CGFloat, size: CGSize, in bounds: CGRect) -> [Placement] {
        nodes.enumerated().map { index, node in
            let fraction = CGFloat(index + 1) / CGFloat(nodes.count + 1)
            let rank = Int((Double(node.id.rawValue.utf8.count) + Double(index)) * 10)
            return Placement(id: node.id, size: size,
                             anchor: CGPoint(x: column, y: bounds.minY + bounds.height * fraction), rank: rank)
        }
    }

    private static func resolve(placement: Placement, within bounds: CGRect, avoiding placed: [CGRect]) -> CGRect {
        func frame(center: CGPoint) -> CGRect {
            CGRect(x: center.x - placement.size.width / 2, y: center.y - placement.size.height / 2,
                   width: placement.size.width, height: placement.size.height)
        }
        func clamped(_ candidate: CGRect) -> CGRect {
            var result = candidate
            if result.minX < bounds.minX { result.origin.x = bounds.minX }
            if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
            if result.minY < bounds.minY { result.origin.y = bounds.minY }
            if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
            return result
        }
        func collides(_ candidate: CGRect) -> Bool {
            placed.contains { $0.insetBy(dx: -8, dy: -8).intersects(candidate) }
        }

        let initial = clamped(frame(center: placement.anchor))
        guard collides(initial) else { return initial }

        for ring in 1...14 {
            for slot in 0..<16 {
                let angle = CGFloat(slot) * .pi / 8
                let center = CGPoint(
                    x: placement.anchor.x + cos(angle) * CGFloat(ring) * 58,
                    y: placement.anchor.y + sin(angle) * CGFloat(ring) * 52
                )
                let candidate = clamped(frame(center: center))
                if !collides(candidate) { return candidate }
            }
        }
        return initial
    }

    private static func curve(from source: CGRect, to target: CGRect, seed: UInt64) -> TrafficGraphCurve {
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let deltaX = targetCenter.x - sourceCenter.x
        let deltaY = targetCenter.y - sourceCenter.y
        let horizontal = abs(deltaX) >= abs(deltaY)
        let start = horizontal
            ? CGPoint(x: deltaX >= 0 ? source.maxX : source.minX, y: source.midY)
            : CGPoint(x: source.midX, y: deltaY >= 0 ? source.maxY : source.minY)
        let end = horizontal
            ? CGPoint(x: deltaX >= 0 ? target.minX : target.maxX, y: target.midY)
            : CGPoint(x: target.midX, y: deltaY >= 0 ? target.minY : target.maxY)
        let bend = CGFloat(Int(seed % 5) - 2) * 9
        if horizontal {
            let span = (end.x - start.x) * 0.42
            return TrafficGraphCurve(start: start,
                                     control1: CGPoint(x: start.x + span, y: start.y + bend),
                                     control2: CGPoint(x: end.x - span, y: end.y + bend), end: end)
        }
        let span = (end.y - start.y) * 0.42
        return TrafficGraphCurve(start: start,
                                 control1: CGPoint(x: start.x + bend, y: start.y + span),
                                 control2: CGPoint(x: end.x + bend, y: end.y - span), end: end)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
