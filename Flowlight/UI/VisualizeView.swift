import SwiftUI

@MainActor
enum VisualizeActionScope {
    static func canInspect(_ filter: TrafficFilter) -> Bool {
        guard let domain = filter.domain else { return false }
        return HostCanonicalizer.host(domain) != nil && HostCanonicalizer.address(domain) == nil
    }

    static func canBlock(_ filter: TrafficFilter) -> Bool {
        exactDestination(filter) != nil
    }

    static func showInspect(_ nav: AppNavigation, filter: TrafficFilter, sourceTitle: String? = nil) {
        guard canInspect(filter), let host = filter.domain else { return }
        let app = filter.bundleID.flatMap { $0.isEmpty ? nil : ($0, sourceTitle ?? $0) }
        nav.showInspect(app: app, host: host, hostIncludesSubdomains: false,
                        includeAttributedChildren: filter.includeAttributedChildren,
                        agentParent: filter.agentParent, mcpServer: filter.mcpServer)
    }

    static func blockRule(for filter: TrafficFilter) -> Rule? {
        guard let destination = exactDestination(filter) else { return nil }
        var rule = RuleStore.block(app: filter.agentParent ?? filter.bundleID ?? "", destination: destination)
        rule.destinationMatch = .exact
        return rule
    }

    private static func exactDestination(_ filter: TrafficFilter) -> String? {
        if let domain = filter.domain,
           let canonical = HostCanonicalizer.host(domain) {
            return canonical
        }
        if let remoteIP = filter.remoteIP,
           let canonical = HostCanonicalizer.address(remoteIP) {
            return canonical
        }
        return nil
    }
}

struct VisualizeView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case traffic, ai
        var id: String { rawValue }
        var title: String { self == .traffic ? L("Traffic") : L("AI activity") }
        var icon: String { self == .traffic ? "network" : "sparkles" }
    }

    enum Presentation: String, CaseIterable, Identifiable {
        case map, list
        var id: String { rawValue }
        var title: String { self == .map ? L("Map") : L("List") }
        var icon: String { self == .map ? "point.3.connected.trianglepath.dotted" : "list.bullet" }
    }

    @EnvironmentObject private var monitor: TrafficMonitor
    @EnvironmentObject private var nav: AppNavigation
    @EnvironmentObject private var focus: FocusStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualize.mode") private var mode: Mode = .traffic
    @AppStorage("visualize.granularity") private var granularity: Granularity = .minute
    @AppStorage("visualize.presentation") private var presentation: Presentation = .map
    @State private var rows: [BreakdownRow] = []
    @State private var snapshot = TrafficGraphSnapshot.empty
    @State private var selectedNode: TrafficGraphNodeID?
    @State private var selectedEdge: TrafficGraphEdgeID?
    @State private var query = ""
    @State private var loading = false
    @State private var loadID = UUID()

    private var endDate: Date { Date() }
    private var startDate: Date { endDate.addingTimeInterval(-granularity.defaultWindow) }
    private var selection: GraphSelection? {
        if let selectedEdge, let edge = snapshot.edges.first(where: { $0.id == selectedEdge }) {
            return .edge(edge, source: node(edge.source), target: node(edge.target))
        }
        if let selectedNode, let node = node(selectedNode) { return .node(node) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if snapshot.edges.isEmpty, !loading {
                emptyState
            } else if presentation == .map {
                graphAndInspector
            } else {
                listAndInspector
            }
        }
        .background(FL.ground)
        .navigationTitle(L("Visualize"))
        .searchable(text: $query, placement: .toolbar, prompt: L("App, domain, or IP"))
        .task(id: LoadKey(mode: mode, granularity: granularity, focus: focus.scope, version: monitor.dataVersion)) { await reload() }
        .task(id: granularity) {
            guard granularity == .second else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { await reload() }
            }
        }
        .task(id: RebuildKey(loadID: loadID, query: query, mode: mode)) { await rebuild() }
        .onChange(of: mode) { _, _ in
            rows = []
            snapshot = .empty
            selectedNode = nil
            selectedEdge = nil
            loadID = UUID()
        }
        .onChange(of: snapshot.edges.map(\.id)) { _, ids in
            if let selectedEdge, !ids.contains(selectedEdge) { self.selectedEdge = nil }
            if let selectedNode, !snapshot.nodes.map(\.id).contains(selectedNode) { self.selectedNode = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.s) {
                    Text(mode == .traffic ? L("Traffic map") : L("AI activity map"))
                        .font(.title2.bold()).foregroundStyle(FL.ink)
                    FLPill(text: focus.isActive ? L("Focus: %@", focus.summary)
                           : mode == .traffic ? L("All applications") : L("Proved AI agents"),
                           systemImage: focus.isActive ? "scope" : mode.icon, color: FL.accent)
                }
                Text(mode == .traffic ? L("Observed connections during %@", granularity.periodName)
                     : L("Observed agent, tool, and service activity during %@", granularity.periodName))
                    .font(.caption).foregroundStyle(FL.muted)
            }
            Spacer()
            if snapshot.hidden.edgeCount > 0 {
                Label(L("%lld quieter connections hidden", snapshot.hidden.edgeCount), systemImage: "ellipsis.circle")
                    .font(.caption).foregroundStyle(FL.muted)
                    .help(hiddenSummary)
            }
            Picker(L("Mode"), selection: $mode) {
                ForEach(Mode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Picker(L("Period"), selection: $granularity) {
                ForEach(Granularity.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 112)
            Picker(L("View"), selection: $presentation) {
                ForEach(Presentation.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
        .background(FL.surface)
    }

    private var hiddenSummary: String {
        let explanation = L("The map stays readable by showing the busiest relationships. The list uses the same bounded selection.")
        let totals = "\(L("Received")): \(ByteFormat.string(snapshot.hidden.counters.bytesIn)) · "
            + "\(L("Sent")): \(ByteFormat.string(snapshot.hidden.counters.bytesOut)) · "
            + L("%lld connections", snapshot.hidden.counters.flows)
        return explanation + "\n" + totals
    }

    private var graphAndInspector: some View {
        HSplitView {
            TrafficGraphCanvas(snapshot: snapshot, selectedNode: $selectedNode, selectedEdge: $selectedEdge,
                               reduceMotion: reduceMotion)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            TrafficGraphInspector(selection: selection, granularity: granularity)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 350, maxHeight: .infinity)
                .environmentObject(nav)
        }
    }

    private var listAndInspector: some View {
        HSplitView {
            TrafficGraphList(snapshot: snapshot, selectedEdge: $selectedEdge, selectedNode: $selectedNode)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            TrafficGraphInspector(selection: selection, granularity: granularity)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 350, maxHeight: .infinity)
                .environmentObject(nav)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(mode == .traffic ? L("No traffic to visualize") : L("No AI activity to visualize"),
                  systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(query.isEmpty
                 ? mode == .traffic ? L("Flowlight has not observed any connections in this period.")
                    : L("Flowlight has not observed any proved AI agent activity in this period.")
                 : L("No observed connections match this search."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func node(_ id: TrafficGraphNodeID) -> TrafficGraphNode? {
        snapshot.nodes.first { $0.id == id }
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        let granularity = granularity
        let mode = mode
        let to = Date()
        let from = to.addingTimeInterval(-granularity.defaultWindow)
        let filter: TrafficFilter = {
            guard mode == .traffic else { return .none }
            return TrafficFilter(focus: focus.scope)
        }()
        do {
            let loaded = try await monitor.read { database in
                switch mode {
                case .traffic:
                    return try database.appDestinationRows(granularity, from: from, to: to, filter: filter)
                case .ai:
                    return try database.aiVisualizationRows(granularity, from: from, to: to)
                }
            }
            guard !Task.isCancelled else { return }
            rows = loaded
            loadID = UUID()
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            loadID = UUID()
            monitor.lastError = error.localizedDescription
        }
    }

    @MainActor
    private func rebuild() async {
        let source = rows
        let mode = mode
        let focusScope = focus.scope
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let built = await Task.detached(priority: .userInitiated) {
            let searched = query.isEmpty ? source : source.filter { row in
                row.appName.lowercased().contains(query)
                    || row.bundleID.lowercased().contains(query)
                    || row.domain.lowercased().contains(query)
                    || row.remoteIP.lowercased().contains(query)
                    || row.owner.lowercased().contains(query)
                    || row.parentAgent.lowercased().contains(query)
                    || row.parentAgentName.lowercased().contains(query)
                    || row.mcpServer.lowercased().contains(query)
            }
            switch mode {
            case .traffic:
                return TrafficGraphBuilder.build(rows: searched)
            case .ai:
                let visible = searched.filter {
                    focusScope.isEmpty || focusScope.matches(bundleID: $0.bundleID,
                                                              domain: $0.domain,
                                                              remoteIP: $0.remoteIP)
                        || (!$0.parentAgent.isEmpty && focusScope.bundleIDs.contains($0.parentAgent))
                }
                return AITrafficGraphBuilder.build(rows: source, visibleRows: visible)
            }
        }.value
        guard !Task.isCancelled else { return }
        snapshot = built
    }

    private struct LoadKey: Equatable {
        var mode: Mode
        var granularity: Granularity
        var focus: FocusScope
        var version: Int
    }

    private struct RebuildKey: Equatable {
        var loadID: UUID
        var query: String
        var mode: Mode
    }
}

private enum GraphSelection {
    case node(TrafficGraphNode)
    case edge(TrafficGraphEdge, source: TrafficGraphNode?, target: TrafficGraphNode?)
}

private struct TrafficGraphCanvas: View {
    var snapshot: TrafficGraphSnapshot
    @Binding var selectedNode: TrafficGraphNodeID?
    @Binding var selectedEdge: TrafficGraphEdgeID?
    var reduceMotion: Bool
    @State private var hoveredNode: TrafficGraphNodeID?
    @State private var hoveredEdge: TrafficGraphEdgeID?
    @State private var cachedLayout = TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
    @State private var viewport = TrafficGraphViewport()
    @State private var panStart: TrafficGraphViewport?
    @State private var zoomStart: TrafficGraphViewport?

    var body: some View {
        GeometryReader { geometry in
            let graphSize = CGSize(width: max(900, geometry.size.width), height: max(760, geometry.size.height))
            let graphBounds = CGRect(origin: .zero, size: graphSize)
            let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: graphBounds,
                                                    preserving: cachedLayout.nodeFrames.isEmpty ? nil : cachedLayout)
            let layoutKey = LayoutKey(snapshot: snapshot, size: graphSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                graphContent(layout, size: graphSize)
                    .scaleEffect(viewport.scale, anchor: .topLeading)
                    .offset(viewport.offset)
                viewportControls(layout: layout, in: CGRect(origin: .zero, size: geometry.size))
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoveredEdge = layout.edge(at: viewport.graphPoint(for: point), tolerance: 12 / viewport.scale)
                case .ended:
                    hoveredEdge = nil
                }
            }
            .onTapGesture { point in
                let graphPoint = viewport.graphPoint(for: point)
                if let edge = layout.edge(at: graphPoint, tolerance: 12 / viewport.scale) {
                    select(edge)
                } else if !layout.nodeFrames.values.contains(where: { $0.contains(graphPoint) }) {
                    selectedEdge = nil
                    selectedNode = nil
                }
            }
            .gesture(panGesture)
            .simultaneousGesture(zoomGesture(in: geometry.size))
            .task(id: layoutKey) {
                cachedLayout = layout
                viewport.fit(content: layout.contentBounds,
                             in: CGRect(origin: .zero, size: geometry.size))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Traffic relationship map"))
            .accessibilityHint(L("Drag to pan, pinch to zoom, or use the map controls."))
        }
    }

    private func graphContent(_ layout: TrafficGraphLayoutSnapshot, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            edgeLayer(layout)
            particleLayer(layout)
            relationshipControls(layout)
            ForEach(snapshot.nodes) { node in
                if let frame = layout.nodeFrames[node.id] {
                    TrafficGraphNodeView(
                        node: node,
                        selected: selectedNode == node.id,
                        hovered: hoveredNode == node.id,
                        dimmed: isNodeDimmed(node.id)
                    ) {
                        selectedNode = node.id
                        selectedEdge = nil
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .onHover { inside in
                        hoveredNode = inside ? node.id : (hoveredNode == node.id ? nil : hoveredNode)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panStart ?? viewport
                if panStart == nil { panStart = start }
                var next = start
                next.pan(by: value.translation)
                viewport = next
            }
            .onEnded { _ in panStart = nil }
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                let start = zoomStart ?? viewport
                if zoomStart == nil { zoomStart = start }
                var next = start
                next.zoom(by: factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
                viewport = next
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func viewportControls(layout: TrafficGraphLayoutSnapshot, in bounds: CGRect) -> some View {
        HStack(spacing: 2) {
            Button { viewport.zoom(by: 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY)) } label: {
                Image(systemName: "plus")
            }
            .help(L("Zoom in"))
            Button { viewport.zoom(by: 1 / 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY)) } label: {
                Image(systemName: "minus")
            }
            .help(L("Zoom out"))
            Divider().frame(height: 16)
            Button(L("Fit")) { viewport.fit(content: layout.contentBounds, in: bounds) }
                .help(L("Fit the map in the window"))
            Button(L("Reset")) { viewport.reset() }
                .help(L("Reset zoom and position"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(6)
        .background(FL.surface, in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(FL.line))
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func edgeLayer(_ layout: TrafficGraphLayoutSnapshot) -> some View {
        Canvas { context, _ in
            for edge in snapshot.edges {
                guard let curve = layout.edgeCurves[edge.id] else { continue }
                let emphasized = selectedEdge == edge.id || hoveredEdge == edge.id
                let related = isEdgeRelated(edge)
                let baseOpacity = emphasized ? 0.92 : related ? 0.42 : 0.10
                if edge.relationship == .worksFor {
                    context.stroke(path(curve), with: .color(FL.graphInvocation.opacity(baseOpacity)),
                                   style: StrokeStyle(lineWidth: emphasized ? 2.5 : 1.5, lineCap: .round,
                                                      dash: [6, 5]))
                    continue
                }

                let width = layout.edgeWidths[edge.id] ?? 1
                context.fill(ribbonPath(curve, width: width),
                             with: .color(FL.muted.opacity(emphasized ? 0.44 : related ? 0.20 : 0.05)))
                guard emphasized, edge.counters.total > 0 else { continue }

                let receivedWidth = width * CGFloat(edge.counters.bytesIn) / CGFloat(edge.counters.total)
                let sentWidth = width - receivedWidth
                if receivedWidth > 0 {
                    let offset = -(width - receivedWidth) / 2
                    context.fill(ribbonPath(curve, width: receivedWidth, offset: offset),
                                 with: .color(FL.graphReceived.opacity(0.88)))
                }
                if sentWidth > 0 {
                    let offset = (width - sentWidth) / 2
                    context.fill(ribbonPath(curve, width: sentWidth, offset: offset),
                                 with: .color(FL.graphSent.opacity(0.88)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func particleLayer(_ layout: TrafficGraphLayoutSnapshot) -> some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                Canvas { context, _ in
                    for edge in snapshot.edges where isEdgeRelated(edge) {
                        for particle in layout.particles(for: edge, at: timeline.date.timeIntervalSinceReferenceDate,
                                                         reduceMotion: reduceMotion) {
                            let rect = CGRect(x: particle.position.x - particle.radius, y: particle.position.y - particle.radius,
                                              width: particle.radius * 2, height: particle.radius * 2)
                            let color = particle.direction == .received ? FL.graphReceived
                                : particle.direction == .sent ? FL.graphSent : FL.graphInvocation
                            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)),
                                           with: .color(FL.ground), lineWidth: 1)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func relationshipControls(_ layout: TrafficGraphLayoutSnapshot) -> some View {
        ForEach(snapshot.edges) { edge in
            if let curve = layout.edgeCurves[edge.id] {
                Button { select(edge.id) } label: {
                    Color.clear.frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(curve.point(at: 0.5))
                .accessibilityLabel(edgeAccessibilityLabel(edge))
                .accessibilityHint(L("Select to inspect this connection"))
            }
        }
    }

    private func edgeAccessibilityLabel(_ edge: TrafficGraphEdge) -> String {
        let source = snapshot.nodes.first { $0.id == edge.source }?.title ?? L("Source")
        let target = snapshot.nodes.first { $0.id == edge.target }?.title ?? L("Destination")
        if edge.relationship == .worksFor { return "\(source), \(L("Works for")), \(target)" }
        return L("%@ to %@, received %@, sent %@, %lld connections", source, target,
                 ByteFormat.string(edge.counters.bytesIn), ByteFormat.string(edge.counters.bytesOut),
                 edge.counters.flows)
    }

    private func select(_ edge: TrafficGraphEdgeID) {
        selectedEdge = edge
        selectedNode = nil
    }

    private func isEdgeRelated(_ edge: TrafficGraphEdge) -> Bool {
        if selectedEdge == nil, selectedNode == nil { return true }
        return selectedEdge == edge.id || selectedNode == edge.source || selectedNode == edge.target
    }

    private func isNodeDimmed(_ id: TrafficGraphNodeID) -> Bool {
        if selectedEdge == nil, selectedNode == nil { return false }
        if selectedNode == id { return false }
        return !snapshot.edges.contains { edge in
            isEdgeRelated(edge) && (edge.source == id || edge.target == id)
        }
    }

    private func path(_ curve: TrafficGraphCurve) -> Path {
        Path { path in
            path.move(to: curve.start)
            path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        }
    }

    private func ribbonPath(_ curve: TrafficGraphCurve, width: CGFloat, offset: CGFloat = 0) -> Path {
        let top = curve.offset(by: offset - width / 2)
        let bottom = curve.offset(by: offset + width / 2)
        return Path { path in
            path.move(to: top.start)
            path.addCurve(to: top.end, control1: top.control1, control2: top.control2)
            path.addLine(to: bottom.end)
            path.addCurve(to: bottom.start, control1: bottom.control2, control2: bottom.control1)
            path.closeSubpath()
        }
    }

    private struct LayoutKey: Equatable {
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
}

private struct TrafficGraphNodeView: View {
    var node: TrafficGraphNode
    var selected: Bool
    var hovered: Bool
    var dimmed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if node.kind == .app || node.kind == .agent { appContent } else { destinationContent }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.28 : 1)
        .overlay {
            if selected || hovered {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FL.accent.opacity(selected ? 0.9 : 0.45), lineWidth: selected ? 2 : 1)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("Select to inspect this traffic"))
    }

    private var appContent: some View {
        HStack(spacing: 9) {
            AppIconView(path: node.appPath, size: 30)
            Text(node.title).font(.caption.bold()).foregroundStyle(FL.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FL.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FL.line, lineWidth: 1))
    }

    private var destinationContent: some View {
        HStack(spacing: 7) {
            Image(systemName: nodeIcon).foregroundStyle(node.kind == .tool || node.kind == .mcp ? FL.tool : FL.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(.caption.bold()).foregroundStyle(FL.ink).lineLimit(2)
                if !node.detail.isEmpty { Text(node.detail).font(.caption2).foregroundStyle(FL.faint).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(FL.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FL.line, lineWidth: 1))
    }

    private var nodeIcon: String {
        switch node.kind {
        case .service: return "sparkles"
        case .tool: return "hammer"
        case .mcp: return "shippingbox"
        default: return "network"
        }
    }

    private var accessibilityLabel: String {
        L("%@, received %@, sent %@, %lld connections", node.title, ByteFormat.string(node.counters.bytesIn),
          ByteFormat.string(node.counters.bytesOut), node.counters.flows)
    }
}

private struct TrafficGraphInspector: View {
    var selection: GraphSelection?
    var granularity: Granularity
    @EnvironmentObject private var nav: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let selection {
                switch selection {
                case .node(let node): nodeInspector(node)
                case .edge(let edge, let source, let target): edgeInspector(edge, source: source, target: target)
                }
            } else {
                Label(L("Select a node or connection"), systemImage: "cursorarrow.click")
                    .font(.headline).foregroundStyle(FL.ink)
                Text(L("The map stays still while traffic values update. Moving particles show direction; use List for the exact same values without motion."))
                    .font(.callout).foregroundStyle(FL.muted)
                legend
                Spacer()
            }
        }
        .padding(Spacing.l)
        .background(FL.surface)
    }

    private func nodeInspector(_ node: TrafficGraphNode) -> some View {
        Group {
            Text(node.title).font(.title3.bold()).foregroundStyle(FL.ink)
            if !node.detail.isEmpty { Text(node.detail).font(.caption).foregroundStyle(FL.muted) }
            FLPill(text: L("Observed"), systemImage: "eye", color: FL.muted)
            metrics(node.counters)
            Divider()
            if !node.members.isEmpty && (node.filter.domainSuffix != nil || node.members.count > 1) {
                if node.filter.domainSuffix != nil {
                    Button(L("Show domain family in Reports")) {
                        nav.showReport(filter: node.filter, granularity: granularity)
                    }
                }
                Text(L("Exact destinations")).font(.caption.bold()).foregroundStyle(FL.muted)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(node.members) { member in exactMember(member, source: memberSource(member)) }
                    }
                }
            } else {
                Button(L("Show in Reports")) { nav.showReport(filter: node.filter, granularity: granularity) }
                #if !APP_STORE
                if node.kind == .destination || node.kind == .service {
                    if VisualizeActionScope.canInspect(node.filter) {
                        Button(L("Inspect")) {
                            VisualizeActionScope.showInspect(nav, filter: node.filter)
                        }
                    }
                } else {
                    Button(L("Inspect")) {
                        nav.showInspect(app: (node.filter.bundleID ?? "", node.title),
                                        includeAttributedChildren: node.filter.includeAttributedChildren,
                                        agentParent: node.filter.agentParent, mcpServer: node.filter.mcpServer)
                    }
                }
                #endif
            }
            Spacer()
            legend
        }
    }

    private func edgeInspector(_ edge: TrafficGraphEdge, source: TrafficGraphNode?, target: TrafficGraphNode?) -> some View {
        Group {
            Text(L("Connection")).font(.caption.bold()).foregroundStyle(FL.muted)
            Text("\(source?.title ?? L("App")) → \(target?.title ?? L("Destination"))")
                .font(.title3.bold()).foregroundStyle(FL.ink)
            FLPill(text: edge.relationship == .observed ? L("Observed")
                   : edge.relationship == .worksFor ? L("Works for") : L("Invoked"),
                   systemImage: edge.relationship == .observed ? "eye"
                    : edge.relationship == .worksFor ? "point.topleft.down.to.point.bottomright.curvepath" : "bolt",
                   color: edge.relationship == .observed ? FL.muted : FL.graphInvocation)
            if edge.relationship == .observed {
                metrics(edge.counters)
                Divider()
                if edge.members.count > 1 {
                    Text(L("Exact destinations")).font(.caption.bold()).foregroundStyle(FL.muted)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(edge.members) { member in exactMember(member, source: source) }
                        }
                    }
                } else {
                    exactActions(edge.filter, source: source)
                }
            } else {
                Text(L("Stored process lineage proves this tool works for the agent. It does not prove a tool invocation."))
                    .font(.callout).foregroundStyle(FL.muted)
            }
            Spacer()
            legend
        }
    }

    private func memberSource(_ member: TrafficGraphMember) -> TrafficGraphNode? {
        guard let bundleID = member.filter.bundleID else { return nil }
        return TrafficGraphNode(id: TrafficGraphNodeID(rawValue: "member-app:" + bundleID), kind: .app,
                                title: bundleID, detail: bundleID, appPath: "",
                                filter: TrafficFilter(bundleID: bundleID), counters: member.counters)
    }

    private func exactMember(_ member: TrafficGraphMember, source: TrafficGraphNode?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.title).font(.callout.bold()).foregroundStyle(FL.ink)
                    if !member.detail.isEmpty { Text(member.detail).font(.caption2).foregroundStyle(FL.muted) }
                    if !member.protocols.isEmpty {
                        Text(member.protocols).font(.caption2).foregroundStyle(FL.muted)
                    }
                }
                Spacer()
                Text(ByteFormat.string(member.counters.total)).font(.caption.monospacedDigit()).foregroundStyle(FL.muted)
            }
            exactActions(member.filter, source: source)
        }
        .padding(8)
        .background(FL.surfaceDeep, in: RoundedRectangle(cornerRadius: Radius.chip))
    }

    private func exactActions(_ filter: TrafficFilter, source: TrafficGraphNode?) -> some View {
        HStack(spacing: Spacing.s) {
            Button(L("Reports")) { nav.showReport(filter: filter, granularity: granularity) }
            #if !APP_STORE
            if VisualizeActionScope.canInspect(filter) {
                Button(L("Inspect")) {
                    VisualizeActionScope.showInspect(nav, filter: filter, sourceTitle: source?.title)
                }
            }
            #endif
            if let rule = VisualizeActionScope.blockRule(for: filter) {
                Button(L("Block…")) { nav.writeRule(rule) }
            }
        }
        .controlSize(.small)
    }

    private func metrics(_ counters: FlowCounters) -> some View {
        VStack(spacing: 8) {
            metric(L("Received"), ByteFormat.string(counters.bytesIn), FL.graphReceived, "arrow.down")
            metric(L("Sent"), ByteFormat.string(counters.bytesOut), FL.graphSent, "arrow.up")
            metric(L("Connections"), counters.flows.formatted(), FL.muted, "link")
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color, _ icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundStyle(color)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(FL.ink)
        }.font(.callout)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Direction and evidence")).font(.caption.bold()).foregroundStyle(FL.muted)
            Label(L("Received"), systemImage: "circle.fill").foregroundStyle(FL.graphReceived)
            Label(L("Sent"), systemImage: "circle.fill").foregroundStyle(FL.graphSent)
            Label(L("Works for"), systemImage: "line.diagonal").foregroundStyle(FL.graphInvocation)
        }.font(.caption)
    }

}

private struct TrafficGraphList: View {
    var snapshot: TrafficGraphSnapshot
    @Binding var selectedEdge: TrafficGraphEdgeID?
    @Binding var selectedNode: TrafficGraphNodeID?

    private let columns = [
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 180), alignment: .leading),
        GridItem(.flexible(minimum: 100), alignment: .leading),
        GridItem(.flexible(minimum: 100), alignment: .leading),
        GridItem(.flexible(minimum: 105), alignment: .leading),
        GridItem(.flexible(minimum: 105), alignment: .leading)
    ]

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                header(L("App")); header(L("Destination")); header(L("Received")); header(L("Sent"))
                header(L("Connections")); header(L("Status"))
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(snapshot.edges) { edge in
                        row(edge)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(Spacing.l)
        .accessibilityLabel(L("Traffic connections"))
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(FL.muted)
    }

    private func row(_ edge: TrafficGraphEdge) -> some View {
        let source = node(edge.source)?.title ?? "—"
        let target = node(edge.target)
        return Button { select(edge) } label: {
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                Text(source)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target?.title ?? "—")
                    if let detail = target?.detail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(FL.muted)
                    }
                }
                Text(edge.relationship == .observed ? ByteFormat.string(edge.counters.bytesIn) : "—").monospacedDigit()
                Text(edge.relationship == .observed ? ByteFormat.string(edge.counters.bytesOut) : "—").monospacedDigit()
                Text(edge.relationship == .observed ? edge.counters.flows.formatted() : "—").monospacedDigit()
                FLPill(text: edge.relationship == .observed ? L("Observed")
                       : edge.relationship == .worksFor ? L("Works for") : L("Invoked"),
                       systemImage: edge.relationship == .observed ? "eye" : "point.topleft.down.to.point.bottomright.curvepath",
                       color: edge.relationship == .observed ? FL.muted : FL.graphInvocation)
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedEdge == edge.id ? FL.accent.opacity(0.12) : FL.surfaceDeep,
                        in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibilityLabel(edge))
    }

    private func node(_ id: TrafficGraphNodeID) -> TrafficGraphNode? { snapshot.nodes.first { $0.id == id } }

    private func select(_ edge: TrafficGraphEdge) {
        selectedEdge = edge.id
        selectedNode = nil
    }

    private func rowAccessibilityLabel(_ edge: TrafficGraphEdge) -> String {
        let app = node(edge.source)?.title ?? L("App")
        let destination = node(edge.target)?.title ?? L("Destination")
        if edge.relationship == .worksFor { return "\(app), \(L("Works for")), \(destination)" }
        if edge.relationship == .invoked { return "\(app), \(L("Invoked")), \(destination)" }
        return "\(app), \(destination), \(L("Received")) \(ByteFormat.string(edge.counters.bytesIn)), "
            + "\(L("Sent")) \(ByteFormat.string(edge.counters.bytesOut)), \(L("%lld connections", edge.counters.flows))"
    }
}
