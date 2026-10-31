import CoreGraphics
import Foundation

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

struct TrafficGraphViewport: Equatable, Sendable {
    static let minimumScale: CGFloat = 0.55
    static let maximumScale: CGFloat = 2.4
    private static let minimumFitScale: CGFloat = 0.1

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let lowerBound = min(scale, Self.minimumScale)
        let nextScale = min(Self.maximumScale, max(lowerBound, scale * factor))
        guard nextScale != scale else { return }
        let graphAnchor = graphPoint(for: anchor)
        scale = nextScale
        offset = CGSize(width: anchor.x - graphAnchor.x * scale,
                        height: anchor.y - graphAnchor.y * scale)
    }

    mutating func pan(by translation: CGSize) {
        offset.width += translation.width
        offset.height += translation.height
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    mutating func fit(content: CGRect, in viewport: CGRect, padding: CGFloat = 32) {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else {
            reset()
            return
        }
        let available = viewport.insetBy(dx: padding, dy: padding)
        scale = min(Self.maximumScale, max(Self.minimumFitScale,
                    min(available.width / content.width, available.height / content.height)))
        offset = CGSize(width: viewport.midX - content.midX * scale,
                        height: viewport.midY - content.midY * scale)
    }

    func screenPoint(for graphPoint: CGPoint) -> CGPoint {
        CGPoint(x: graphPoint.x * scale + offset.width,
                y: graphPoint.y * scale + offset.height)
    }

    func graphPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: (screenPoint.x - offset.width) / scale,
                y: (screenPoint.y - offset.height) / scale)
    }
}

struct TrafficGraphCurve: Equatable, Sendable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint
    var routingPoints: [CGPoint] = []

    var points: [CGPoint] {
        routingPoints.count >= 2 ? routingPoints : (0...24).map { point(at: CGFloat($0) / 24) }
    }

    func point(at progress: CGFloat) -> CGPoint {
        if routingPoints.count >= 2 {
            let segments = zip(routingPoints, routingPoints.dropFirst()).map { ($0, $1, $0.distance(to: $1)) }
            let total = segments.reduce(CGFloat(0)) { $0 + $1.2 }
            guard total > 0 else { return start }
            var remaining = min(1, max(0, progress)) * total
            for (from, to, length) in segments {
                if remaining <= length {
                    let fraction = length > 0 ? remaining / length : 0
                    return CGPoint(x: from.x + (to.x - from.x) * fraction,
                                   y: from.y + (to.y - from.y) * fraction)
                }
                remaining -= length
            }
            return end
        }

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

    /// Offsets a ribbon boundary while keeping its node ports flush with vertical card edges.
    func offset(by distance: CGFloat) -> TrafficGraphCurve {
        let shift = CGPoint(x: 0, y: distance)
        let shifted = routingPoints.map { CGPoint(x: $0.x, y: $0.y + distance) }
        return TrafficGraphCurve(
            start: CGPoint(x: start.x + shift.x, y: start.y + shift.y),
            control1: CGPoint(x: control1.x + shift.x, y: control1.y + shift.y),
            control2: CGPoint(x: control2.x + shift.x, y: control2.y + shift.y),
            end: CGPoint(x: end.x + shift.x, y: end.y + shift.y),
            routingPoints: shifted
        )
    }

    func hitTestSteps(maximumSegmentLength: CGFloat) -> Int {
        guard routingPoints.count < 2 else {
            let length = zip(routingPoints, routingPoints.dropFirst()).reduce(CGFloat(0)) {
                $0 + $1.0.distance(to: $1.1)
            }
            return max(1, Int(ceil(length / maximumSegmentLength)))
        }
        let controlPolygon = start.distance(to: control1) + control1.distance(to: control2)
            + control2.distance(to: end)
        return max(12, Int(ceil(controlPolygon / maximumSegmentLength)))
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
    var edgeWidths: [TrafficGraphEdgeID: CGFloat] = [:]

    var contentBounds: CGRect {
        let nodes = nodeFrames.values.reduce(CGRect.null) { $0.union($1) }
        return edgeCurves.reduce(nodes) { bounds, entry in
            let width = edgeWidths[entry.key] ?? 1
            return entry.value.points.reduce(bounds) { partial, point in
                partial.union(CGRect(x: point.x - width / 2, y: point.y - width / 2,
                                     width: width, height: width))
            }
        }
    }

    func edge(at point: CGPoint, tolerance: CGFloat = 12) -> TrafficGraphEdgeID? {
        var closest: (id: TrafficGraphEdgeID, distance: CGFloat)?
        for (id, curve) in edgeCurves {
            let hitTolerance = tolerance + (edgeWidths[id] ?? 0) / 2
            let steps = curve.hitTestSteps(maximumSegmentLength: max(2, hitTolerance))
            var previous = curve.point(at: 0)
            var distance = point.distance(to: previous)
            for step in 1...steps {
                let sample = curve.point(at: CGFloat(step) / CGFloat(steps))
                distance = min(distance, Self.distance(from: point, toSegmentFrom: previous, to: sample))
                previous = sample
            }
            guard distance <= hitTolerance else { continue }
            if let closestDistance = closest?.distance, distance >= closestDistance { continue }
            closest = (id, distance)
        }
        return closest?.id
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return point.distance(to: start) }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, projection))
        return point.distance(to: CGPoint(x: start.x + dx * t, y: start.y + dy * t))
    }

    func particles(for edge: TrafficGraphEdge, at time: TimeInterval, reduceMotion: Bool) -> [TrafficGraphParticle] {
        guard !reduceMotion, edge.relationship == .observed,
              let curve = edgeCurves[edge.id] else { return [] }
        var result: [TrafficGraphParticle] = []
        appendParticles(direction: .sent, bytes: edge.counters.bytesOut, curve: curve.offset(by: 2), reverse: false,
                        edgeID: edge.id, time: time, into: &result)
        appendParticles(direction: .received, bytes: edge.counters.bytesIn, curve: curve.offset(by: -2), reverse: true,
                        edgeID: edge.id, time: time, into: &result)
        return result
    }

    private func appendParticles(direction: TrafficGraphParticle.Direction, bytes: Int64, curve: TrafficGraphCurve,
                                 reverse: Bool, edgeID: TrafficGraphEdgeID, time: TimeInterval,
                                 into result: inout [TrafficGraphParticle]) {
        guard bytes > 0 else { return }
        let count = max(1, min(2, Int(log10(Double(bytes) / 25_000_000 + 1).rounded(.up))))
        let duration = max(28, 36 - log10(Double(bytes) / 1_000_000 + 1) * 0.8)
        let seed = Double(Self.stableHash(edgeID.rawValue) % 997) / 997
        for index in 0..<count {
            var progress = (time / duration + Double(index) / Double(count) + seed).truncatingRemainder(dividingBy: 1)
            if progress < 0 { progress += 1 }
            if reverse { progress = 1 - progress }
            result.append(TrafficGraphParticle(position: curve.point(at: CGFloat(progress)),
                                                direction: direction, radius: 2.4))
        }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

enum TrafficGraphLayout {
    private enum Lane: Int, CaseIterable {
        case source
        case intermediary
        case destination
    }

    static let appSize = CGSize(width: 132, height: 52)
    static let destinationSize = CGSize(width: 150, height: 52)
    private static let intermediarySize = CGSize(width: 144, height: 52)
    private static let nodeGap: CGFloat = 10

    static func layout(snapshot: TrafficGraphSnapshot, in bounds: CGRect,
                       preserving previous: TrafficGraphLayoutSnapshot? = nil) -> TrafficGraphLayoutSnapshot {
        guard !snapshot.nodes.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
        }

        let insetBounds = bounds.insetBy(dx: 24, dy: 22)
        let ordered = orderedNodes(snapshot: snapshot)
        let columns: [Lane: CGFloat] = [
            .source: insetBounds.minX + appSize.width / 2,
            .intermediary: insetBounds.midX,
            .destination: insetBounds.maxX - destinationSize.width / 2
        ]
        var frames: [TrafficGraphNodeID: CGRect] = [:]

        if let previous {
            for node in snapshot.nodes {
                guard var frame = previous.nodeFrames[node.id] else { continue }
                let lane = lane(for: node)
                frame.origin.x = columns[lane]! - frame.width / 2
                guard insetBounds.contains(frame) else { continue }
                frames[node.id] = frame
            }
        }

        for lane in Lane.allCases {
            let nodes = ordered[lane] ?? []
            let size = size(for: lane)
            let availableHeight = insetBounds.height
            let stackHeight = CGFloat(nodes.count) * size.height + CGFloat(max(0, nodes.count - 1)) * nodeGap
            let startY = insetBounds.midY - min(stackHeight, availableHeight) / 2
            let step = nodes.count > 1 && stackHeight > availableHeight
                ? max(1, (availableHeight - size.height) / CGFloat(nodes.count - 1))
                : size.height + nodeGap

            for (index, node) in nodes.enumerated() where frames[node.id] == nil {
                let preferredY = startY + size.height / 2 + CGFloat(index) * step
                let preferred = CGPoint(x: columns[lane]!, y: preferredY)
                frames[node.id] = place(size: size, near: preferred, laneX: columns[lane]!,
                                            within: insetBounds, avoiding: Array(frames.values))
            }
        }

        let observed = snapshot.edges.filter { $0.relationship == .observed }
        let maximum = max(1, observed.map { $0.counters.total }.max() ?? 1)
        var widths = Dictionary(uniqueKeysWithValues: observed.map {
            ($0.id, ribbonWidth(bytes: $0.counters.total, maximum: maximum))
        })
        let scale = ribbonScale(edges: observed, widths: widths, frames: frames)
        widths = widths.mapValues { $0 * scale }

        let outgoing = Dictionary(grouping: observed, by: \.source)
        let incoming = Dictionary(grouping: observed, by: \.target)
        var sourcePorts: [TrafficGraphEdgeID: CGPoint] = [:]
        var targetPorts: [TrafficGraphEdgeID: CGPoint] = [:]
        for (nodeID, edges) in outgoing {
            guard let frame = frames[nodeID] else { continue }
            let sorted = edges.sorted {
                let leftY = frames[$0.target]?.midY ?? 0
                let rightY = frames[$1.target]?.midY ?? 0
                return leftY == rightY ? $0.id < $1.id : leftY < rightY
            }
            sourcePorts.merge(portCenters(for: sorted, in: frame, edgeWidths: widths)) { current, _ in current }
        }
        for (nodeID, edges) in incoming {
            guard let frame = frames[nodeID] else { continue }
            let sorted = edges.sorted {
                let leftY = frames[$0.source]?.midY ?? 0
                let rightY = frames[$1.source]?.midY ?? 0
                return leftY == rightY ? $0.id < $1.id : leftY < rightY
            }
            targetPorts.merge(portCenters(for: sorted, in: frame, edgeWidths: widths)) { current, _ in current }
        }

        let nodeLane = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, lane(for: $0)) })
        var curves: [TrafficGraphEdgeID: TrafficGraphCurve] = [:]
        for edge in snapshot.edges.sorted(by: { $0.id < $1.id }) {
            guard let source = frames[edge.source], let target = frames[edge.target] else { continue }
            if edge.relationship == .observed {
                guard let sourcePort = sourcePorts[edge.id], let targetPort = targetPorts[edge.id] else { continue }
                let start = CGPoint(x: source.maxX - 0.5, y: sourcePort.y)
                let end = CGPoint(x: target.minX, y: targetPort.y)
                let obstacles = nodeLane[edge.source] == .source && nodeLane[edge.target] == .destination
                    ? snapshot.nodes.compactMap { node -> CGRect? in
                        guard nodeLane[node.id] == .intermediary else { return nil }
                        return frames[node.id]
                    }
                    : []
                curves[edge.id] = sankeyCurve(start: start, end: end, avoiding: obstacles,
                                              width: widths[edge.id] ?? 0)
            } else {
                widths[edge.id] = 1.5
                let targetIsLeft = (nodeLane[edge.target]?.rawValue ?? 0) < (nodeLane[edge.source]?.rawValue ?? 0)
                let start = CGPoint(x: targetIsLeft ? source.minX : source.maxX, y: source.midY)
                let end = CGPoint(x: targetIsLeft ? target.maxX : target.minX, y: target.midY)
                curves[edge.id] = sankeyCurve(start: start, end: end)
            }
        }
        return TrafficGraphLayoutSnapshot(nodeFrames: frames, edgeCurves: curves, edgeWidths: widths)
    }

    static func edgeWidth(bytes: Int64, maximum: Int64) -> CGFloat {
        guard bytes > 0, maximum > 0 else { return 1.5 }
        let normalized = log10(Double(bytes) + 1) / log10(Double(maximum) + 1)
        return 1.5 + CGFloat(normalized) * 3.75
    }

    static func trafficWidth(bytes: Int64, maximum: Int64) -> CGFloat {
        guard bytes > 0, maximum > 0 else { return 0 }
        let normalized = log10(Double(bytes) + 1) / log10(Double(maximum) + 1)
        return 0.65 + CGFloat(normalized) * 2.6
    }

    static func ribbonWidth(bytes: Int64, maximum: Int64) -> CGFloat {
        guard bytes > 0, maximum > 0 else { return 0 }
        let normalized = log10(Double(bytes) + 1) / log10(Double(maximum) + 1)
        return 3 + CGFloat(normalized) * 21
    }

    private static func ribbonScale(
        edges: [TrafficGraphEdge],
        widths: [TrafficGraphEdgeID: CGFloat],
        frames: [TrafficGraphNodeID: CGRect]
    ) -> CGFloat {
        let bySource = Dictionary(grouping: edges, by: \.source)
        let byTarget = Dictionary(grouping: edges, by: \.target)
        let groups = Array(bySource) + Array(byTarget)
        return groups.reduce(CGFloat(1)) { scale, group in
            guard let height = frames[group.key]?.height else { return scale }
            let total = group.value.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 0) }
            guard total > 0 else { return scale }
            let available = max(1, height - 12 - CGFloat(max(0, group.value.count - 1)) * 2)
            return min(scale, available / total)
        }
    }

    private static func portCenters(
        for edges: [TrafficGraphEdge],
        in frame: CGRect,
        edgeWidths: [TrafficGraphEdgeID: CGFloat]
    ) -> [TrafficGraphEdgeID: CGPoint] {
        let gap: CGFloat = 2
        let total = edges.reduce(CGFloat(0)) { $0 + (edgeWidths[$1.id] ?? 0) }
            + CGFloat(max(0, edges.count - 1)) * gap
        var cursor = frame.midY - total / 2
        var result: [TrafficGraphEdgeID: CGPoint] = [:]
        for edge in edges {
            let width = edgeWidths[edge.id] ?? 0
            result[edge.id] = CGPoint(x: frame.midX, y: cursor + width / 2)
            cursor += width + gap
        }
        return result
    }

    private static func sankeyCurve(start: CGPoint, end: CGPoint, avoiding obstacles: [CGRect] = [],
                                    width: CGFloat = 0) -> TrafficGraphCurve {
        let controlOffset = max(24, abs(end.x - start.x) * 0.42)
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        let direct = TrafficGraphCurve(
            start: start,
            control1: CGPoint(x: start.x + controlOffset * direction, y: start.y),
            control2: CGPoint(x: end.x - controlOffset * direction, y: end.y),
            end: end
        )
        let padded = obstacles.map { $0.insetBy(dx: -(width / 2 + 6), dy: -(width / 2 + 6)) }
        guard padded.contains(where: { obstacle in
            (1..<80).contains(where: { step in
                obstacle.contains(direct.point(at: CGFloat(step) / 80))
            })
        }) else { return direct }

        let top = padded.map(\.minY).min() ?? min(start.y, end.y)
        let bottom = padded.map(\.maxY).max() ?? max(start.y, end.y)
        let above = top - 16
        let below = bottom + 16
        let routeY = abs(start.y - above) + abs(end.y - above) <= abs(start.y - below) + abs(end.y - below)
            ? above : below
        let firstX = start.x + (end.x - start.x) * 0.38
        let secondX = start.x + (end.x - start.x) * 0.62
        return TrafficGraphCurve(start: start, control1: CGPoint(x: firstX, y: routeY),
                                 control2: CGPoint(x: secondX, y: routeY), end: end)
    }

    private static func orderedNodes(snapshot: TrafficGraphSnapshot) -> [Lane: [TrafficGraphNode]] {
        var lanes = Dictionary(grouping: snapshot.nodes, by: lane(for:))
        for lane in Lane.allCases { lanes[lane] = (lanes[lane] ?? []).sorted { $0.id < $1.id } }

        for _ in 0..<3 {
            for lane in Lane.allCases {
                let neighbors = neighboringOrder(for: lane, lanes: lanes)
                guard !neighbors.isEmpty else { continue }
                let positions = Dictionary(uniqueKeysWithValues: neighbors.enumerated().map { ($1.id, CGFloat($0)) })
                let edgesByNode = Dictionary(grouping: snapshot.edges.flatMap { edge in
                    [(edge.source, edge.target), (edge.target, edge.source)]
                }, by: \.0)
                lanes[lane]?.sort { left, right in
                    let leftScore = median((edgesByNode[left.id] ?? []).compactMap { positions[$0.1] })
                    let rightScore = median((edgesByNode[right.id] ?? []).compactMap { positions[$0.1] })
                    if leftScore == rightScore { return left.id < right.id }
                    return leftScore < rightScore
                }
            }
        }
        return lanes
    }

    private static func neighboringOrder(for lane: Lane, lanes: [Lane: [TrafficGraphNode]]) -> [TrafficGraphNode] {
        switch lane {
        case .source: return (lanes[.intermediary] ?? []) + (lanes[.destination] ?? [])
        case .intermediary: return (lanes[.source] ?? []) + (lanes[.destination] ?? [])
        case .destination: return (lanes[.intermediary] ?? []) + (lanes[.source] ?? [])
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    private static func lane(for node: TrafficGraphNode) -> Lane {
        switch node.kind {
        case .app, .agent: return .source
        case .tool, .mcp: return .intermediary
        case .destination, .service: return .destination
        }
    }

    private static func size(for lane: Lane) -> CGSize {
        switch lane {
        case .source: return appSize
        case .intermediary: return intermediarySize
        case .destination: return destinationSize
        }
    }

    private static func place(size: CGSize, near preferred: CGPoint, laneX: CGFloat,
                              within bounds: CGRect, avoiding placed: [CGRect]) -> CGRect {
        func frame(y: CGFloat) -> CGRect {
            CGRect(x: laneX - size.width / 2, y: y - size.height / 2,
                   width: size.width, height: size.height)
        }
        func clamped(_ candidate: CGRect) -> CGRect {
            var result = candidate
            result.origin.y = min(bounds.maxY - result.height, max(bounds.minY, result.minY))
            return result
        }
        func clear(_ candidate: CGRect) -> Bool {
            !placed.contains { $0.insetBy(dx: -nodeGap / 2, dy: -nodeGap / 2).intersects(candidate) }
        }

        let initial = clamped(frame(y: preferred.y))
        if clear(initial) { return initial }
        for distance in stride(from: nodeGap + size.height, through: bounds.height, by: nodeGap + size.height) {
            for direction: CGFloat in [-1, 1] {
                let candidate = clamped(frame(y: preferred.y + distance * direction))
                if clear(candidate) { return candidate }
            }
        }
        return initial
    }

    private static func routedCurve(points: [CGPoint]) -> TrafficGraphCurve {
        let compacted = points.reduce(into: [CGPoint]()) { result, point in
            if result.last != point { result.append(point) }
        }
        let start = compacted.first ?? .zero
        let end = compacted.last ?? start
        return TrafficGraphCurve(start: start, control1: start, control2: end, end: end,
                                 routingPoints: compacted)
    }
}
