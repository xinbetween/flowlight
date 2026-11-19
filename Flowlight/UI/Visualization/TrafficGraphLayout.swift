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

    func visibleGraphRect(in screenBounds: CGRect) -> CGRect {
        let topLeft = graphPoint(for: CGPoint(x: screenBounds.minX, y: screenBounds.minY))
        let bottomRight = graphPoint(for: CGPoint(x: screenBounds.maxX, y: screenBounds.maxY))
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}

enum TrafficGraphViewportPolicy {
    static func shouldAutoFit(isUserControlled: Bool) -> Bool {
        !isUserControlled
    }

    static func shouldPreserveLayout(
        snapshot: TrafficGraphSnapshot,
        previous: TrafficGraphLayoutSnapshot
    ) -> Bool {
        Set(snapshot.nodes.map(\.id)) == Set(previous.nodeFrames.keys)
            && Set(snapshot.edges.map(\.id)) == previous.topologyEdgeIDs
    }
}

struct TrafficGraphCurveSegment: Equatable, Sendable {
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

    func derivative(at progress: CGFloat) -> CGVector {
        let t = min(1, max(0, progress))
        let inverse = 1 - t
        return CGVector(
            dx: 3 * inverse * inverse * (control1.x - start.x)
                + 6 * inverse * t * (control2.x - control1.x)
                + 3 * t * t * (end.x - control2.x),
            dy: 3 * inverse * inverse * (control1.y - start.y)
                + 6 * inverse * t * (control2.y - control1.y)
                + 3 * t * t * (end.y - control2.y)
        )
    }

    func offset(by distance: CGFloat, orientation: CGFloat) -> TrafficGraphCurveSegment {
        func shift(at progress: CGFloat) -> CGVector {
            var tangent = derivative(at: progress)
            var length = hypot(tangent.dx, tangent.dy)
            if length < 0.000_001 {
                tangent = CGVector(dx: end.x - start.x, dy: end.y - start.y)
                length = hypot(tangent.dx, tangent.dy)
            }
            guard length >= 0.000_001 else { return .zero }
            return CGVector(
                dx: -tangent.dy / length * orientation * distance,
                dy: tangent.dx / length * orientation * distance
            )
        }

        func shifted(_ point: CGPoint, by shift: CGVector) -> CGPoint {
            CGPoint(x: point.x + shift.dx, y: point.y + shift.dy)
        }

        // Moving each endpoint and its adjacent control by the same vector preserves that endpoint's tangent exactly.
        // Adjacent centerline segments share the same tangent, so they also share one shifted join and remain smooth.
        let startShift = shift(at: 0)
        let endShift = shift(at: 1)
        return TrafficGraphCurveSegment(
            start: shifted(start, by: startShift),
            control1: shifted(control1, by: startShift),
            control2: shifted(control2, by: endShift),
            end: shifted(end, by: endShift)
        )
    }
}

struct TrafficGraphCurve: Equatable, Sendable {
    var segments: [TrafficGraphCurveSegment]

    var start: CGPoint { segments.first?.start ?? .zero }
    var end: CGPoint { segments.last?.end ?? .zero }

    init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        segments = [TrafficGraphCurveSegment(
            start: start,
            control1: control1,
            control2: control2,
            end: end
        )]
    }

    init(segments: [TrafficGraphCurveSegment]) {
        precondition(!segments.isEmpty)
        self.segments = segments
    }

    var points: [CGPoint] {
        let count = max(24, segments.count * 24)
        return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
    }

    func point(at progress: CGFloat) -> CGPoint {
        let scaled = min(1, max(0, progress)) * CGFloat(segments.count)
        let index = min(segments.count - 1, Int(scaled))
        let localProgress = index == segments.count - 1 && scaled == CGFloat(segments.count)
            ? 1
            : scaled - CGFloat(index)
        return segments[index].point(at: localProgress)
    }

    func hasContinuousTangents(tolerance: CGFloat = 0.001) -> Bool {
        let meaningful = segments.filter { segment in
            hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y) > 0.001
        }
        guard meaningful.count > 1 else { return true }
        for index in 0..<(meaningful.count - 1) {
            let outgoing = meaningful[index].derivative(at: 1)
            let incoming = meaningful[index + 1].derivative(at: 0)
            let outgoingLength = hypot(outgoing.dx, outgoing.dy)
            let incomingLength = hypot(incoming.dx, incoming.dy)
            guard outgoingLength > 0.001, incomingLength > 0.001 else { return false }
            let cross = abs(outgoing.dx * incoming.dy - outgoing.dy * incoming.dx)
            let dot = outgoing.dx * incoming.dx + outgoing.dy * incoming.dy
            guard dot > 0, cross <= tolerance * outgoingLength * incomingLength else { return false }
        }
        return true
    }

    func hasLongHorizontalShelf(minimumLength: CGFloat = 80, tolerance: CGFloat = 0.5) -> Bool {
        if segments.count == 1, let segment = segments.first {
            let ys = [segment.start.y, segment.control1.y, segment.control2.y, segment.end.y]
            let verticalRange = (ys.max() ?? 0) - (ys.min() ?? 0)
            if verticalRange <= 12 { return false }
        }

        if segments.contains(where: { segment in
            guard abs(segment.end.x - segment.start.x) >= minimumLength else { return false }
            let ys = [segment.start.y, segment.control1.y, segment.control2.y, segment.end.y]
            return (ys.max() ?? 0) - (ys.min() ?? 0) <= tolerance
        }) {
            return true
        }

        // A single cubic can still read as a rounded rectangle when one horizontal endpoint handle consumes most of
        // the route. This escaped the segment-only check because the curve itself remained continuous. Keep ordinary
        // balanced Sankey curves, but reject a long flat departure or arrival that postpones almost the entire bend.
        guard segments.count == 1, let segment = segments.first else { return false }
        let span = abs(segment.end.x - segment.start.x)
        let ys = [segment.start.y, segment.control1.y, segment.control2.y, segment.end.y]
        let verticalRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard span >= minimumLength, verticalRange > 12 else { return false }
        let dominantHandle = max(minimumLength, span * 0.60)
        let startHandleX = abs(segment.control1.x - segment.start.x)
        let startHandleY = abs(segment.control1.y - segment.start.y)
        let endHandleX = abs(segment.end.x - segment.control2.x)
        let endHandleY = abs(segment.end.y - segment.control2.y)
        let startShelf = startHandleX >= dominantHandle
            && startHandleY <= max(tolerance, startHandleX * 0.20)
        let endShelf = endHandleX >= dominantHandle
            && endHandleY <= max(tolerance, endHandleX * 0.20)
        return startShelf || endShelf
    }

    func hasLongVerticalShelf(minimumLength: CGFloat = 80, tolerance: CGFloat = 12) -> Bool {
        if segments.contains(where: { segment in
            guard abs(segment.end.y - segment.start.y) >= minimumLength else { return false }
            let xs = [segment.start.x, segment.control1.x, segment.control2.x, segment.end.x]
            return (xs.max() ?? 0) - (xs.min() ?? 0) <= tolerance
        }) {
            return true
        }

        if segments.count > 1 {
            // Multi-segment curves come only from the separately bounded fallback (at most 64 candidates), so sample
            // those complete shapes. The much larger primary single-cubic search stays constant-time below.
            let sampleCount = segments.count * 64
            var runStart = point(at: 0)
            var previous = runStart
            var minimumX = runStart.x
            var maximumX = runStart.x
            for sample in 1...sampleCount {
                let current = point(at: CGFloat(sample) / CGFloat(sampleCount))
                let deltaX = abs(current.x - previous.x)
                let deltaY = abs(current.y - previous.y)
                if deltaY > 0.5, deltaX <= max(0.5, deltaY * 0.12) {
                    minimumX = min(minimumX, current.x)
                    maximumX = max(maximumX, current.x)
                    if abs(current.y - runStart.y) >= minimumLength,
                       maximumX - minimumX <= tolerance {
                        return true
                    }
                } else {
                    runStart = current
                    minimumX = current.x
                    maximumX = current.x
                }
                previous = current
            }
            return false
        }

        // A dominant near-vertical endpoint handle is the single-cubic equivalent of a tall rectangular shelf.
        guard let segment = segments.first else { return false }
        let ys = [segment.start.y, segment.control1.y, segment.control2.y, segment.end.y]
        let verticalRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard verticalRange >= minimumLength else { return false }
        let dominantHandle = max(minimumLength, verticalRange * 0.60)
        let startHandleX = abs(segment.control1.x - segment.start.x)
        let startHandleY = abs(segment.control1.y - segment.start.y)
        let endHandleX = abs(segment.end.x - segment.control2.x)
        let endHandleY = abs(segment.end.y - segment.control2.y)
        let startShelf = startHandleY >= dominantHandle
            && startHandleX <= max(tolerance, startHandleY * 0.12)
        let endShelf = endHandleY >= dominantHandle
            && endHandleX <= max(tolerance, endHandleY * 0.12)
        return startShelf || endShelf
    }

    func hasPinchedVerticalTurn(
        minimumRise: CGFloat = 80,
        minimumRunRatio: CGFloat = 0.5
    ) -> Bool {
        let requiredRunRatio = segments.count > 1 ? max(0.8, minimumRunRatio) : minimumRunRatio
        return segments.contains { segment in
            let verticalDistance = abs(segment.end.y - segment.start.y)
            guard verticalDistance >= minimumRise else { return false }

            let xs = [segment.start.x, segment.control1.x, segment.control2.x, segment.end.x]
            let horizontalRange = (xs.max() ?? 0) - (xs.min() ?? 0)
            guard horizontalRange < verticalDistance * requiredRunRatio else { return false }

            let startTangent = segment.derivative(at: 0)
            let endTangent = segment.derivative(at: 1)
            let startsHorizontally = abs(startTangent.dx) >= abs(startTangent.dy) * 0.75
            let endsHorizontally = abs(endTangent.dx) >= abs(endTangent.dy) * 0.75
            return startsHorizontally || endsHorizontally
        }
    }

    /// Offsets a ribbon boundary along the curve normal while keeping horizontal node-port tangents flush with cards.
    func offset(by distance: CGFloat) -> TrafficGraphCurve {
        let horizontalDelta = end.x - start.x
        let verticalDelta = end.y - start.y
        let orientation: CGFloat
        if abs(horizontalDelta) >= abs(verticalDelta) {
            orientation = horizontalDelta >= 0 ? 1 : -1
        } else {
            orientation = verticalDelta >= 0 ? 1 : -1
        }
        return TrafficGraphCurve(
            segments: segments.map { $0.offset(by: distance, orientation: orientation) }
        )
    }

    func hitTestSteps(maximumSegmentLength: CGFloat) -> Int {
        let controlPolygon = segments.reduce(CGFloat(0)) { length, segment in
            length + segment.start.distance(to: segment.control1)
                + segment.control1.distance(to: segment.control2)
                + segment.control2.distance(to: segment.end)
        }
        return max(12, Int(ceil(controlPolygon / maximumSegmentLength)))
    }
}

enum TrafficGraphFlowDirection: Equatable, Sendable {
    case received
    case sent
    case invocation
}

struct TrafficGraphFlowDashLane: Equatable, Sendable {
    var width: CGFloat
    var offset: CGFloat
}

struct TrafficGraphFlowDashLanes: Equatable, Sendable {
    var received: TrafficGraphFlowDashLane
    var sent: TrafficGraphFlowDashLane
}

private enum TrafficGraphStableHash {
    static func fnv1a(_ value: String) -> UInt64 {
        // FNV-1a is stable across launches; Swift's Hasher deliberately is not.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

enum TrafficGraphFlowDash {
    /// Short rounded marks read as directional light pulses without requiring one animated view per edge.
    static let pattern: [CGFloat] = [4, 22]
    static let strokeWidth: CGFloat = GraphStyle.flowPulseWidth
    static let frameInterval: TimeInterval = 1 / 30
    private static let basePointsPerSecond: CGFloat = 32
    private static let minimumSpeedMultiplier: CGFloat = 0.70
    private static let speedVariation: CGFloat = 0.60

    static func animates(_ edge: TrafficGraphEdge) -> Bool {
        edge.relationship == .observed && edge.counters.total > 0
    }

    static func speed(for edgeID: TrafficGraphEdgeID) -> CGFloat {
        let unit = CGFloat(Double(stableHash(edgeID)) / Double(UInt64.max))
        return basePointsPerSecond * (minimumSpeedMultiplier + unit * speedVariation)
    }

    static func speeds(for edgeIDs: [TrafficGraphEdgeID]) -> [TrafficGraphEdgeID: CGFloat] {
        let ordered = Set(edgeIDs).sorted { left, right in
            let leftHash = stableHash(left)
            let rightHash = stableHash(right)
            return leftHash == rightHash ? left < right : leftHash < rightHash
        }
        var used: Set<CGFloat> = []
        var result: [TrafficGraphEdgeID: CGFloat] = [:]
        for edgeID in ordered {
            var candidate = speed(for: edgeID)
            while used.contains(candidate) { candidate = candidate.nextUp }
            used.insert(candidate)
            result[edgeID] = candidate
        }
        return result
    }

    static func phase(
        at time: TimeInterval,
        edgeID: TrafficGraphEdgeID,
        direction: TrafficGraphFlowDirection,
        speed: CGFloat? = nil
    ) -> CGFloat {
        let cycle = pattern.reduce(CGFloat(0), +)
        let distance = (CGFloat(time) * (speed ?? self.speed(for: edgeID)))
            .truncatingRemainder(dividingBy: cycle)
        return direction == .received ? distance : -distance
    }

    private static func stableHash(_ edgeID: TrafficGraphEdgeID) -> UInt64 {
        TrafficGraphStableHash.fnv1a(edgeID.rawValue)
    }

    static func borderOffset(
        totalWidth: CGFloat,
        direction: TrafficGraphFlowDirection,
        paintedWidth: CGFloat = strokeWidth
    ) -> CGFloat {
        let width = max(0, totalWidth)
        let inset = min(max(0, paintedWidth) / 2, width / 2)
        switch direction {
        case .received: return -width / 2 + inset
        case .sent: return width / 2 - inset
        case .invocation: return 0
        }
    }

    static func lanes(counters: FlowCounters, totalWidth: CGFloat) -> TrafficGraphFlowDashLanes {
        let width = max(0, totalWidth)
        let totalBytes = max(0, counters.bytesIn) + max(0, counters.bytesOut)
        guard totalBytes > 0 else {
            let empty = TrafficGraphFlowDashLane(width: 0, offset: 0)
            return TrafficGraphFlowDashLanes(received: empty, sent: empty)
        }

        let receivedWidth = width * CGFloat(max(0, counters.bytesIn)) / CGFloat(totalBytes)
        let sentWidth = width - receivedWidth
        return TrafficGraphFlowDashLanes(
            received: TrafficGraphFlowDashLane(width: receivedWidth, offset: -sentWidth / 2),
            sent: TrafficGraphFlowDashLane(width: sentWidth, offset: receivedWidth / 2)
        )
    }

    static func boundedStrokeWidth(preferred: CGFloat, laneWidth: CGFloat) -> CGFloat {
        min(max(0, preferred), max(0, laneWidth))
    }

    static func paintedLane(
        totalWidth: CGFloat,
        direction: TrafficGraphFlowDirection,
        preferredWidth: CGFloat,
        laneWidth: CGFloat
    ) -> TrafficGraphFlowDashLane {
        let width = boundedStrokeWidth(preferred: preferredWidth, laneWidth: laneWidth)
        return TrafficGraphFlowDashLane(
            width: width,
            offset: borderOffset(totalWidth: totalWidth, direction: direction, paintedWidth: width)
        )
    }
}

enum TrafficGraphMotionPolicy {
    static func animatesFlow(reduceMotion: Bool, hasVisibleFlow: Bool) -> Bool {
        !reduceMotion && hasVisibleFlow
    }

    /// Prioritizes the person's current focus, then the busiest visible paths. The stable ID tie-break keeps the
    /// animated set from flickering when counters are equal or the source order changes.
    static func activeEdgeIDs(
        edges: [TrafficGraphEdge],
        visibleEdgeIDs: Set<TrafficGraphEdgeID>,
        selectedNode: TrafficGraphNodeID?,
        selectedEdge: TrafficGraphEdgeID?,
        hoveredEdge: TrafficGraphEdgeID?,
        limit: Int = GraphStyle.maximumAnimatedEdges
    ) -> [TrafficGraphEdgeID] {
        guard limit > 0 else { return [] }
        let candidates = edges.filter {
            visibleEdgeIDs.contains($0.id) && TrafficGraphFlowDash.animates($0)
        }
        let candidateIDs = Set(candidates.map(\.id))
        var result: [TrafficGraphEdgeID] = []
        var added: Set<TrafficGraphEdgeID> = []

        func append(_ id: TrafficGraphEdgeID?) {
            guard let id, candidateIDs.contains(id), added.insert(id).inserted, result.count < limit else { return }
            result.append(id)
        }

        append(selectedEdge)
        append(hoveredEdge)

        let ranked = candidates.sorted {
            if $0.displayedCounters.total != $1.displayedCounters.total {
                return $0.displayedCounters.total > $1.displayedCounters.total
            }
            return $0.id < $1.id
        }
        if let selectedNode {
            for edge in ranked where edge.source == selectedNode || edge.target == selectedNode {
                append(edge.id)
            }
        }
        for edge in ranked { append(edge.id) }
        return result
    }
}

struct TrafficGraphLayoutKey: Equatable, Sendable {
    var nodeIDs: [TrafficGraphNodeID]
    var edgeIDs: [TrafficGraphEdgeID]
    var width: Int
    var height: Int

    init(snapshot: TrafficGraphSnapshot, size: CGSize) {
        nodeIDs = snapshot.nodes.map(\.id)
        edgeIDs = snapshot.edges.map(\.id)
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
    }
}

/// Restarts viewport fitting when the visible canvas settles or resizes, even if the graph's minimum layout canvas
/// remains unchanged. The nested layout key still controls atomic geometry publication independently.
struct TrafficGraphRenderKey: Equatable, Sendable {
    var layout: TrafficGraphLayoutKey
    var viewportWidth: Int
    var viewportHeight: Int

    init(snapshot: TrafficGraphSnapshot, graphSize: CGSize, viewportSize: CGSize) {
        layout = TrafficGraphLayoutKey(snapshot: snapshot, size: graphSize)
        viewportWidth = Int(viewportSize.width.rounded())
        viewportHeight = Int(viewportSize.height.rounded())
    }
}

struct TrafficGraphVisibleRegion: Equatable, Sendable {
    var nodeIDs: Set<TrafficGraphNodeID>
    var edgeIDs: Set<TrafficGraphEdgeID>
}

struct TrafficGraphLayoutSnapshot: Sendable {
    var nodeFrames: [TrafficGraphNodeID: CGRect]
    var edgeCurves: [TrafficGraphEdgeID: TrafficGraphCurve]
    /// Complete semantic topology, including an edge whose geometry cannot be drawn without crossing a card.
    /// Older focused tests and synthetic snapshots infer it from their drawable curves.
    var semanticEdgeIDs: Set<TrafficGraphEdgeID> = []
    var edgeWidths: [TrafficGraphEdgeID: CGFloat] = [:]
    var edgeWidthCaps: [TrafficGraphEdgeID: CGFloat] = [:]
    var edgeBounds: [TrafficGraphEdgeID: CGRect] = [:]

    var topologyEdgeIDs: Set<TrafficGraphEdgeID> {
        semanticEdgeIDs.isEmpty ? Set(edgeCurves.keys) : semanticEdgeIDs
    }

    var omittedEdgeIDs: Set<TrafficGraphEdgeID> {
        topologyEdgeIDs.subtracting(edgeCurves.keys)
    }

    var contentBounds: CGRect {
        let nodes = nodeFrames.values.reduce(CGRect.null) { $0.union($1) }
        return resolvedEdgeBounds.reduce(nodes) { $0.union($1.value) }
    }

    func updatingTrafficWidths(for snapshot: TrafficGraphSnapshot) -> TrafficGraphLayoutSnapshot {
        var updated = self
        updated.edgeWidths = TrafficGraphLayout.trafficWidths(
            for: snapshot,
            caps: edgeWidthCaps
        )
        return updated
    }

    func visibleRegion(in graphRect: CGRect, margin: CGFloat = 80) -> TrafficGraphVisibleRegion {
        let expanded = graphRect.insetBy(dx: -max(0, margin), dy: -max(0, margin))
        let nodes = Set(nodeFrames.compactMap { id, frame in
            frame.intersects(expanded) ? id : nil
        })
        let edges = Set(resolvedEdgeBounds.compactMap { id, bounds in
            bounds.intersects(expanded) ? id : nil
        })
        return TrafficGraphVisibleRegion(nodeIDs: nodes, edgeIDs: edges)
    }

    private var resolvedEdgeBounds: [TrafficGraphEdgeID: CGRect] {
        guard edgeBounds.count != edgeCurves.count else { return edgeBounds }
        return Dictionary(uniqueKeysWithValues: edgeCurves.map { id, curve in
            let width = max(1, edgeWidthCaps[id] ?? edgeWidths[id] ?? 1)
            let bounds = curve.points.reduce(CGRect.null) { partial, point in
                partial.union(CGRect(x: point.x - width / 2, y: point.y - width / 2,
                                     width: width, height: width))
            }
            return (id, bounds)
        })
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
}

enum TrafficGraphLayout {
    private struct ParallelEdgeKey: Hashable {
        var source: TrafficGraphNodeID
        var target: TrafficGraphNodeID
    }

    private enum Lane: Int, CaseIterable {
        case upstreamLauncher
        case launcher
        case source
        case tool
        case gateway
        case inspectionProxy
        case destination
    }

    enum CardSide: Hashable {
        case left
        case right

        var opposite: CardSide { self == .left ? .right : .left }
    }

    private struct PortKey: Hashable {
        var node: TrafficGraphNodeID
        var side: CardSide
    }

    private struct PortAssignment {
        var edge: TrafficGraphEdge
        var isSource: Bool
    }

    static let appSize = CGSize(width: 132, height: 52)
    static let destinationSize = CGSize(width: 150, height: 52)
    private static let intermediarySize = CGSize(width: 144, height: 52)
    private static let baseNodeGap: CGFloat = 10
    static let relationshipWidth: CGFloat = 1.5
    static let flowOnlyRibbonWidth: CGFloat = 1.5
    static let maximumRibbonWidth: CGFloat = 24
    static let trafficScaleFloorBytes: Int64 = 1_024
    static let trafficScaleCeilingBytes: Int64 = 1_073_741_824
    static let maximumPrimaryRouteBands = 16
    static let maximumPrimaryRouteCandidates = 2_048

    static func boundedRouteBands(_ ranked: [CGFloat], obstacleCount: Int) -> [CGFloat] {
        Array(ranked.prefix(obstacleCount > 160 ? 4 : maximumPrimaryRouteBands))
    }

    static func routeClearance(width: CGFloat, obstacleCount _: Int) -> CGFloat {
        10 + max(0.5, width / 2)
    }

    static func minimumCanvasWidth(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        let nodeLanes = lanes(snapshot: snapshot)
        let activeLanes = Lane.allCases.filter { lane in
            snapshot.nodes.contains { nodeLanes[$0.id] == lane }
        }
        let cards = activeLanes.reduce(CGFloat(0)) { $0 + size(for: $1).width }
        let gaps = columnGaps(for: snapshot).reduce(CGFloat(0), +)
        return max(900, cards + gaps + 48)
    }

    static func minimumCanvasHeight(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        let nodeLanes = lanes(snapshot: snapshot)
        let largestLane = Dictionary(grouping: snapshot.nodes, by: { nodeLanes[$0.id] }).values
            .map(\.count).max() ?? 0
        let gap = nodeGap(for: snapshot)
        let stackHeight = CGFloat(largestLane) * appSize.height
            + CGFloat(max(0, largestLane - 1)) * gap
        return max(760, stackHeight + 104)
    }

    static func layout(
        snapshot: TrafficGraphSnapshot,
        in bounds: CGRect,
        preserving previous: TrafficGraphLayoutSnapshot? = nil,
        placementObserver: (@Sendable () -> Void)? = nil
    ) -> TrafficGraphLayoutSnapshot {
        guard !snapshot.nodes.isEmpty, bounds.width > 0, bounds.height > 0,
              !Task<Never, Never>.isCancelled else {
            return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
        }

        let nodeLanes = lanes(snapshot: snapshot)
        let ordered = orderedNodes(snapshot: snapshot, nodeLanes: nodeLanes)
        let activeLanes = Lane.allCases.filter { !(ordered[$0] ?? []).isEmpty }
        let verticalGap = nodeGap(for: snapshot)
        let requiredStackHeight = activeLanes.map { lane -> CGFloat in
            let count = ordered[lane]?.count ?? 0
            return CGFloat(count) * size(for: lane).height
                + CGFloat(max(0, count - 1)) * verticalGap
        }.max() ?? 0
        let availableRouteMargin = max(12, (bounds.height - requiredStackHeight) / 2)
        let routeMargin = min(routingMargin(for: snapshot), availableRouteMargin)
        let insetBounds = bounds.insetBy(dx: 24, dy: routeMargin)
        let columns = columnPositions(
            for: activeLanes,
            in: insetBounds,
            minimumGaps: columnGaps(for: snapshot)
        )
        var frames: [TrafficGraphNodeID: CGRect] = [:]

        if let previous {
            for node in snapshot.nodes {
                if Task<Never, Never>.isCancelled {
                    return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
                }
                guard var frame = previous.nodeFrames[node.id] else { continue }
                guard let lane = nodeLanes[node.id] else { continue }
                guard let column = columns[lane] else { continue }
                frame.origin.x = column - frame.width / 2
                guard frame.minY >= insetBounds.minY, frame.maxY <= insetBounds.maxY else { continue }
                frames[node.id] = frame
            }
        }

        guard placeMissingNodes(
            ordered: ordered,
            activeLanes: activeLanes,
            columns: columns,
            insetBounds: insetBounds,
            gap: verticalGap,
            frames: &frames,
            placementObserver: placementObserver
        ) else {
            return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
        }
        if hasOverlaps(frames.values, gap: verticalGap) {
            guard !Task<Never, Never>.isCancelled else {
                return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
            }
            frames = [:]
            guard placeMissingNodes(
                ordered: ordered,
                activeLanes: activeLanes,
                columns: columns,
                insetBounds: insetBounds,
                gap: verticalGap,
                frames: &frames,
                placementObserver: placementObserver
            ) else {
                return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
            }
        }
        guard !Task<Never, Never>.isCancelled else {
            return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
        }

        let trafficRibbons = snapshot.edges.filter(\.isTrafficRibbon)
        let routeVariations = Dictionary(uniqueKeysWithValues: trafficRibbons
            .sorted { $0.id < $1.id }
            .enumerated()
            .map { ($0.element.id, $0.offset) })
        var sourceSides: [TrafficGraphEdgeID: CardSide] = [:]
        var targetSides: [TrafficGraphEdgeID: CardSide] = [:]
        var assignments: [PortKey: [PortAssignment]] = [:]
        for edge in snapshot.edges {
            let sourceLane = nodeLanes[edge.source] ?? .source
            let targetLane = nodeLanes[edge.target] ?? .source
            let sourceSide: CardSide
            let targetSide: CardSide
            if sourceLane == targetLane {
                sourceSide = stableSide(for: edge.id)
                targetSide = sourceSide
            } else {
                sourceSide = sourceLane.rawValue < targetLane.rawValue ? .right : .left
                targetSide = sourceSide.opposite
            }
            sourceSides[edge.id] = sourceSide
            targetSides[edge.id] = targetSide
            assignments[PortKey(node: edge.source, side: sourceSide), default: []]
                .append(PortAssignment(edge: edge, isSource: true))
            assignments[PortKey(node: edge.target, side: targetSide), default: []]
                .append(PortAssignment(edge: edge, isSource: false))
        }

        let capacityWidths = ribbonCapacities(
            edges: trafficRibbons,
            assignments: assignments,
            frames: frames
        )
        var widths = trafficWidths(for: snapshot, caps: capacityWidths)
        var portWidths = capacityWidths
        for edge in snapshot.edges where !edge.isTrafficRibbon {
            widths[edge.id] = relationshipWidth
            portWidths[edge.id] = relationshipWidth
        }

        var sourcePorts: [TrafficGraphEdgeID: CGPoint] = [:]
        var targetPorts: [TrafficGraphEdgeID: CGPoint] = [:]
        for (key, group) in assignments {
            guard let frame = frames[key.node] else { continue }
            let sorted = group.sorted { left, right in
                let leftNode = left.isSource ? left.edge.target : left.edge.source
                let rightNode = right.isSource ? right.edge.target : right.edge.source
                let leftY = frames[leftNode]?.midY ?? 0
                let rightY = frames[rightNode]?.midY ?? 0
                return leftY == rightY ? left.edge.id < right.edge.id : leftY < rightY
            }
            let centers = portCenters(for: sorted.map(\.edge), in: frame, edgeWidths: portWidths)
            for assignment in sorted {
                guard let center = centers[assignment.edge.id] else { continue }
                if assignment.isSource {
                    sourcePorts[assignment.edge.id] = center
                } else {
                    targetPorts[assignment.edge.id] = center
                }
            }
        }

        let parallelRelationships = Dictionary(grouping: snapshot.edges.filter { !$0.isTrafficRibbon }) {
            ParallelEdgeKey(source: $0.source, target: $0.target)
        }.mapValues { $0.sorted { $0.id < $1.id } }
        var parallelOffsets: [TrafficGraphEdgeID: CGFloat] = [:]
        for edges in parallelRelationships.values where edges.count > 1 {
            let midpoint = CGFloat(edges.count - 1) / 2
            for (index, edge) in edges.enumerated() {
                parallelOffsets[edge.id] = (CGFloat(index) - midpoint) * 16
            }
        }

        var curves: [TrafficGraphEdgeID: TrafficGraphCurve] = [:]
        let separatesRouteCorridors = snapshot.edges.count <= 160
        for edge in snapshot.edges.sorted(by: { $0.id < $1.id }) {
            if Task<Never, Never>.isCancelled {
                return TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
            }
            guard let source = frames[edge.source], let target = frames[edge.target],
                  let sourceSide = sourceSides[edge.id], let targetSide = targetSides[edge.id],
                  let sourcePort = sourcePorts[edge.id], let targetPort = targetPorts[edge.id] else { continue }
            let portInset: CGFloat = edge.isTrafficRibbon ? 0.5 : 0
            let start = CGPoint(
                x: sourceSide == .left ? source.minX + portInset : source.maxX - portInset,
                y: sourcePort.y
            )
            let end = CGPoint(
                x: targetSide == .left ? target.minX + portInset : target.maxX - portInset,
                y: targetPort.y
            )
            let width = portWidths[edge.id] ?? relationshipWidth
            let fanoutOffset = parallelOffsets[edge.id] ?? 0
            let obstacles = unrelatedObstacles(
                for: edge,
                from: frames,
                between: start,
                and: end
            )
            let direct: TrafficGraphCurve?
            if nodeLanes[edge.source] == nodeLanes[edge.target] {
                direct = sameLaneCurve(
                    start: start,
                    end: end,
                    side: sourceSide,
                    avoiding: obstacles,
                    width: width,
                    within: bounds
                )
            } else if edge.isTrafficRibbon {
                direct = sankeyCurve(
                    start: start,
                    end: end,
                    avoiding: obstacles,
                    width: width,
                    within: bounds,
                    variation: routeVariations[edge.id] ?? 0,
                    avoidingRoutes: separatesRouteCorridors ? Array(curves.values) : []
                )
            } else {
                direct = parallelCurve(start: start, end: end, fanout: fanoutOffset,
                                       routeOffset: fanoutOffset, avoiding: obstacles,
                                       width: width, within: bounds)
            }
            if let direct {
                curves[edge.id] = direct
            }
        }
        var widthCaps = capacityWidths
        for edge in snapshot.edges where !edge.isTrafficRibbon {
            widthCaps[edge.id] = relationshipWidth
        }
        let boundsByEdge = edgeBounds(curves: curves, widths: widthCaps)
        return TrafficGraphLayoutSnapshot(
            nodeFrames: frames,
            edgeCurves: curves,
            semanticEdgeIDs: Set(snapshot.edges.map(\.id)),
            edgeWidths: widths,
            edgeWidthCaps: widthCaps,
            edgeBounds: boundsByEdge
        )
    }

    static func crossingCount(
        snapshot: TrafficGraphSnapshot,
        layout: TrafficGraphLayoutSnapshot
    ) -> Int {
        let positioned = snapshot.edges.compactMap { edge -> (CGRect, CGRect)? in
            guard let source = layout.nodeFrames[edge.source],
                  let target = layout.nodeFrames[edge.target] else { return nil }
            return (source, target)
        }
        var crossings = 0
        for left in positioned.indices {
            for right in positioned.indices where right > left {
                let first = positioned[left]
                let second = positioned[right]
                guard abs(first.0.midX - second.0.midX) < 0.5,
                      abs(first.1.midX - second.1.midX) < 0.5 else { continue }
                let sourceDelta = first.0.midY - second.0.midY
                let targetDelta = first.1.midY - second.1.midY
                if sourceDelta * targetDelta < 0 { crossings += 1 }
            }
        }
        return crossings
    }

    static func ribbonWidth(counters: FlowCounters) -> CGFloat {
        let bytes = counters.total
        guard bytes > 0 else {
            return counters.flows > 0 ? flowOnlyRibbonWidth : 0
        }
        guard bytes > trafficScaleFloorBytes else { return 3 }
        let logarithmicRange = log10(
            Double(trafficScaleCeilingBytes) / Double(trafficScaleFloorBytes)
        )
        let normalized = min(
            1,
            log10(Double(bytes) / Double(trafficScaleFloorBytes)) / logarithmicRange
        )
        return 3 + CGFloat(normalized) * (maximumRibbonWidth - 3)
    }

    static func trafficWidths(
        for snapshot: TrafficGraphSnapshot,
        caps: [TrafficGraphEdgeID: CGFloat]
    ) -> [TrafficGraphEdgeID: CGFloat] {
        Dictionary(uniqueKeysWithValues: snapshot.edges.map { edge in
            guard edge.isTrafficRibbon else { return (edge.id, relationshipWidth) }
            let width = ribbonWidth(counters: edge.displayedCounters)
            guard width > 0 else { return (edge.id, 0) }
            let cap = max(0, caps[edge.id] ?? maximumRibbonWidth)
            let capacityScale = min(1, cap / maximumRibbonWidth)
            return (edge.id, width * capacityScale)
        })
    }

    private static func ribbonCapacities(
        edges: [TrafficGraphEdge],
        assignments: [PortKey: [PortAssignment]],
        frames: [TrafficGraphNodeID: CGRect]
    ) -> [TrafficGraphEdgeID: CGFloat] {
        // A capacity is the largest envelope this topology can paint, not the edge's width at one moment in time.
        // Using maximum-width envelopes makes live counter refreshes grow inside their reserved ports. Each endpoint
        // contributes only its own constraint, so a crowded card cannot shrink an unrelated part of the graph.
        var capacities = Dictionary(uniqueKeysWithValues: edges.map {
            ($0.id, maximumRibbonWidth)
        })
        for (key, group) in assignments {
            guard let height = frames[key.node]?.height else { continue }
            let ribbons = group.filter { $0.edge.isTrafficRibbon }
            guard !ribbons.isEmpty else { continue }
            let fixedWidth = group.reduce(CGFloat(0)) {
                $0 + ($1.edge.isTrafficRibbon ? 0 : relationshipWidth)
            }
            let gaps = CGFloat(max(0, group.count - 1)) * 2
            let available = max(1, height - 12 - fixedWidth - gaps)
            let maximumTotal = CGFloat(ribbons.count) * maximumRibbonWidth
            let scale = min(1, available / maximumTotal)
            for assignment in ribbons {
                capacities[assignment.edge.id] = min(
                    capacities[assignment.edge.id] ?? maximumRibbonWidth,
                    maximumRibbonWidth * scale
                )
            }
        }
        return capacities
    }

    private static func edgeBounds(
        curves: [TrafficGraphEdgeID: TrafficGraphCurve],
        widths: [TrafficGraphEdgeID: CGFloat]
    ) -> [TrafficGraphEdgeID: CGRect] {
        Dictionary(uniqueKeysWithValues: curves.map { id, curve in
            let width = max(1, widths[id] ?? 1)
            let bounds = curve.points.reduce(CGRect.null) { partial, point in
                partial.union(CGRect(x: point.x - width / 2, y: point.y - width / 2,
                                     width: width, height: width))
            }
            return (id, bounds)
        })
    }

    private static func portCenters(
        for edges: [TrafficGraphEdge],
        in frame: CGRect,
        edgeWidths: [TrafficGraphEdgeID: CGFloat]
    ) -> [TrafficGraphEdgeID: CGPoint] {
        guard !edges.isEmpty else { return [:] }
        let padding: CGFloat = 6
        let widths = edges.map { max(0, edgeWidths[$0.id] ?? 0) }
        let available = max(1, frame.height - padding * 2)
        let widthTotal = widths.reduce(0, +)
        let gapCount = max(0, edges.count - 1)
        let gap = gapCount == 0 ? 0 : min(2, max(0, (available - widthTotal) / CGFloat(gapCount)))
        let total = min(available, widthTotal + CGFloat(gapCount) * gap)
        var cursor = frame.midY - total / 2
        var result: [TrafficGraphEdgeID: CGPoint] = [:]
        for (index, edge) in edges.enumerated() {
            let width = widths[index]
            let minimum = frame.minY + padding + width / 2
            let maximum = frame.maxY - padding - width / 2
            let center = min(maximum, max(minimum, cursor + width / 2))
            result[edge.id] = CGPoint(x: frame.midX, y: center)
            cursor += width + gap
        }
        return result
    }

    private static func unrelatedObstacles(
        for edge: TrafficGraphEdge,
        from frames: [TrafficGraphNodeID: CGRect],
        between start: CGPoint,
        and end: CGPoint
    ) -> [CGRect] {
        let horizontalRange = min(start.x, end.x)...max(start.x, end.x)
        return frames.compactMap { id, frame in
            // Sibling cards in the endpoint columns cannot be treated as obstacles: every route has to leave and
            // enter those columns inside their padded horizontal span. Only cards wholly between the attachment
            // points can block the route; those are the cards a cable can otherwise visibly pass through.
            guard id != edge.source, id != edge.target,
                  frame.minX > horizontalRange.lowerBound,
                  frame.maxX < horizontalRange.upperBound else { return nil }
            return frame
        }
    }

    private static func routingMargin(for _: TrafficGraphSnapshot) -> CGFloat { 52 }

    private static func stableSide(for edgeID: TrafficGraphEdgeID) -> CardSide {
        TrafficGraphStableHash.fnv1a(edgeID.rawValue).isMultiple(of: 2) ? .left : .right
    }

    static func sameLaneCurve(
        start: CGPoint,
        end: CGPoint,
        side: CardSide,
        avoiding obstacles: [CGRect],
        width: CGFloat,
        within bounds: CGRect
    ) -> TrafficGraphCurve? {
        let halfWidth = max(0.5, width / 2)
        let clearance = 10 + halfWidth
        let padded = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let baseOffset = max(36 + halfWidth, min(180, abs(end.y - start.y) * 0.35))
        let minimumX = bounds.minX + halfWidth + 2
        let maximumX = bounds.maxX - halfWidth - 2
        for candidateSide in [side, side.opposite] {
            let direction: CGFloat = candidateSide == .left ? -1 : 1
            for multiplier: CGFloat in [1, 1.35, 1.75, 2.25] {
                let detourX = min(maximumX, max(minimumX, start.x + direction * baseOffset * multiplier))
                let candidate = TrafficGraphCurve(
                    start: start,
                    control1: CGPoint(x: detourX, y: start.y),
                    control2: CGPoint(x: detourX, y: end.y),
                    end: end
                )
                if !intersects(candidate, obstacles: padded) { return candidate }
            }
        }
        return nil
    }

    static func parallelCurve(
        start: CGPoint,
        end: CGPoint,
        fanout: CGFloat,
        routeOffset: CGFloat,
        avoiding obstacles: [CGRect],
        width: CGFloat,
        within bounds: CGRect
    ) -> TrafficGraphCurve? {
        let controlOffset = max(24, abs(end.x - start.x) * 0.42)
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        // Both cubic controls contribute 75% of their shared shift at t = 0.5. Compensate so the midpoint keeps the
        // full parallel-edge fanout while the endpoints remain attached to the cards.
        let controlFanout = fanout * 4 / 3
        let direct = TrafficGraphCurve(
            start: start,
            control1: CGPoint(x: start.x + controlOffset * direction, y: start.y + controlFanout),
            control2: CGPoint(x: end.x - controlOffset * direction, y: end.y + controlFanout),
            end: end
        )
        let clearance = 10 + max(0.5, width / 2)
        let padded = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        guard intersects(direct, obstacles: padded) else { return direct }

        let above = (padded.map(\.minY).min() ?? min(start.y, end.y)) - 16 + min(0, routeOffset)
        let below = (padded.map(\.maxY).max() ?? max(start.y, end.y)) + 16 + max(0, routeOffset)
        let preferAbove = routeOffset < 0 || (routeOffset == 0
            && abs(start.y - above) + abs(end.y - above) <= abs(start.y - below) + abs(end.y - below))
        return routedCurve(
            start: start,
            end: end,
            obstacles: padded,
            preferAbove: preferAbove,
            width: width,
            within: bounds
        )
    }

    private static func controlBounds(_ curve: TrafficGraphCurve) -> CGRect {
        let points = curve.segments.flatMap { [$0.start, $0.control1, $0.control2, $0.end] }
        let minimumX = points.map(\.x).min() ?? 0
        let maximumX = points.map(\.x).max() ?? 0
        let minimumY = points.map(\.y).min() ?? 0
        let maximumY = points.map(\.y).max() ?? 0
        return CGRect(x: minimumX, y: minimumY,
                      width: max(0.5, maximumX - minimumX), height: max(0.5, maximumY - minimumY))
    }

    private static func intersects(_ curve: TrafficGraphCurve, obstacles: [CGRect]) -> Bool {
        let bounds = controlBounds(curve)
        let relevant = obstacles.filter { bounds.intersects($0) }
        guard !relevant.isEmpty else { return false }

        // This runs for every routing candidate. Building a 161-point array and nested Zip2Sequence closures here
        // made one ordinary 18-edge map take tens of seconds in Debug builds and time out under Xcode 16. Walk the
        // same 160 line segments directly: collision precision and resulting geometry stay identical, while the hot
        // path allocates nothing and can return as soon as any relevant card is hit.
        let steps = 160 * curve.segments.count
        var previous = curve.start
        for step in 1...steps {
            let current = curve.point(at: CGFloat(step) / CGFloat(steps))
            let minimumX = min(previous.x, current.x)
            let maximumX = max(previous.x, current.x)
            let minimumY = min(previous.y, current.y)
            let maximumY = max(previous.y, current.y)
            for obstacle in relevant {
                // The curve-wide bounds above are intentionally conservative. Reject cards that cannot overlap this
                // individual segment before running the more expensive exact clipping test; boundary contact remains
                // inclusive, matching `segment(_:_:intersects:)`.
                guard maximumX >= obstacle.minX, minimumX <= obstacle.maxX,
                      maximumY >= obstacle.minY, minimumY <= obstacle.maxY else { continue }
                if segment(previous, current, intersects: obstacle) { return true }
            }
            previous = current
        }
        return false
    }

    private static func segment(_ start: CGPoint, _ end: CGPoint, intersects rect: CGRect) -> Bool {
        if rect.contains(start) || rect.contains(end) { return true }

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        return clip(direction: -deltaX, distance: start.x - rect.minX, lower: &lower, upper: &upper)
            && clip(direction: deltaX, distance: rect.maxX - start.x, lower: &lower, upper: &upper)
            && clip(direction: -deltaY, distance: start.y - rect.minY, lower: &lower, upper: &upper)
            && clip(direction: deltaY, distance: rect.maxY - start.y, lower: &lower, upper: &upper)
    }

    private static func clip(
        direction: CGFloat,
        distance: CGFloat,
        lower: inout CGFloat,
        upper: inout CGFloat
    ) -> Bool {
        if abs(direction) < 0.000_001 { return distance >= 0 }
        let ratio = distance / direction
        if direction < 0 {
            lower = max(lower, ratio)
        } else {
            upper = min(upper, ratio)
        }
        return lower <= upper
    }

    private static func corridorOverlap(
        _ candidate: TrafficGraphCurve,
        with routes: [TrafficGraphCurve]
    ) -> Int {
        let candidateBounds = controlBounds(candidate).insetBy(dx: -4, dy: -4)
        return routes.reduce(0) { largest, route in
            guard candidateBounds.intersects(controlBounds(route)) else { return largest }
            let closeSamples = (15..<85).reduce(0) { count, step in
                let progress = CGFloat(step) / 100
                let left = candidate.point(at: progress)
                let right = route.point(at: progress)
                return count + (hypot(left.x - right.x, left.y - right.y) < 4 ? 1 : 0)
            }
            return max(largest, closeSamples)
        }
    }

    private static func sharesCorridor(
        _ candidate: TrafficGraphCurve,
        with routes: [TrafficGraphCurve]
    ) -> Bool {
        corridorOverlap(candidate, with: routes) >= 8
    }

    static func sankeyCurve(
        start: CGPoint,
        end: CGPoint,
        avoiding obstacles: [CGRect] = [],
        width: CGFloat = 0,
        within bounds: CGRect,
        variation: Int = 0,
        avoidingRoutes: [TrafficGraphCurve] = []
    ) -> TrafficGraphCurve? {
        let controlOffset = max(24, abs(end.x - start.x) * 0.42)
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        let direct = TrafficGraphCurve(
            start: start,
            control1: CGPoint(x: start.x + controlOffset * direction, y: start.y),
            control2: CGPoint(x: end.x - controlOffset * direction, y: end.y),
            end: end
        )
        let denseSearch = obstacles.count > 160
        // Dense graphs search fewer candidates, but they never receive a smaller visual safety halo around cards.
        let clearance = routeClearance(width: width, obstacleCount: obstacles.count)
        let padded = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let directBounds = controlBounds(direct)
        let routingObstacles = denseSearch
            ? padded.filter { directBounds.intersects($0) }
            : padded
        let directIntersectsObstacle = intersects(direct, obstacles: padded)
        guard directIntersectsObstacle
                || sharesCorridor(direct, with: avoidingRoutes) else { return direct }

        let above = (padded.map(\.minY).min() ?? min(start.y, end.y)) - 16
        let below = (padded.map(\.maxY).max() ?? max(start.y, end.y)) + 16
        let preferAbove = abs(start.y - above) + abs(end.y - above)
            <= abs(start.y - below) + abs(end.y - below)
        if let routed = routedCurve(
            start: start,
            end: end,
            obstacles: padded,
            routingObstacles: routingObstacles,
            preferAbove: preferAbove,
            width: width,
            within: bounds,
            variation: variation,
            avoidingRoutes: avoidingRoutes
        ) {
            return routed
        }

        // Corridor separation is an aesthetic preference, so a card-clear direct route remains truthful when no
        // separated candidate exists. A route already proved to cross a card is never restored: List retains the exact
        // relationship while Map omits geometry that would falsely run through an unrelated node.
        return directIntersectsObstacle ? nil : direct
    }

    private static func routedCurve(
        start: CGPoint,
        end: CGPoint,
        obstacles: [CGRect],
        routingObstacles: [CGRect]? = nil,
        preferAbove: Bool,
        width: CGFloat,
        within bounds: CGRect,
        variation: Int = 0,
        avoidingRoutes: [TrafficGraphCurve] = []
    ) -> TrafficGraphCurve? {
        let halfWidth = max(0.5, width / 2)
        let minimumY = bounds.minY + halfWidth + 2
        let maximumY = bounds.maxY - halfWidth - 2
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        let span = abs(end.x - start.x)

        func curve(
            control1Fraction: CGFloat,
            control2Fraction: CGFloat,
            control1Y: CGFloat,
            control2Y: CGFloat
        ) -> TrafficGraphCurve {
            TrafficGraphCurve(
                start: start,
                control1: CGPoint(x: start.x + span * control1Fraction * direction, y: control1Y),
                control2: CGPoint(x: start.x + span * control2Fraction * direction, y: control2Y),
                end: end
            )
        }

        func clampedY(_ value: CGFloat) -> CGFloat {
            min(maximumY, max(minimumY, value))
        }

        let bandObstacles = routingObstacles ?? obstacles
        let upperBands = Set([minimumY] + bandObstacles.map { clampedY($0.minY - 4) })
        let lowerBands = Set([maximumY] + bandObstacles.map { clampedY($0.maxY + 4) })
        // Search the closest useful corridor first. Trying the outer canvas edge first created a technically valid
        // but visually foreign U-turn: a route plunged to a shared bottom baseline even when a nearer card edge
        // could clear the same obstacle. Side preference only breaks equal-distance ties.
        let rankedBands = Array(upperBands.union(lowerBands)).sorted { left, right in
            let leftDistance = abs(start.y - left) + abs(end.y - left)
            let rightDistance = abs(start.y - right) + abs(end.y - right)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            let leftPreferred = preferAbove ? upperBands.contains(left) : lowerBands.contains(left)
            let rightPreferred = preferAbove ? upperBands.contains(right) : lowerBands.contains(right)
            if leftPreferred != rightPreferred { return leftPreferred }
            return left < right
        }
        let denseSearch = obstacles.count > 160
        let ordered = boundedRouteBands(rankedBands, obstacleCount: obstacles.count)
        let controlProfiles: [(CGFloat, CGFloat)] = [
            (0.42, 0.58),
            (0.30, 0.45),
            (0.55, 0.70),
            (0.08, 0.28),
            (0.72, 0.92),
            (0.08, 0.55),
            (0.45, 0.92),
            (0.12, 0.88),
            (0.42, 0.49),
            (0.02, 0.98)
        ]
        let smoothProfiles = Array(controlProfiles.prefix(3))
        let profileShift = max(0, variation) % smoothProfiles.count
        let orderedSmoothProfiles = Array(smoothProfiles.dropFirst(profileShift))
            + Array(smoothProfiles.prefix(profileShift))
        let orderedProfiles = denseSearch
            ? Array(orderedSmoothProfiles.prefix(1))
            : orderedSmoothProfiles + Array(controlProfiles.dropFirst(3))
        let controlFactors: [CGFloat] = denseSearch ? [1, 2.6] : [1, CGFloat(4.0 / 3.0), 2, 2.6, 3.2]
        func staysInsideCanvas(_ candidate: TrafficGraphCurve) -> Bool {
            let steps = 64 * candidate.segments.count
            return (0...steps).allSatisfy { step in
                let point = candidate.point(at: CGFloat(step) / CGFloat(steps))
                return point.y >= minimumY && point.y <= maximumY
            }
        }
        var obstacleClearFallback: TrafficGraphCurve?
        var fallbackOverlap = Int.max
        var obstacleClearShelfFallback: TrafficGraphCurve?
        var shelfFallbackOverlap = Int.max

        func shouldReturn(_ candidate: TrafficGraphCurve) -> Bool {
            let overlap = corridorOverlap(candidate, with: avoidingRoutes)
            if candidate.hasLongHorizontalShelf()
                || candidate.hasLongVerticalShelf()
                || candidate.hasPinchedVerticalTurn() {
                if overlap < shelfFallbackOverlap {
                    obstacleClearShelfFallback = candidate
                    shelfFallbackOverlap = overlap
                }
                return false
            }
            if overlap < fallbackOverlap {
                obstacleClearFallback = candidate
                fallbackOverlap = overlap
            }
            return overlap < 8
        }

        func smoothFallbackCurve(
            routeY: CGFloat,
            sourceFraction: CGFloat,
            targetFraction: CGFloat
        ) -> TrafficGraphCurve? {
            let sourceObstacleX = obstacles.compactMap { obstacle -> CGFloat? in
                if direction > 0, obstacle.minX > start.x + 1 { return obstacle.minX }
                if direction < 0, obstacle.maxX < start.x - 1 { return obstacle.maxX }
                return nil
            }.min { abs($0 - start.x) < abs($1 - start.x) } ?? end.x
            let targetObstacleX = obstacles.compactMap { obstacle -> CGFloat? in
                if direction > 0, obstacle.maxX < end.x - 1 { return obstacle.maxX }
                if direction < 0, obstacle.minX > end.x + 1 { return obstacle.minX }
                return nil
            }.min { abs($0 - end.x) < abs($1 - end.x) } ?? start.x
            let sourceColumnBoundary = obstacles.compactMap { obstacle -> CGFloat? in
                guard obstacle.minX < start.x, obstacle.maxX > start.x else { return nil }
                return direction > 0 ? obstacle.maxX : obstacle.minX
            }.min { abs($0 - start.x) < abs($1 - start.x) }
            let targetColumnBoundary = obstacles.compactMap { obstacle -> CGFloat? in
                guard obstacle.minX < end.x, obstacle.maxX > end.x else { return nil }
                return direction > 0 ? obstacle.minX : obstacle.maxX
            }.min { abs($0 - end.x) < abs($1 - end.x) }
            let rawSourceClearX = (sourceColumnBoundary ?? start.x) + direction * 2
            let rawTargetClearX = (targetColumnBoundary ?? end.x) - direction * 2
            let sourceClearX = direction > 0
                ? min(sourceObstacleX - 2, max(start.x, rawSourceClearX))
                : max(sourceObstacleX + 2, min(start.x, rawSourceClearX))
            let targetClearX = direction > 0
                ? max(targetObstacleX + 2, min(end.x, rawTargetClearX))
                : min(targetObstacleX - 2, max(end.x, rawTargetClearX))
            let sourceExitX = sourceClearX + (sourceObstacleX - sourceClearX) * sourceFraction
            let targetEntryX = targetClearX + (targetObstacleX - targetClearX) * targetFraction
            guard (sourceExitX - sourceClearX) * direction > 1,
                  (targetClearX - targetEntryX) * direction > 1,
                  (targetEntryX - sourceExitX) * direction > 4 else { return nil }

            func horizontalSegment(from first: CGPoint, to second: CGPoint) -> TrafficGraphCurveSegment {
                let delta = second.x - first.x
                return TrafficGraphCurveSegment(
                    start: first,
                    control1: CGPoint(x: first.x + delta / 3, y: first.y),
                    control2: CGPoint(x: first.x + delta * 2 / 3, y: second.y),
                    end: second
                )
            }

            let sourceClear = CGPoint(x: sourceClearX, y: start.y)
            let targetClear = CGPoint(x: targetClearX, y: end.y)
            let sourceBlend: CGFloat = variation.isMultiple(of: 2) ? 0.90 : 0.96
            let targetBlend: CGFloat = variation.isMultiple(of: 2) ? 0.96 : 0.90
            let sourceExit = CGPoint(
                x: sourceExitX,
                y: start.y + (routeY - start.y) * sourceBlend
            )
            let targetEntry = CGPoint(
                x: targetEntryX,
                y: end.y + (routeY - end.y) * targetBlend
            )
            let sourceTurnDelta = sourceExitX - sourceClearX
            let middleDelta = targetEntryX - sourceExitX
            let targetTurnDelta = targetClearX - targetEntryX

            // Bow the long middle leg farther away from the cards instead of holding one flat routing band. Align the
            // adjacent handles with that arch so all joins retain one tangent and read as one continuous movement.
            let routesAbove = routeY <= min(start.y, end.y)
            let archDirection: CGFloat = routesAbove ? -1 : 1
            let availableArch = routesAbove ? routeY - minimumY : maximumY - routeY
            let requestedArch = max(24, min(64, abs(middleDelta) * 0.10))
            let archY = routeY + archDirection * min(requestedArch, max(0, availableArch - 2))
            let middleControl1 = CGPoint(
                x: sourceExitX + middleDelta / 3,
                y: archY
            )
            let middleControl2 = CGPoint(
                x: sourceExitX + middleDelta * 2 / 3,
                y: archY
            )
            let sourceJoinScale = min(
                0.35,
                abs(sourceTurnDelta) * 0.45 / max(1, abs(middleControl1.x - sourceExit.x))
            )
            let targetJoinScale = min(
                0.35,
                abs(targetTurnDelta) * 0.45 / max(1, abs(targetEntry.x - middleControl2.x))
            )
            let sourceTurnControl2 = CGPoint(
                x: sourceExit.x - (middleControl1.x - sourceExit.x) * sourceJoinScale,
                y: sourceExit.y - (middleControl1.y - sourceExit.y) * sourceJoinScale
            )
            let targetTurnControl1 = CGPoint(
                x: targetEntry.x + (targetEntry.x - middleControl2.x) * targetJoinScale,
                y: targetEntry.y + (targetEntry.y - middleControl2.y) * targetJoinScale
            )
            let candidateSegments = [
                horizontalSegment(from: start, to: sourceClear),
                TrafficGraphCurveSegment(
                    start: sourceClear,
                    control1: CGPoint(x: sourceClearX + sourceTurnDelta * 0.35, y: start.y),
                    control2: sourceTurnControl2,
                    end: sourceExit
                ),
                TrafficGraphCurveSegment(
                    start: sourceExit,
                    control1: middleControl1,
                    control2: middleControl2,
                    end: targetEntry
                ),
                TrafficGraphCurveSegment(
                    start: targetEntry,
                    control1: targetTurnControl1,
                    control2: CGPoint(x: targetEntryX + targetTurnDelta * 0.65, y: end.y),
                    end: targetClear
                ),
                horizontalSegment(from: targetClear, to: end)
            ].filter { segment in
                hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y) > 0.001
            }
            guard !candidateSegments.isEmpty else { return nil }
            let candidate = TrafficGraphCurve(segments: candidateSegments)
            return candidate.hasContinuousTangents() ? candidate : nil
        }

        var primaryCandidatesTried = 0
        primarySearch: for routeY in ordered {
            if Task<Never, Never>.isCancelled { return nil }
            for profile in orderedProfiles {
                if Task<Never, Never>.isCancelled { return nil }
                // A cubic reaches only partway toward its controls. Extrapolate the controls beyond the desired
                // corridor so the rendered curve itself can make one restrained arc around a full card column.
                var candidates: [TrafficGraphCurve] = []
                if denseSearch {
                    for factor in controlFactors {
                        let firstY = start.y + (routeY - start.y) * factor
                        let secondY = end.y + (routeY - end.y) * factor
                        candidates.append(curve(
                            control1Fraction: profile.0,
                            control2Fraction: profile.1,
                            control1Y: firstY,
                            control2Y: secondY
                        ))
                        candidates.append(curve(
                            control1Fraction: profile.0,
                            control2Fraction: profile.1,
                            control1Y: firstY,
                            control2Y: end.y
                        ))
                        candidates.append(curve(
                            control1Fraction: profile.0,
                            control2Fraction: profile.1,
                            control1Y: start.y,
                            control2Y: secondY
                        ))
                    }
                } else {
                    for firstFactor in controlFactors {
                        let firstY = start.y + (routeY - start.y) * firstFactor
                        candidates.append(curve(
                            control1Fraction: profile.0,
                            control2Fraction: profile.1,
                            control1Y: firstY,
                            control2Y: end.y
                        ))
                        for secondFactor in controlFactors {
                            candidates.append(curve(
                                control1Fraction: profile.0,
                                control2Fraction: profile.1,
                                control1Y: firstY,
                                control2Y: end.y + (routeY - end.y) * secondFactor
                            ))
                        }
                    }
                    for secondFactor in controlFactors {
                        candidates.append(curve(
                            control1Fraction: profile.0,
                            control2Fraction: profile.1,
                            control1Y: start.y,
                            control2Y: end.y + (routeY - end.y) * secondFactor
                        ))
                    }
                }
                for candidate in candidates {
                    if Task<Never, Never>.isCancelled { return nil }
                    guard primaryCandidatesTried < maximumPrimaryRouteCandidates else {
                        break primarySearch
                    }
                    primaryCandidatesTried += 1
                    guard staysInsideCanvas(candidate),
                          !intersects(candidate, obstacles: obstacles) else { continue }
                    if shouldReturn(candidate) { return candidate }
                }
            }
        }
        if !denseSearch {
            // Keep this smooth escape hatch bounded while retaining enough distinct bands to separate parallel
            // routes. Sixteen bands and four waypoint pairs cap the fallback at 64 deterministic candidates.
            let outerBands = preferAbove ? [minimumY, maximumY] : [maximumY, minimumY]
            let fallbackBands = (outerBands + rankedBands).reduce(into: [CGFloat]()) { result, band in
                guard result.count < 16, !result.contains(band) else { return }
                result.append(band)
            }
            let gapFractionPairs: [(CGFloat, CGFloat)] = [
                (0.55, 0.9),
                (0.9, 0.55),
                (0.9, 1.5),
                (1.5, 0.9)
            ]
            for routeY in fallbackBands {
                if Task<Never, Never>.isCancelled { return nil }
                for (sourceFraction, targetFraction) in gapFractionPairs {
                    guard let candidate = smoothFallbackCurve(
                        routeY: routeY,
                        sourceFraction: sourceFraction,
                        targetFraction: targetFraction
                    ), staysInsideCanvas(candidate),
                    !intersects(candidate, obstacles: obstacles) else { continue }
                    if shouldReturn(candidate) { return candidate }
                }
            }
        }
        // A shelf is the last card-clear escape hatch only. Corridor overlap must not reintroduce the rounded
        // rectangle geometry this router is specifically required to remove whenever any smooth route exists.
        return obstacleClearFallback ?? obstacleClearShelfFallback
    }

    private static func orderedNodes(snapshot: TrafficGraphSnapshot,
                                     nodeLanes: [TrafficGraphNodeID: Lane]) -> [Lane: [TrafficGraphNode]] {
        var lanes = Dictionary(grouping: snapshot.nodes) { nodeLanes[$0.id] ?? .source }
        for lane in Lane.allCases { lanes[lane] = (lanes[lane] ?? []).sorted { $0.id < $1.id } }
        let neighbors = Dictionary(grouping: snapshot.edges.flatMap { edge in
            [(edge.source, edge.target), (edge.target, edge.source)]
        }, by: \.0)

        func normalizedPositions(_ current: [Lane: [TrafficGraphNode]]) -> [TrafficGraphNodeID: CGFloat] {
            Dictionary(uniqueKeysWithValues: current.values.flatMap { nodes in
                nodes.enumerated().map { index, node in
                    let denominator = CGFloat(max(1, nodes.count - 1))
                    return (node.id, CGFloat(index) / denominator)
                }
            })
        }

        func reorder(_ lane: Lane) {
            guard var nodes = lanes[lane], nodes.count > 1 else { return }
            let positions = normalizedPositions(lanes)
            nodes.sort { left, right in
                let leftScore = median((neighbors[left.id] ?? []).compactMap { positions[$0.1] })
                let rightScore = median((neighbors[right.id] ?? []).compactMap { positions[$0.1] })
                if leftScore == rightScore { return left.id < right.id }
                return leftScore < rightScore
            }
            lanes[lane] = nodes
        }

        for _ in 0..<6 {
            if Task<Never, Never>.isCancelled { return lanes }
            for lane in Lane.allCases { reorder(lane) }
            for lane in Lane.allCases.reversed() { reorder(lane) }
        }
        return lanes
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    private static func lanes(snapshot: TrafficGraphSnapshot) -> [TrafficGraphNodeID: Lane] {
        let gatewayTargets = Set(snapshot.edges.filter { $0.relationship == .configuredGateway }.map(\.target))
        let inspectionTargets = Set(snapshot.edges.filter { $0.relationship == .routedThrough }.map(\.target))
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let upstreamLauncherIDs = Set(snapshot.edges.compactMap { edge -> TrafficGraphNodeID? in
            guard edge.relationship == .launched,
                  nodesByID[edge.target]?.kind == .launcher else { return nil }
            return edge.source
        })
        return Dictionary(uniqueKeysWithValues: snapshot.nodes.map { node in
            let lane: Lane
            switch node.kind {
            case .launcher:
                lane = upstreamLauncherIDs.contains(node.id) ? .upstreamLauncher : .launcher
            case .app, .agent: lane = .source
            case .tool, .mcp: lane = .tool
            case .proxy:
                lane = inspectionTargets.contains(node.id) ? .inspectionProxy
                    : gatewayTargets.contains(node.id) ? .gateway : .inspectionProxy
            case .destination, .service: lane = .destination
            }
            return (node.id, lane)
        })
    }

    private static func size(for lane: Lane) -> CGSize {
        switch lane {
        case .upstreamLauncher, .launcher, .source: return appSize
        case .tool, .gateway, .inspectionProxy: return intermediarySize
        case .destination: return destinationSize
        }
    }

    static func columnGaps(for snapshot: TrafficGraphSnapshot) -> [CGFloat] {
        guard !snapshot.nodes.isEmpty else { return [] }
        let nodeLanes = lanes(snapshot: snapshot)
        let activeLanes = Lane.allCases.filter { lane in
            snapshot.nodes.contains { nodeLanes[$0.id] == lane }
        }
        guard activeLanes.count > 1 else { return [] }
        let laneIndexes = Dictionary(uniqueKeysWithValues: activeLanes.enumerated().map { ($0.element, $0.offset) })
        var widenedGapIndexes: Set<Int> = []
        for edge in snapshot.edges {
            guard let sourceLane = nodeLanes[edge.source],
                  let targetLane = nodeLanes[edge.target],
                  let sourceIndex = laneIndexes[sourceLane],
                  let targetIndex = laneIndexes[targetLane] else { continue }
            let lower = min(sourceIndex, targetIndex)
            let upper = max(sourceIndex, targetIndex)
            guard upper - lower > 1 else { continue }
            // A skipped stage needs runway across its own semantic corridor. Widening every graph gap made one long
            // edge shrink unrelated columns under automatic Fit, while widening only the corridor endpoints pinched
            // longer routes back into shelf-shaped fallbacks between the intermediate stages.
            widenedGapIndexes.formUnion(lower..<upper)
        }
        let density = CGFloat(snapshot.edges.count) / CGFloat(snapshot.nodes.count)
        let densityBonus = min(24, density * 4)
        return (0..<(activeLanes.count - 1)).map { index in
            (widenedGapIndexes.contains(index) ? CGFloat(168) : 80) + densityBonus
        }
    }

    private static func nodeGap(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        guard !snapshot.nodes.isEmpty else { return baseNodeGap }
        let density = CGFloat(snapshot.edges.count) / CGFloat(snapshot.nodes.count)
        return baseNodeGap + min(18, density * 3)
    }

    private static func columnPositions(
        for lanes: [Lane],
        in bounds: CGRect,
        minimumGaps: [CGFloat]
    ) -> [Lane: CGFloat] {
        guard let first = lanes.first else { return [:] }
        if lanes.count == 1 { return [first: bounds.midX] }
        var minimum: [CGFloat] = [bounds.minX + size(for: first).width / 2]
        for (index, pair) in zip(lanes, lanes.dropFirst()).enumerated() {
            let (left, right) = pair
            let gap = minimumGaps.indices.contains(index) ? minimumGaps[index] : 80
            minimum.append(minimum.last! + size(for: left).width / 2
                           + gap + size(for: right).width / 2)
        }
        let last = lanes[lanes.count - 1]
        let availableRight = bounds.maxX - size(for: last).width / 2
        let extra = max(0, availableRight - minimum.last!)
        return Dictionary(uniqueKeysWithValues: lanes.enumerated().map { index, lane in
            let fraction = CGFloat(index) / CGFloat(lanes.count - 1)
            return (lane, minimum[index] + extra * fraction)
        })
    }

    private static func placeMissingNodes(
        ordered: [Lane: [TrafficGraphNode]],
        activeLanes: [Lane],
        columns: [Lane: CGFloat],
        insetBounds: CGRect,
        gap: CGFloat,
        frames: inout [TrafficGraphNodeID: CGRect],
        placementObserver: (@Sendable () -> Void)?
    ) -> Bool {
        // Keep one ordered collision list for the whole placement pass. Rebuilding Array(frames.values) for every
        // node turns a large graph into hundreds of successively larger allocations even though only one frame was
        // added since the previous iteration.
        var placedFrames = Array(frames.values)
        for lane in activeLanes {
            if Task<Never, Never>.isCancelled { return false }
            let nodes = ordered[lane] ?? []
            guard let column = columns[lane] else { continue }
            let size = size(for: lane)
            let availableHeight = insetBounds.height
            let stackHeight = CGFloat(nodes.count) * size.height
                + CGFloat(max(0, nodes.count - 1)) * gap
            let startY = insetBounds.midY - min(stackHeight, availableHeight) / 2
            let step = nodes.count > 1 && stackHeight > availableHeight
                ? max(1, (availableHeight - size.height) / CGFloat(nodes.count - 1))
                : size.height + gap

            for (index, node) in nodes.enumerated() where frames[node.id] == nil {
                if Task<Never, Never>.isCancelled { return false }
                let preferredY = startY + size.height / 2 + CGFloat(index) * step
                let preferred = CGPoint(x: column, y: preferredY)
                let frame = place(
                    size: size,
                    near: preferred,
                    laneX: column,
                    within: insetBounds,
                    avoiding: placedFrames,
                    gap: gap
                )
                frames[node.id] = frame
                placedFrames.append(frame)
                placementObserver?()
            }
        }
        return true
    }

    private static func hasOverlaps<S: Sequence>(
        _ frames: S,
        gap: CGFloat
    ) -> Bool where S.Element == CGRect {
        let frames = Array(frames)
        for left in frames.indices {
            if Task<Never, Never>.isCancelled { return false }
            for right in frames.indices where right > left {
                if Task<Never, Never>.isCancelled { return false }
                if frames[left].insetBy(dx: -gap / 2, dy: -gap / 2)
                    .intersects(frames[right]) {
                    return true
                }
            }
        }
        return false
    }

    private static func place(
        size: CGSize,
        near preferred: CGPoint,
        laneX: CGFloat,
        within bounds: CGRect,
        avoiding placed: [CGRect],
        gap: CGFloat
    ) -> CGRect {
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
            for existing in placed {
                if Task<Never, Never>.isCancelled { return false }
                if existing.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(candidate) { return false }
            }
            return true
        }

        let initial = clamped(frame(y: preferred.y))
        if clear(initial) { return initial }
        for distance in stride(from: gap + size.height, through: bounds.height, by: gap + size.height) {
            if Task<Never, Never>.isCancelled { return initial }
            for direction: CGFloat in [-1, 1] {
                let candidate = clamped(frame(y: preferred.y + distance * direction))
                if clear(candidate) { return candidate }
            }
        }
        return initial
    }

}
