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
            && Set(snapshot.edges.map(\.id)) == Set(previous.edgeCurves.keys)
    }
}

struct TrafficGraphCurve: Equatable, Sendable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    var points: [CGPoint] {
        (0...24).map { point(at: CGFloat($0) / 24) }
    }

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

    /// Offsets a ribbon boundary while keeping its node ports flush with card edges.
    func offset(by distance: CGFloat) -> TrafficGraphCurve {
        let shift = CGPoint(x: 0, y: distance)
        return TrafficGraphCurve(
            start: CGPoint(x: start.x + shift.x, y: start.y + shift.y),
            control1: CGPoint(x: control1.x + shift.x, y: control1.y + shift.y),
            control2: CGPoint(x: control2.x + shift.x, y: control2.y + shift.y),
            end: CGPoint(x: end.x + shift.x, y: end.y + shift.y)
        )
    }

    func hitTestSteps(maximumSegmentLength: CGFloat) -> Int {
        let controlPolygon = start.distance(to: control1) + control1.distance(to: control2)
            + control2.distance(to: end)
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
    static let pattern: [CGFloat] = [8, 26]
    static let strokeWidth: CGFloat = 1.8
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

    static func borderOffset(totalWidth: CGFloat, direction: TrafficGraphFlowDirection) -> CGFloat {
        let width = max(0, totalWidth)
        let inset = min(strokeWidth / 2, width / 2)
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

struct TrafficGraphVisibleRegion: Equatable, Sendable {
    var nodeIDs: Set<TrafficGraphNodeID>
    var edgeIDs: Set<TrafficGraphEdgeID>
}

struct TrafficGraphLayoutSnapshot: Sendable {
    var nodeFrames: [TrafficGraphNodeID: CGRect]
    var edgeCurves: [TrafficGraphEdgeID: TrafficGraphCurve]
    var edgeWidths: [TrafficGraphEdgeID: CGFloat] = [:]
    var edgeWidthCaps: [TrafficGraphEdgeID: CGFloat] = [:]
    var edgeBounds: [TrafficGraphEdgeID: CGRect] = [:]

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
    private static let maximumRibbonWidth: CGFloat = 24

    static func minimumCanvasWidth(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        let nodeLanes = lanes(snapshot: snapshot)
        let activeLanes = Lane.allCases.filter { lane in
            snapshot.nodes.contains { nodeLanes[$0.id] == lane }
        }
        let cards = activeLanes.reduce(CGFloat(0)) { $0 + size(for: $1).width }
        let gaps = CGFloat(max(0, activeLanes.count - 1)) * columnGap(for: snapshot)
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
            minimumGap: columnGap(for: snapshot)
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
            widths[edge.id] = 1.5
            portWidths[edge.id] = 1.5
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
            let width = portWidths[edge.id] ?? 1.5
            let fanoutOffset = parallelOffsets[edge.id] ?? 0
            let obstacles = unrelatedObstacles(
                for: edge,
                from: frames,
                between: start,
                and: end
            )
            let direct: TrafficGraphCurve
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
            curves[edge.id] = direct
        }
        var widthCaps = capacityWidths
        for edge in snapshot.edges where !edge.isTrafficRibbon { widthCaps[edge.id] = 1.5 }
        let boundsByEdge = edgeBounds(curves: curves, widths: widthCaps)
        return TrafficGraphLayoutSnapshot(
            nodeFrames: frames,
            edgeCurves: curves,
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

    static func trafficWidths(
        for snapshot: TrafficGraphSnapshot,
        caps: [TrafficGraphEdgeID: CGFloat]
    ) -> [TrafficGraphEdgeID: CGFloat] {
        let ribbons = snapshot.edges.filter(\.isTrafficRibbon)
        let maximum = max(1, ribbons.map { $0.displayedCounters.total }.max() ?? 1)
        return Dictionary(uniqueKeysWithValues: snapshot.edges.map { edge in
            guard edge.isTrafficRibbon else { return (edge.id, 1.5) }
            let width = ribbonWidth(bytes: edge.displayedCounters.total, maximum: maximum)
            let scale = min(1, (caps[edge.id] ?? maximumRibbonWidth) / maximumRibbonWidth)
            return (edge.id, width * scale)
        })
    }

    private static func ribbonCapacities(
        edges: [TrafficGraphEdge],
        assignments: [PortKey: [PortAssignment]],
        frames: [TrafficGraphNodeID: CGRect]
    ) -> [TrafficGraphEdgeID: CGFloat] {
        let scale = assignments.reduce(CGFloat(1)) { current, entry in
            guard let height = frames[entry.key.node]?.height else { return current }
            let ribbons = entry.value.filter { $0.edge.isTrafficRibbon }
            guard !ribbons.isEmpty else { return current }
            let fixedWidth = entry.value.reduce(CGFloat(0)) {
                $0 + ($1.edge.isTrafficRibbon ? 0 : 1.5)
            }
            let gaps = CGFloat(max(0, entry.value.count - 1)) * 2
            let available = max(1, height - 12 - fixedWidth - gaps)
            let maximumTotal = CGFloat(ribbons.count) * maximumRibbonWidth
            return min(current, available / maximumTotal)
        }
        let capacity = maximumRibbonWidth * min(1, scale)
        return Dictionary(uniqueKeysWithValues: edges.map { ($0.id, capacity) })
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
        return frames.compactMap { id, frame -> CGRect? in
            guard id != edge.source, id != edge.target else { return nil }
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
    ) -> TrafficGraphCurve {
        let halfWidth = max(0.5, width / 2)
        let clearance = 10 + halfWidth
        let padded = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let baseOffset = max(36 + halfWidth, min(180, abs(end.y - start.y) * 0.35))
        let minimumX = bounds.minX + halfWidth + 2
        let maximumX = bounds.maxX - halfWidth - 2
        var fallback: TrafficGraphCurve?
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
                if fallback == nil { fallback = candidate }
                if !intersects(candidate, obstacles: padded) { return candidate }
            }
        }
        return fallback ?? TrafficGraphCurve(start: start, control1: start, control2: end, end: end)
    }

    private static func parallelCurve(
        start: CGPoint,
        end: CGPoint,
        fanout: CGFloat,
        routeOffset: CGFloat,
        avoiding obstacles: [CGRect],
        width: CGFloat,
        within bounds: CGRect
    ) -> TrafficGraphCurve {
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
        ) ?? direct
    }

    private static func controlBounds(_ curve: TrafficGraphCurve) -> CGRect {
        let points = [curve.start, curve.control1, curve.control2, curve.end]
        let minimumX = points.map(\.x).min() ?? 0
        let maximumX = points.map(\.x).max() ?? 0
        let minimumY = points.map(\.y).min() ?? 0
        let maximumY = points.map(\.y).max() ?? 0
        return CGRect(x: minimumX, y: minimumY,
                      width: max(0.5, maximumX - minimumX), height: max(0.5, maximumY - minimumY))
    }

    private static func intersects(_ curve: TrafficGraphCurve, obstacles: [CGRect]) -> Bool {
        func segment(_ start: CGPoint, _ end: CGPoint, intersects rect: CGRect) -> Bool {
            if rect.contains(start) || rect.contains(end) { return true }

            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            var lower: CGFloat = 0
            var upper: CGFloat = 1
            func clip(direction: CGFloat, distance: CGFloat) -> Bool {
                if abs(direction) < 0.000_001 { return distance >= 0 }
                let ratio = distance / direction
                if direction < 0 {
                    lower = max(lower, ratio)
                } else {
                    upper = min(upper, ratio)
                }
                return lower <= upper
            }
            return clip(direction: -deltaX, distance: start.x - rect.minX)
                && clip(direction: deltaX, distance: rect.maxX - start.x)
                && clip(direction: -deltaY, distance: start.y - rect.minY)
                && clip(direction: deltaY, distance: rect.maxY - start.y)
        }

        let bounds = controlBounds(curve)
        let relevant = obstacles.filter { bounds.intersects($0) }
        guard !relevant.isEmpty else { return false }
        let points = (0...160).map { curve.point(at: CGFloat($0) / 160) }
        return relevant.contains { obstacle in
            zip(points, points.dropFirst()).contains { start, end in
                segment(start, end, intersects: obstacle)
            }
        }
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

    private static func sankeyCurve(
        start: CGPoint,
        end: CGPoint,
        avoiding obstacles: [CGRect] = [],
        width: CGFloat = 0,
        within bounds: CGRect,
        variation: Int = 0,
        avoidingRoutes: [TrafficGraphCurve] = []
    ) -> TrafficGraphCurve {
        let controlOffset = max(24, abs(end.x - start.x) * 0.42)
        let direction: CGFloat = end.x >= start.x ? 1 : -1
        let direct = TrafficGraphCurve(
            start: start,
            control1: CGPoint(x: start.x + controlOffset * direction, y: start.y),
            control2: CGPoint(x: end.x - controlOffset * direction, y: end.y),
            end: end
        )
        let clearance = 10 + max(0.5, width / 2)
        let padded = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let directBounds = controlBounds(direct)
        let routingObstacles = padded.count > 160
            ? padded.filter { directBounds.intersects($0) }
            : padded
        guard intersects(direct, obstacles: padded)
                || sharesCorridor(direct, with: avoidingRoutes) else { return direct }

        let above = (padded.map(\.minY).min() ?? min(start.y, end.y)) - 16
        let below = (padded.map(\.maxY).max() ?? max(start.y, end.y)) + 16
        let preferAbove = abs(start.y - above) + abs(end.y - above)
            <= abs(start.y - below) + abs(end.y - below)
        return routedCurve(
            start: start,
            end: end,
            obstacles: padded,
            routingObstacles: routingObstacles,
            preferAbove: preferAbove,
            width: width,
            within: bounds,
            variation: variation,
            avoidingRoutes: avoidingRoutes
        ) ?? direct
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
        let ordered = denseSearch ? Array(rankedBands.prefix(4)) : rankedBands
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
            (0...64).allSatisfy { step in
                let point = candidate.point(at: CGFloat(step) / 64)
                return point.y >= minimumY && point.y <= maximumY
            }
        }
        var obstacleClearFallback: TrafficGraphCurve?
        var fallbackOverlap = Int.max
        for routeY in ordered {
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
                    guard staysInsideCanvas(candidate),
                          !intersects(candidate, obstacles: obstacles) else { continue }
                    let overlap = corridorOverlap(candidate, with: avoidingRoutes)
                    if overlap < fallbackOverlap {
                        obstacleClearFallback = candidate
                        fallbackOverlap = overlap
                    }
                    if overlap < 8 { return candidate }
                }
            }
        }
        return obstacleClearFallback
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

    private static func columnGap(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        guard !snapshot.nodes.isEmpty else { return 18 }
        let density = CGFloat(snapshot.edges.count) / CGFloat(snapshot.nodes.count)
        return 18 + min(30, density * 6)
    }

    private static func nodeGap(for snapshot: TrafficGraphSnapshot) -> CGFloat {
        guard !snapshot.nodes.isEmpty else { return baseNodeGap }
        let density = CGFloat(snapshot.edges.count) / CGFloat(snapshot.nodes.count)
        return baseNodeGap + min(18, density * 3)
    }

    private static func columnPositions(
        for lanes: [Lane],
        in bounds: CGRect,
        minimumGap: CGFloat
    ) -> [Lane: CGFloat] {
        guard let first = lanes.first else { return [:] }
        if lanes.count == 1 { return [first: bounds.midX] }
        var minimum: [CGFloat] = [bounds.minX + size(for: first).width / 2]
        for (left, right) in zip(lanes, lanes.dropFirst()) {
            minimum.append(minimum.last! + size(for: left).width / 2
                           + minimumGap + size(for: right).width / 2)
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
                frames[node.id] = place(
                    size: size,
                    near: preferred,
                    laneX: column,
                    within: insetBounds,
                    avoiding: Array(frames.values),
                    gap: gap
                )
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
