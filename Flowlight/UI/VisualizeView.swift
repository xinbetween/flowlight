import SwiftUI

enum VisualizeSelectionPolicy {
    static func shouldClear(previousQuery: String, newQuery: String) -> Bool {
        previousQuery != newQuery
    }

    static func mapOmitsSelection(
        selectedNode: TrafficGraphNodeID?,
        selectedEdge: TrafficGraphEdgeID?,
        map: TrafficGraphSnapshot
    ) -> Bool {
        if let selectedEdge, !map.edges.contains(where: { $0.id == selectedEdge }) { return true }
        if let selectedNode, !map.nodes.contains(where: { $0.id == selectedNode }) { return true }
        return false
    }

    static func listOmitsSelection(
        selectedNode selectedNodeID: TrafficGraphNodeID?,
        selectedEdge: TrafficGraphEdgeID?,
        complete: TrafficGraphSnapshot
    ) -> Bool {
        if let selectedEdge, !complete.edges.contains(where: { $0.id == selectedEdge }) { return true }
        if let selectedNodeID {
            guard let node = selectedNode(selectedNodeID, in: complete) else { return true }
            return node.roleEvidence.isEmpty
        }
        return false
    }

    static func selectedNode(
        _ id: TrafficGraphNodeID,
        in snapshot: TrafficGraphSnapshot
    ) -> TrafficGraphNode? {
        snapshot.nodes.first { $0.id == id }
    }

    static func validEndpointSelection(
        _ selection: TrafficGraphNodeID?,
        options: [TrafficGraphEndpointOption]
    ) -> TrafficGraphNodeID? {
        guard let selection else { return nil }
        return options.contains { $0.id == selection } ? selection : nil
    }

    static func revealedNodeFocus(
        afterExpanding id: TrafficGraphNodeID,
        in snapshot: TrafficGraphSnapshot
    ) -> TrafficGraphNodeID? {
        snapshot.nodes.first { $0.id == id }?.collapsedNodeIDs.sorted().first
    }

    static func revealedEdgeFocus(
        afterExpanding id: TrafficGraphEdgeID,
        in snapshot: TrafficGraphSnapshot
    ) -> TrafficGraphEdgeID? {
        snapshot.edges.first { $0.id == id }?.collapsedEdgeIDs.sorted().first
    }
}

enum VisualizeEvidenceScope {
    static func rows(
        _ rows: [BreakdownRow],
        query: String,
        focus: FocusScope
    ) -> [BreakdownRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            let matchesQuery = query.isEmpty || [
                row.appName,
                row.bundleID,
                row.appPath,
                row.domain,
                row.remoteIP,
                row.owner,
                row.parentAgent,
                row.parentAgentName,
                row.mcpServer,
                row.launcherBundleID,
                row.launcherName,
                row.launcherPath,
                row.routeProxyBundleID,
                row.routeProxyName,
                row.routeProxyPath
            ].contains { $0.lowercased().contains(query) }
            let matchesFocus = focus.isEmpty
                || focus.matches(
                    bundleID: row.bundleID,
                    domain: row.domain,
                    remoteIP: row.remoteIP
                )
                || focus.matches(bundleID: row.parentAgent, domain: "", remoteIP: "")
                || focus.matches(bundleID: row.launcherBundleID, domain: "", remoteIP: "")
                || focus.matches(bundleID: row.routeProxyBundleID, domain: "", remoteIP: "")
            return matchesQuery && matchesFocus
        }
    }

    static func blockedAttempts(
        _ attempts: [BlockedAttemptRow],
        query: String,
        focus: FocusScope
    ) -> [BlockedAttemptRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return attempts.filter { attempt in
            let exactDestination = VisualizationDestinationCanonicalizer.parse(attempt.destination)
            let matchesFocus = focus.isEmpty
                || focus.matches(
                    bundleID: attempt.bundleID.isEmpty ? attempt.agentKey : attempt.bundleID,
                    domain: exactDestination.domain ?? "",
                    remoteIP: exactDestination.address ?? ""
                )
                || focus.matches(bundleID: attempt.agentKey, domain: "", remoteIP: "")
            let matchesQuery = query.isEmpty || [
                attempt.appName,
                attempt.bundleID,
                attempt.agentName,
                attempt.agentKey,
                attempt.destination,
                attempt.category,
                attempt.source,
                attempt.detail
            ].contains { $0.lowercased().contains(query) }
            return matchesFocus && matchesQuery
        }
    }
}

enum VisualizeGatewayScope {
    static func includes(
        _ gateway: AgentGatewayConfig,
        identity: AgentGatewayIdentity? = nil,
        query: String,
        focus: FocusScope
    ) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = AgentCatalog.knownAgent(
            bundleID: gateway.agent,
            appName: gateway.agent
        )
        var aliases: Set<String> = [gateway.agent.lowercased()]
        if let known {
            aliases.insert(known.name.lowercased())
            aliases.formUnion(known.processNames.map { $0.lowercased() })
            aliases.formUnion(known.bundleIDs.map { $0.lowercased() })
        }
        if let identity {
            aliases.insert(identity.bundleID.lowercased())
            aliases.insert(identity.name.lowercased())
            aliases.insert(identity.path.lowercased())
        }
        aliases.remove("")
        let matchesQuery = query.isEmpty
            || aliases.contains(where: { $0.contains(query) })
            || gateway.endpoint.description.lowercased().contains(query)
            || gateway.sourceKey.lowercased().contains(query)
        let matchesFocus = focus.isEmpty
            || !Set(focus.bundleIDs.map { $0.lowercased() }).isDisjoint(with: aliases)
            || focus.matches(
                bundleID: gateway.agent,
                domain: HostCanonicalizer.host(gateway.endpoint.host) ?? "",
                remoteIP: HostCanonicalizer.address(gateway.endpoint.host) ?? ""
            )
            || identity.map {
                focus.matches(bundleID: $0.bundleID, domain: "", remoteIP: "")
            } == true
        return matchesQuery && matchesFocus
    }
}

@MainActor
enum VisualizeActionScope {
    static func canInspect(_ filter: TrafficFilter) -> Bool {
        InspectNavigationScope.canInspect(filter)
    }

    static func canBlock(_ filter: TrafficFilter) -> Bool {
        exactDestination(filter) != nil
    }

    static func showInspect(_ nav: AppNavigation, filter: TrafficFilter, sourceTitle: String? = nil) {
        InspectNavigationScope.showInspect(nav, filter: filter, sourceTitle: sourceTitle)
    }

    static func blockRule(for filter: TrafficFilter) -> Rule? {
        guard filter.bundleIDs.isEmpty,
              let destination = exactDestination(filter) else { return nil }
        var rule = RuleStore.block(
            app: filter.agentParent ?? filter.bundleID ?? "",
            destination: destination
        )
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
    @ObservedObject private var workspaceStore = AgentWorkspaceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualize.mode") private var mode: Mode = .traffic
    @AppStorage("visualize.granularity") private var granularity: Granularity = .minute
    @AppStorage("visualize.presentation") private var presentation: Presentation = .map
    @State private var rows: [BreakdownRow] = []
    @State private var blockedAttempts: [BlockedAttemptRow] = []
    @State private var completeSnapshot = TrafficGraphSnapshot.empty
    @State private var mapSnapshot = TrafficGraphSnapshot.empty
    @State private var expandedGroupIDs: Set<TrafficGraphNodeID> = []
    @State private var expandedEdgeGroupIDs: Set<TrafficGraphEdgeID> = []
    @State private var listVisibleCount = TrafficGraphListPager.pageSize
    @State private var selectedNode: TrafficGraphNodeID?
    @State private var selectedEdge: TrafficGraphEdgeID?
    @State private var sourceOptions: [TrafficGraphEndpointOption] = []
    @State private var destinationOptions: [TrafficGraphEndpointOption] = []
    @State private var selectedSource: TrafficGraphNodeID?
    @State private var selectedDestination: TrafficGraphNodeID?
    @State private var query = ""
    @State private var loading = false
    @State private var loadID = UUID()

    private var endDate: Date { Date() }
    private var startDate: Date { endDate.addingTimeInterval(-granularity.defaultWindow) }
    private var agentGateways: [AgentGatewayConfig] {
        DemoData.isEnabled ? DemoData.agentGateways : workspaceStore.workspaces.flatMap(\.gateways)
    }
    private var gatewayVersion: String {
        agentGateways.map {
            "\($0.agent)|\($0.endpoint.description)|\($0.source)|\($0.sourceKey)"
        }.sorted().joined(separator: "\n")
    }
    private var selectionSnapshot: TrafficGraphSnapshot {
        presentation == .map ? mapSnapshot : completeSnapshot
    }

    private var selection: GraphSelection? {
        if let selectedEdge, let edge = selectionSnapshot.edges.first(where: { $0.id == selectedEdge }) {
            return .edge(
                edge,
                source: VisualizeSelectionPolicy.selectedNode(edge.source, in: selectionSnapshot),
                target: VisualizeSelectionPolicy.selectedNode(edge.target, in: selectionSnapshot)
            )
        }
        if let selectedNode,
           let node = VisualizeSelectionPolicy.selectedNode(selectedNode, in: selectionSnapshot) {
            return .node(node)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            endpointToolbar
            Divider()
            if completeSnapshot.nodes.isEmpty, loading {
                ProgressView(L("Loading visualization…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if completeSnapshot.nodes.isEmpty {
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
        .task { workspaceStore.refresh(gatewaysOnly: true) }
        .task(id: LoadKey(mode: mode, granularity: granularity, focus: focus.scope,
                          trafficVersion: monitor.dataVersion, ruleVersion: monitor.rules.version,
                          packVersion: monitor.rulePacks.version)) { await reload() }
        .task(id: granularity) {
            guard granularity == .second else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { await reload() }
            }
        }
        .task(id: RebuildKey(loadID: loadID, query: query, mode: mode,
                             focus: focus.scope, gatewayVersion: gatewayVersion,
                             selectedSource: selectedSource,
                             selectedDestination: selectedDestination,
                             expandedGroupIDs: expandedGroupIDs,
                             expandedEdgeGroupIDs: expandedEdgeGroupIDs)) { await rebuild() }
        .onChange(of: mode) { _, _ in
            rows = []
            completeSnapshot = .empty
            mapSnapshot = .empty
            expandedGroupIDs = []
            expandedEdgeGroupIDs = []
            listVisibleCount = TrafficGraphListPager.pageSize
            selectedNode = nil
            selectedEdge = nil
            sourceOptions = []
            destinationOptions = []
            selectedSource = nil
            selectedDestination = nil
            loadID = UUID()
        }
        .onChange(of: granularity) { _, _ in
            listVisibleCount = TrafficGraphListPager.pageSize
        }
        .onChange(of: focus.scope) { _, _ in
            listVisibleCount = TrafficGraphListPager.pageSize
            expandedGroupIDs = []
            expandedEdgeGroupIDs = []
            selectedNode = nil
            selectedEdge = nil
        }
        .onChange(of: query) { previous, current in
            listVisibleCount = TrafficGraphListPager.pageSize
            expandedGroupIDs = []
            expandedEdgeGroupIDs = []
            guard VisualizeSelectionPolicy.shouldClear(previousQuery: previous, newQuery: current) else { return }
            selectedNode = nil
            selectedEdge = nil
        }
        .onChange(of: selectedSource) { _, _ in resetEndpointContext() }
        .onChange(of: selectedDestination) { _, _ in resetEndpointContext() }
        .onChange(of: presentation) { _, current in
            let omitsSelection = switch current {
            case .map:
                VisualizeSelectionPolicy.mapOmitsSelection(
                    selectedNode: selectedNode,
                    selectedEdge: selectedEdge,
                    map: mapSnapshot
                )
            case .list:
                VisualizeSelectionPolicy.listOmitsSelection(
                    selectedNode: selectedNode,
                    selectedEdge: selectedEdge,
                    complete: completeSnapshot
                )
            }
            guard omitsSelection else { return }
            selectedNode = nil
            selectedEdge = nil
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
            if presentation == .map, collapsedExactItemCount > 0 {
                Label(
                    L("%lld exact items collapsed into %lld groups",
                      Int64(collapsedExactItemCount), Int64(collapsedGroupCount)),
                    systemImage: "square.grid.2x2"
                )
                .font(.caption).foregroundStyle(FL.muted)
                .help(L("Select a group to reveal its exact chart items."))
            }
            if presentation == .map, !expandedGroupIDs.isEmpty || !expandedEdgeGroupIDs.isEmpty {
                Button(L("Collapse groups")) {
                    expandedGroupIDs = []
                    expandedEdgeGroupIDs = []
                    selectedNode = nil
                    selectedEdge = nil
                }
                .buttonStyle(.borderless)
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

    private var endpointToolbar: some View {
        HStack(spacing: Spacing.m) {
            TrafficGraphEndpointPicker(
                label: L("Source"),
                anyTitle: mode == .traffic ? L("Any application") : L("Any AI agent"),
                searchPrompt: mode == .traffic ? L("Search applications") : L("Search AI agents"),
                systemImage: mode == .traffic ? "app" : "sparkles",
                options: sourceOptions,
                selection: $selectedSource
            )
            Image(systemName: "arrow.right")
                .font(.caption.bold())
                .foregroundStyle(FL.muted)
                .accessibilityHidden(true)
            TrafficGraphEndpointPicker(
                label: L("Destination"),
                anyTitle: L("Any destination"),
                searchPrompt: L("Search destinations"),
                systemImage: "globe",
                options: destinationOptions,
                selection: $selectedDestination
            )
            Text(selectedSource == nil && selectedDestination == nil
                 ? L("Map shows the top 10 sources by traffic. List keeps every exact relationship.")
                 : L("Focused scope shows every connected relationship; large neighborhoods group progressively."))
                .font(.caption)
                .foregroundStyle(FL.muted)
                .lineLimit(2)
            Spacer(minLength: 0)
            if selectedSource != nil || selectedDestination != nil {
                Button(L("Clear scope")) {
                    selectedSource = nil
                    selectedDestination = nil
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(FL.surface)
    }

    private var collapsedGroupCount: Int {
        mapSnapshot.nodes.lazy.filter(\.isCollapsedGroup).count
            + mapSnapshot.edges.lazy.filter(\.isCollapsedGroup).count
    }

    private var collapsedExactItemCount: Int {
        mapSnapshot.nodes.lazy.filter(\.isCollapsedGroup)
            .reduce(0) { $0 + $1.collapsedNodeIDs.count }
            + mapSnapshot.edges.lazy.filter(\.isCollapsedGroup)
                .reduce(0) { $0 + $1.collapsedEdgeIDs.count }
    }

    private var graphAndInspector: some View {
        HSplitView {
            TrafficGraphCanvas(
                snapshot: mapSnapshot,
                selectedNode: $selectedNode,
                selectedEdge: $selectedEdge,
                reduceMotion: reduceMotion,
                onToggleGroup: expandGroup
            )
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            TrafficGraphInspector(
                selection: selection,
                granularity: granularity,
                onExpandEdgeGroup: expandEdgeGroup
            )
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 350, maxHeight: .infinity)
                .environmentObject(nav)
        }
    }

    private var listAndInspector: some View {
        HSplitView {
            TrafficGraphList(snapshot: completeSnapshot, mode: mode, visibleCount: $listVisibleCount,
                             selectedEdge: $selectedEdge, selectedNode: $selectedNode)
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

    @MainActor
    private func reload() async {
        let requestID = UUID()
        loadID = requestID
        loading = true
        let granularity = granularity
        let mode = mode
        let to = Date()
        let from = to.addingTimeInterval(-granularity.defaultWindow)
        do {
            let loaded = try await monitor.read { database in
                let rows: [BreakdownRow]
                switch mode {
                case .traffic:
                    rows = try database.appDestinationRows(granularity, from: from, to: to, filter: .none)
                case .ai:
                    rows = try database.aiVisualizationRows(granularity, from: from, to: to)
                }
                let attempts = try database.blockedAttempts(from: from, to: to)
                return (rows, attempts)
            }
            guard !Task.isCancelled, loadID == requestID else { return }
            rows = loaded.0
            blockedAttempts = loaded.1
            loading = false
            loadID = UUID()
        } catch {
            guard !Task.isCancelled, loadID == requestID else { return }
            rows = []
            blockedAttempts = []
            loading = false
            loadID = UUID()
            monitor.lastError = error.localizedDescription
        }
    }

    @MainActor
    private func rebuild() async {
        let source = rows
        let enforcement = blockedAttempts
        let gateways = agentGateways
        let demo = DemoData.isEnabled
        let mode = mode
        let focusScope = focus.scope
        let expandedGroupIDs = expandedGroupIDs
        let expandedEdgeGroupIDs = expandedEdgeGroupIDs
        let endpointQuery = TrafficGraphEndpointQuery(
            source: selectedSource,
            destination: selectedDestination
        )
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let built = await Task.detached(priority: .userInitiated) {
            let visibleRows = VisualizeEvidenceScope.rows(
                source,
                query: query,
                focus: focusScope
            )
            let visibleEnforcement = VisualizeEvidenceScope.blockedAttempts(
                enforcement,
                query: query,
                focus: focusScope
            )
            switch mode {
            case .traffic:
                return TrafficGraphBuilder.buildForPresentation(
                    rows: visibleRows,
                    blockedAttempts: visibleEnforcement,
                    endpointQuery: endpointQuery,
                    expandedGroupIDs: expandedGroupIDs,
                    expandedEdgeGroupIDs: expandedEdgeGroupIDs
                )
            case .ai:
                let resolvedGateways = gateways.map { gateway in
                    (
                        gateway,
                        demo ? DemoData.gatewayIdentity(gateway.endpoint)
                            : LocalGatewayResolver.resolve(gateway.endpoint)
                    )
                }
                let scopedGateways = resolvedGateways.filter { gateway, identity in
                    VisualizeGatewayScope.includes(
                        gateway,
                        identity: identity,
                        query: query,
                        focus: focusScope
                    )
                }
                return AITrafficGraphBuilder.buildForPresentation(
                    rows: source,
                    visibleRows: visibleRows,
                    blockedAttempts: visibleEnforcement,
                    gateways: scopedGateways.map(\.0),
                    resolveGateway: { endpoint in
                        scopedGateways.first { $0.0.endpoint == endpoint }?.1
                    },
                    endpointQuery: endpointQuery,
                    expandedGroupIDs: expandedGroupIDs,
                    expandedEdgeGroupIDs: expandedEdgeGroupIDs
                )
            }
        }.value
        guard !Task.isCancelled else { return }
        let validSource = VisualizeSelectionPolicy.validEndpointSelection(
            endpointQuery.source,
            options: built.sourceOptions
        )
        let validDestination = VisualizeSelectionPolicy.validEndpointSelection(
            endpointQuery.destination,
            options: built.destinationOptions
        )
        if validSource != endpointQuery.source || validDestination != endpointQuery.destination {
            sourceOptions = built.sourceOptions
            destinationOptions = built.destinationOptions
            selectedSource = validSource
            selectedDestination = validDestination
            return
        }
        completeSnapshot = built.complete
        mapSnapshot = built.map
        sourceOptions = built.sourceOptions
        destinationOptions = built.destinationOptions
        let selectionSnapshot = presentation == .map ? built.map : built.complete
        let visibleEdgeIDs = Set(selectionSnapshot.edges.map(\.id))
        let visibleNodeIDs = Set(selectionSnapshot.nodes.map(\.id))
        if let selectedEdge, !visibleEdgeIDs.contains(selectedEdge) { self.selectedEdge = nil }
        if let selectedNode, !visibleNodeIDs.contains(selectedNode) { self.selectedNode = nil }
        listVisibleCount = TrafficGraphListPager.clampedVisibleCount(
            current: listVisibleCount,
            in: built.complete
        )
    }

    private func resetEndpointContext() {
        listVisibleCount = TrafficGraphListPager.pageSize
        expandedGroupIDs = []
        expandedEdgeGroupIDs = []
        selectedNode = nil
        selectedEdge = nil
    }

    private func expandGroup(_ id: TrafficGraphNodeID) {
        let revealed = VisualizeSelectionPolicy.revealedNodeFocus(afterExpanding: id, in: mapSnapshot)
        expandedGroupIDs.insert(id)
        selectedNode = revealed
        selectedEdge = nil
    }

    private func expandEdgeGroup(_ id: TrafficGraphEdgeID) {
        let revealed = VisualizeSelectionPolicy.revealedEdgeFocus(afterExpanding: id, in: mapSnapshot)
        expandedEdgeGroupIDs.insert(id)
        selectedNode = nil
        selectedEdge = revealed
    }

    private struct LoadKey: Equatable {
        var mode: Mode
        var granularity: Granularity
        var focus: FocusScope
        var trafficVersion: Int
        var ruleVersion: Int
        var packVersion: Int
    }

    private struct RebuildKey: Equatable {
        var loadID: UUID
        var query: String
        var mode: Mode
        var focus: FocusScope
        var gatewayVersion: String
        var selectedSource: TrafficGraphNodeID?
        var selectedDestination: TrafficGraphNodeID?
        var expandedGroupIDs: Set<TrafficGraphNodeID>
        var expandedEdgeGroupIDs: Set<TrafficGraphEdgeID>
    }
}

private struct TrafficGraphEndpointPicker: View {
    var label: String
    var anyTitle: String
    var searchPrompt: String
    var systemImage: String
    var options: [TrafficGraphEndpointOption]
    @Binding var selection: TrafficGraphNodeID?
    @State private var isPresented = false
    @State private var query = ""

    private var selectedOption: TrafficGraphEndpointOption? {
        options.first { $0.id == selection }
    }

    private var filteredOptions: [TrafficGraphEndpointOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.detail.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: systemImage)
                    .foregroundStyle(FL.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(FL.muted)
                    Text(selectedOption?.title ?? anyTitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(FL.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(FL.muted)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, 7)
            .frame(width: 240)
            .background(FL.ground, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(FL.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(selectedOption?.title ?? anyTitle)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(Spacing.m)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        optionButton(id: nil, title: anyTitle, detail: nil, counters: nil)
                        ForEach(filteredOptions) { option in
                            optionButton(
                                id: option.id,
                                title: option.title,
                                detail: option.detail,
                                counters: option.counters
                            )
                        }
                    }
                    .padding(Spacing.s)
                }
                .frame(height: 320)
            }
            .frame(width: 360)
            .onDisappear { query = "" }
        }
    }

    private func optionButton(
        id: TrafficGraphNodeID?,
        title: String,
        detail: String?,
        counters: FlowCounters?
    ) -> some View {
        Button {
            selection = id
            isPresented = false
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: selection == id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == id ? FL.accent : FL.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(FL.ink).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(FL.muted).lineLimit(1)
                    }
                }
                Spacer()
                if let counters {
                    Text(ByteFormat.string(counters.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(FL.muted)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

private enum TrafficGraphAccessibilityFocus: Hashable {
    case node(TrafficGraphNodeID)
    case edge(TrafficGraphEdgeID)
    case role(String)
    case more
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
    var onToggleGroup: (TrafficGraphNodeID) -> Void
    @State private var hoveredNode: TrafficGraphNodeID?
    @State private var hoveredEdge: TrafficGraphEdgeID?
    @State private var cachedLayout = TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [:])
    @State private var viewport = TrafficGraphViewport()
    @State private var panStart: TrafficGraphViewport?
    @State private var zoomStart: TrafficGraphViewport?
    @State private var viewportIsUserControlled = false
    @AccessibilityFocusState private var accessibilityFocus: TrafficGraphAccessibilityFocus?

    var body: some View {
        GeometryReader { geometry in
            let graphSize = CGSize(
                width: max(TrafficGraphLayout.minimumCanvasWidth(for: snapshot), geometry.size.width),
                height: max(TrafficGraphLayout.minimumCanvasHeight(for: snapshot), geometry.size.height)
            )
            let graphBounds = CGRect(origin: .zero, size: graphSize)
            let layoutKey = TrafficGraphLayoutKey(snapshot: snapshot, size: graphSize)
            let layout = cachedLayout.updatingTrafficWidths(for: snapshot)
            let screenBounds = CGRect(origin: .zero, size: geometry.size)
            let visible = layout.visibleRegion(
                in: viewport.visibleGraphRect(in: screenBounds),
                margin: 96 / max(viewport.scale, 0.01)
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                if layout.nodeFrames.isEmpty, !snapshot.nodes.isEmpty {
                    ProgressView(L("Loading visualization…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                graphContent(layout, visible: visible, size: graphSize)
                    .scaleEffect(viewport.scale, anchor: .topLeading)
                    .offset(viewport.offset)
                viewportControls(layout: layout, in: screenBounds)
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
                let previous = cachedLayout.nodeFrames.isEmpty ? nil : cachedLayout
                let worker = Task.detached(priority: .userInitiated) {
                    TrafficGraphLayout.layout(
                        snapshot: snapshot,
                        in: graphBounds,
                        preserving: previous
                    )
                }
                let nextLayout = await withTaskCancellationHandler(
                    operation: { await worker.value },
                    onCancel: { worker.cancel() }
                )
                guard !Task.isCancelled, !nextLayout.nodeFrames.isEmpty else { return }
                cachedLayout = nextLayout
                if TrafficGraphViewportPolicy.shouldAutoFit(
                    isUserControlled: viewportIsUserControlled
                ) {
                    viewport.fit(content: nextLayout.contentBounds, in: screenBounds)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Traffic relationship map"))
            .accessibilityHint(L("Drag to pan, pinch to zoom, or use the map controls."))
            .task {
                await Task.yield()
                restoreAccessibilityFocus()
            }
            .onChange(of: selectedNode) { _, _ in restoreAccessibilityFocus() }
            .onChange(of: selectedEdge) { _, _ in restoreAccessibilityFocus() }
        }
    }

    private func graphContent(
        _ layout: TrafficGraphLayoutSnapshot,
        visible: TrafficGraphVisibleRegion,
        size: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            edgeLayer(layout, visible: visible)
            flowDashLayer(layout, visible: visible)
            relationshipControls(layout)
            ForEach(snapshot.nodes) { node in
                if let frame = layout.nodeFrames[node.id] {
                    TrafficGraphNodeView(
                        node: node,
                        selected: selectedNode == node.id,
                        hovered: hoveredNode == node.id,
                        dimmed: isNodeDimmed(node.id)
                    ) {
                        if node.isCollapsedGroup {
                            onToggleGroup(node.id)
                        } else {
                            selectedNode = node.id
                            selectedEdge = nil
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .onHover { inside in
                        hoveredNode = inside ? node.id : (hoveredNode == node.id ? nil : hoveredNode)
                    }
                    .accessibilityFocused($accessibilityFocus, equals: .node(node.id))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panStart ?? viewport
                if panStart == nil {
                    panStart = start
                    viewportIsUserControlled = true
                }
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
                if zoomStart == nil {
                    zoomStart = start
                    viewportIsUserControlled = true
                }
                var next = start
                next.zoom(by: factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
                viewport = next
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func viewportControls(layout: TrafficGraphLayoutSnapshot, in bounds: CGRect) -> some View {
        HStack(spacing: 2) {
            Button {
                viewportIsUserControlled = true
                viewport.zoom(by: 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY))
            } label: {
                Image(systemName: "plus")
            }
            .help(L("Zoom in"))
            Button {
                viewportIsUserControlled = true
                viewport.zoom(by: 1 / 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY))
            } label: {
                Image(systemName: "minus")
            }
            .help(L("Zoom out"))
            Divider().frame(height: 16)
            Button(L("Fit")) {
                viewportIsUserControlled = false
                viewport.fit(content: layout.contentBounds, in: bounds)
            }
            .help(L("Fit the map in the window"))
            Button(L("Reset")) {
                viewportIsUserControlled = true
                viewport.reset()
            }
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

    private func edgeLayer(
        _ layout: TrafficGraphLayoutSnapshot,
        visible: TrafficGraphVisibleRegion
    ) -> some View {
        Canvas { context, _ in
            for edge in snapshot.edges where visible.edgeIDs.contains(edge.id) {
                guard let curve = layout.edgeCurves[edge.id] else { continue }
                let emphasized = TrafficGraphSelection.emphasizes(
                    edge,
                    selectedNode: selectedNode,
                    selectedEdge: selectedEdge,
                    hoveredEdge: hoveredEdge
                )
                let related = isEdgeRelated(edge)
                let baseOpacity = emphasized ? 0.92 : related ? 0.42 : 0.10
                if !edge.isTrafficRibbon {
                    let color = edge.relationship == .blocked ? FL.critical : FL.graphInvocation
                    let dash: [CGFloat] = edge.relationship == .blocked ? [3, 4] : [6, 5]
                    context.stroke(path(curve), with: .color(color.opacity(baseOpacity)),
                                   style: StrokeStyle(lineWidth: emphasized ? 2.5 : 1.5, lineCap: .round,
                                                      dash: dash))
                    continue
                }

                let counters = edge.displayedCounters
                let width = layout.edgeWidths[edge.id] ?? 1
                let ribbonColor = FL.muted.opacity(emphasized ? 0.44 : related ? 0.20 : 0.05)
                if curve.routingPoints.count >= 2 {
                    context.stroke(
                        path(curve),
                        with: .color(ribbonColor),
                        style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                    )
                } else {
                    context.fill(ribbonPath(curve, width: width), with: .color(ribbonColor))
                }
                guard emphasized, counters.total > 0 else { continue }

                let lanes = TrafficGraphFlowDash.lanes(counters: counters, totalWidth: width)
                if lanes.received.width > 0 {
                    if curve.routingPoints.count >= 2 {
                        context.stroke(
                            path(curve.offset(by: lanes.received.offset)),
                            with: .color(FL.graphReceived.opacity(0.88)),
                            style: StrokeStyle(lineWidth: lanes.received.width, lineCap: .round, lineJoin: .round)
                        )
                    } else {
                        context.fill(
                            ribbonPath(curve, width: lanes.received.width, offset: lanes.received.offset),
                            with: .color(FL.graphReceived.opacity(0.88))
                        )
                    }
                }
                if lanes.sent.width > 0 {
                    if curve.routingPoints.count >= 2 {
                        context.stroke(
                            path(curve.offset(by: lanes.sent.offset)),
                            with: .color(FL.graphSent.opacity(0.88)),
                            style: StrokeStyle(lineWidth: lanes.sent.width, lineCap: .round, lineJoin: .round)
                        )
                    } else {
                        context.fill(
                            ribbonPath(curve, width: lanes.sent.width, offset: lanes.sent.offset),
                            with: .color(FL.graphSent.opacity(0.88))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func flowDashLayer(
        _ layout: TrafficGraphLayoutSnapshot,
        visible: TrafficGraphVisibleRegion
    ) -> some View {
        if !reduceMotion {
            let edgeSpeeds = TrafficGraphFlowDash.speeds(
                for: snapshot.edges.filter(TrafficGraphFlowDash.animates).map(\.id)
            )
            TimelineView(.periodic(from: .now, by: TrafficGraphFlowDash.frameInterval)) { timeline in
                Canvas { context, _ in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for edge in snapshot.edges where TrafficGraphFlowDash.animates(edge)
                        && visible.edgeIDs.contains(edge.id) && isEdgeRelated(edge) {
                        guard let curve = layout.edgeCurves[edge.id],
                              let width = layout.edgeWidths[edge.id] else { continue }
                        let emphasized = TrafficGraphSelection.emphasizes(
                            edge,
                            selectedNode: selectedNode,
                            selectedEdge: selectedEdge,
                            hoveredEdge: hoveredEdge
                        )
                        let dashOpacity = emphasized ? 0.9 : 0.34
                        let lanes = TrafficGraphFlowDash.lanes(
                            counters: edge.displayedCounters,
                            totalWidth: width
                        )
                        if lanes.sent.width > 0 {
                            context.stroke(
                                path(curve.offset(by: TrafficGraphFlowDash.borderOffset(
                                    totalWidth: width,
                                    direction: .sent
                                ))),
                                with: .color(FL.graphSent.opacity(dashOpacity)),
                                style: flowDashStyle(
                                    at: time,
                                    edgeID: edge.id,
                                    direction: .sent,
                                    speed: edgeSpeeds[edge.id],
                                    lineWidth: TrafficGraphFlowDash.strokeWidth
                                )
                            )
                        }
                        if lanes.received.width > 0 {
                            context.stroke(
                                path(curve.offset(by: TrafficGraphFlowDash.borderOffset(
                                    totalWidth: width,
                                    direction: .received
                                ))),
                                with: .color(FL.graphReceived.opacity(dashOpacity)),
                                style: flowDashStyle(
                                    at: time,
                                    edgeID: edge.id,
                                    direction: .received,
                                    speed: edgeSpeeds[edge.id],
                                    lineWidth: TrafficGraphFlowDash.strokeWidth
                                )
                            )
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func flowDashStyle(
        at time: TimeInterval,
        edgeID: TrafficGraphEdgeID,
        direction: TrafficGraphFlowDirection,
        speed: CGFloat?,
        lineWidth: CGFloat
    ) -> StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .butt,
            lineJoin: .round,
            dash: TrafficGraphFlowDash.pattern,
            dashPhase: TrafficGraphFlowDash.phase(
                at: time,
                edgeID: edgeID,
                direction: direction,
                speed: speed
            )
        )
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
                .accessibilityAddTraits(selectedEdge == edge.id ? AccessibilityTraits.isSelected : [])
                .accessibilityFocused($accessibilityFocus, equals: .edge(edge.id))
            }
        }
    }

    private func edgeAccessibilityLabel(_ edge: TrafficGraphEdge) -> String {
        let source = snapshot.nodes.first { $0.id == edge.source }?.title ?? L("Source")
        let target = snapshot.nodes.first { $0.id == edge.target }?.title ?? L("Destination")
        if edge.relationship == .runs { return "\(source), \(L("Runs")), \(target)" }
        if edge.relationship == .launched { return "\(source), \(L("Started")), \(target)" }
        if edge.relationship == .routedThrough {
            let counters = edge.displayedCounters
            return "\(source), \(L("Observed route")), \(target), \(L("Received")) "
                + "\(ByteFormat.string(counters.bytesIn)), \(L("Sent")) \(ByteFormat.string(counters.bytesOut))"
        }
        if edge.relationship == .configuredGateway { return "\(source), \(L("Configured gateway")), \(target)" }
        if edge.relationship == .blocked {
            return L("%@ to %@, %lld blocked attempts", source, target, edge.enforcement?.count ?? 0)
        }
        if edge.relationship == .invoked { return "\(source), \(L("Invoked")), \(target)" }
        return L("%@ to %@, received %@, sent %@, %lld connections", source, target,
                 ByteFormat.string(edge.counters.bytesIn), ByteFormat.string(edge.counters.bytesOut),
                 edge.counters.flows)
    }

    private func select(_ edge: TrafficGraphEdgeID) {
        selectedEdge = edge
        selectedNode = nil
    }

    private func restoreAccessibilityFocus() {
        if let selectedEdge {
            accessibilityFocus = .edge(selectedEdge)
        } else if let selectedNode {
            accessibilityFocus = .node(selectedNode)
        }
    }

    private func isEdgeRelated(_ edge: TrafficGraphEdge) -> Bool {
        TrafficGraphSelection.isRelated(
            edge,
            selectedNode: selectedNode,
            selectedEdge: selectedEdge
        )
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
            if curve.routingPoints.count >= 2 {
                addRoundedRoute(curve.routingPoints, to: &path)
            } else {
                path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
            }
        }
    }

    private func addRoundedRoute(_ points: [CGPoint], to path: inout Path) {
        guard points.count > 2 else {
            path.addLines(Array(points.dropFirst()))
            return
        }
        let radius: CGFloat = 8
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let corner = points[index]
            let next = points[index + 1]
            let incomingLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outgoingLength = hypot(next.x - corner.x, next.y - corner.y)
            let incoming = min(radius, incomingLength / 2)
            let outgoing = min(radius, outgoingLength / 2)
            let before = CGPoint(
                x: corner.x + (previous.x - corner.x) * incoming / max(incomingLength, 0.001),
                y: corner.y + (previous.y - corner.y) * incoming / max(incomingLength, 0.001)
            )
            let after = CGPoint(
                x: corner.x + (next.x - corner.x) * outgoing / max(outgoingLength, 0.001),
                y: corner.y + (next.y - corner.y) * outgoing / max(outgoingLength, 0.001)
            )
            path.addLine(to: before)
            path.addQuadCurve(to: after, control: corner)
        }
        if let last = points.last { path.addLine(to: last) }
    }

    private func ribbonPath(_ curve: TrafficGraphCurve, width: CGFloat, offset: CGFloat = 0) -> Path {
        let top = curve.offset(by: offset - width / 2)
        let bottom = curve.offset(by: offset + width / 2)
        return Path { path in
            path.move(to: top.start)
            if top.routingPoints.count >= 2 {
                path.addLines(Array(top.routingPoints.dropFirst()))
            } else {
                path.addCurve(to: top.end, control1: top.control1, control2: top.control2)
            }
            path.addLine(to: bottom.end)
            if bottom.routingPoints.count >= 2 {
                path.addLines(Array(bottom.routingPoints.dropLast().reversed()))
            } else {
                path.addCurve(to: bottom.start, control1: bottom.control2, control2: bottom.control1)
            }
            path.closeSubpath()
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
            if node.kind == .app || node.kind == .agent || node.kind == .launcher || node.kind == .proxy {
                appContent
            } else {
                destinationContent
            }
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
        .accessibilityHint(node.isCollapsedGroup
                           ? L("Reveal the exact chart items in this group")
                           : L("Select to inspect this traffic"))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    private var appContent: some View {
        HStack(spacing: 9) {
            if node.isCollapsedGroup {
                Image(systemName: "square.grid.2x2")
                    .font(.title2)
                    .foregroundStyle(FL.accent)
                    .frame(width: 30, height: 30)
            } else {
                AppIconView(path: node.appPath, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(.caption.bold()).foregroundStyle(FL.ink).lineLimit(2)
                if let role = roleLabel {
                    Text(role).font(.caption2).foregroundStyle(FL.faint).lineLimit(1)
                }
            }
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

    private var roleLabel: String? {
        var labels = node.roleEvidence.map(\.detail)
        switch node.kind {
        case .launcher: labels.insert(L("Started agent"), at: 0)
        case .agent: labels.insert(L("Agent"), at: 0)
        case .proxy: labels.insert(node.detail, at: 0)
        default: break
        }
        let unique = labels.reduce(into: [String]()) { result, label in
            guard !label.isEmpty, !result.contains(label) else { return }
            result.append(label)
        }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    private var nodeIcon: String {
        if node.isCollapsedGroup { return "square.grid.2x2" }
        switch node.kind {
        case .service: return "sparkles"
        case .tool: return "hammer"
        case .mcp: return "shippingbox"
        default: return "network"
        }
    }

    private var accessibilityLabel: String {
        let title = roleLabel.map { "\(node.title), \($0)" } ?? node.title
        return L("%@, received %@, sent %@, %lld connections", title, ByteFormat.string(node.counters.bytesIn),
                 ByteFormat.string(node.counters.bytesOut), node.counters.flows)
    }
}

private struct TrafficGraphInspector: View {
    var selection: GraphSelection?
    var granularity: Granularity
    var onExpandEdgeGroup: ((TrafficGraphEdgeID) -> Void)? = nil
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
                Text(L("The map stays still while traffic values update. Moving dashes show direction and match received and sent traffic; use List for every relationship without motion."))
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
            ForEach(Array(node.roleEvidence.enumerated()), id: \.offset) { _, evidence in
                FLPill(text: evidence.detail, systemImage: "arrow.triangle.branch", color: FL.graphInvocation)
                if let configuration = evidence.configuration {
                    Text("\(configuration.endpoint) · \(configuration.sourceKey)")
                        .font(.caption).foregroundStyle(FL.muted)
                    Text(configuration.source).font(.caption2).foregroundStyle(FL.faint)
                }
            }
            if node.kind == .launcher {
                FLPill(text: L("Started"), systemImage: "terminal", color: FL.graphInvocation)
                Text(L("Capture-time process ancestry proves this application started the agent."))
                    .font(.callout).foregroundStyle(FL.muted)
            } else if node.kind == .proxy {
                FLPill(text: node.detail, systemImage: "arrow.triangle.branch", color: FL.graphInvocation)
                Text(node.detail == L("Configured gateway")
                     ? L("The agent's documented settings declare this gateway. This does not prove a request used it.")
                     : L("Capture-time proxy attribution proves this observed route segment."))
                    .font(.callout).foregroundStyle(FL.muted)
                if !node.counters.isEmpty { metrics(node.counters) }
            } else if node.counters.isEmpty {
                FLPill(text: L("Relationship evidence"), systemImage: "line.diagonal", color: FL.graphInvocation)
            } else {
                FLPill(text: L("Observed"), systemImage: "eye", color: FL.muted)
                metrics(node.counters)
            }
            Divider()
            if !node.isFilterExact {
                Text(L("Select a relationship for an exact Reports scope."))
                    .font(.callout)
                    .foregroundStyle(FL.muted)
            } else if node.kind == .launcher || node.kind == .proxy || node.counters.isEmpty {
                EmptyView()
            } else if !node.members.isEmpty && (node.filter.domainSuffix != nil || node.members.count > 1) {
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
                } else if let bundleID = node.filter.bundleID {
                    Button(L("Inspect")) {
                        nav.showInspect(app: (bundleID, node.title),
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
            FLPill(text: relationshipLabel(edge.relationship),
                   systemImage: relationshipIcon(edge.relationship),
                   color: edge.relationship == .blocked ? FL.critical
                    : edge.relationship == .observed ? FL.muted : FL.graphInvocation)
            if edge.isCollapsedGroup {
                Text(L("%lld exact items", Int64(edge.collapsedEdgeIDs.count)))
                    .font(.caption).foregroundStyle(FL.muted)
                if let onExpandEdgeGroup {
                    Button(L("Reveal the exact chart items in this group")) { onExpandEdgeGroup(edge.id) }
                }
            }
            if edge.isTrafficRibbon {
                metrics(edge.displayedCounters)
                if edge.relationship == .observed {
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
                    Text(relationshipExplanation(edge.relationship))
                        .font(.callout).foregroundStyle(FL.muted)
                }
            } else if edge.relationship == .blocked, let enforcement = edge.enforcement {
                metric(L("Blocked attempts"), enforcement.count.formatted(), FL.critical, "shield.slash")
                Text(enforcementSources(enforcement.source)).font(.callout.bold()).foregroundStyle(FL.ink)
                Text(enforcementCategories(enforcement.category)).font(.caption).foregroundStyle(FL.muted)
                if !enforcement.detail.isEmpty {
                    Text(enforcement.detail).font(.caption).foregroundStyle(FL.muted)
                }
            } else if edge.relationship == .configuredGateway, let configuration = edge.configuration {
                Text(relationshipExplanation(edge.relationship)).font(.callout).foregroundStyle(FL.muted)
                Divider()
                Text(configuration.endpoint).font(.callout.monospaced()).foregroundStyle(FL.ink)
                Text(L("Configured: %@", configuration.sourceKey)).font(.caption).foregroundStyle(FL.muted)
                Text(configuration.source).font(.caption2.monospaced()).foregroundStyle(FL.faint)
            } else {
                Text(relationshipExplanation(edge.relationship))
                    .font(.callout).foregroundStyle(FL.muted)
            }
            Spacer()
            legend
        }
    }

    private func enforcementSources(_ value: String) -> String {
        value.split(separator: ",").map { source in
            let token = source.trimmingCharacters(in: .whitespaces)
            if token == "ordinary-rule" { return L("Ordinary rule") }
            if token.hasPrefix("managed-pack:") {
                return L("Managed pack: %@", String(token.dropFirst("managed-pack:".count)))
            }
            return token
        }.joined(separator: ", ")
    }

    private func enforcementCategories(_ value: String) -> String {
        value.split(separator: ",").map { category in
            switch category.trimmingCharacters(in: .whitespaces).lowercased() {
            case "advertising": return L("Advertising")
            case "tracking": return L("Tracking")
            case "telemetry": return L("Telemetry")
            case "rule": return L("Rule")
            default: return String(category)
            }
        }.joined(separator: ", ")
    }

    private func relationshipLabel(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .observed: return L("Observed")
        case .runs: return L("Runs")
        case .launched: return L("Started")
        case .configuredGateway: return L("Configured gateway")
        case .routedThrough: return L("Observed route")
        case .blocked: return L("Blocked")
        case .invoked: return L("Invoked")
        }
    }

    private func relationshipIcon(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .observed: return "eye"
        case .runs: return "point.topleft.down.to.point.bottomright.curvepath"
        case .launched: return "terminal"
        case .configuredGateway: return "gearshape.2"
        case .routedThrough: return "arrow.triangle.branch"
        case .blocked: return "shield.slash"
        case .invoked: return "bolt"
        }
    }

    private func relationshipExplanation(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .runs:
            return L("Stored process lineage proves this agent runs the tool. It does not prove a tool invocation.")
        case .launched:
            return L("Capture-time process ancestry proves this application started the agent.")
        case .configuredGateway:
            return L("The agent's documented settings declare this gateway. This does not prove a request used it.")
        case .routedThrough:
            return L("Capture-time proxy attribution proves this observed route segment.")
        case .invoked:
            return L("Inspected request evidence proves this invocation.")
        case .blocked:
            return L("A policy stopped this attempt before it became observed traffic.")
        case .observed:
            return ""
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
            Label(L("Relationship evidence"), systemImage: "line.diagonal").foregroundStyle(FL.graphInvocation)
            Label(L("Blocked attempts"), systemImage: "shield.slash").foregroundStyle(FL.critical)
        }.font(.caption)
    }

}

private struct TrafficGraphList: View {
    var snapshot: TrafficGraphSnapshot
    var mode: VisualizeView.Mode
    @Binding var visibleCount: Int
    @Binding var selectedEdge: TrafficGraphEdgeID?
    @Binding var selectedNode: TrafficGraphNodeID?
    @AccessibilityFocusState private var accessibilityFocus: TrafficGraphAccessibilityFocus?

    private let columns = [
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 180), alignment: .leading),
        GridItem(.flexible(minimum: 100), alignment: .leading),
        GridItem(.flexible(minimum: 100), alignment: .leading),
        GridItem(.flexible(minimum: 105), alignment: .leading),
        GridItem(.flexible(minimum: 105), alignment: .leading)
    ]

    private var page: TrafficGraphListPage {
        TrafficGraphListPager.page(in: snapshot, visibleCount: visibleCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                header(mode == .traffic ? L("App") : L("Source")); header(L("Destination"))
                header(L("Received")); header(L("Sent")); header(L("Connections / attempts")); header(L("Status"))
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(page.edges) { edge in
                        row(edge)
                    }
                    ForEach(page.roleItems) { item in
                        roleRow(item)
                    }
                    if page.hasMore {
                        VStack(spacing: Spacing.s) {
                            Text(L("Showing %lld of %lld relationships", page.shownCount, page.totalCount))
                                .font(.caption)
                                .foregroundStyle(FL.muted)
                            Button(L("Show %lld more relationships", min(TrafficGraphListPager.pageSize,
                                                                         page.remainingCount))) {
                                showMore()
                            }
                            .buttonStyle(.link)
                            .accessibilityHint(L("Loads the next page without changing the Map"))
                            .accessibilityFocused($accessibilityFocus, equals: .more)
                        }
                        .padding(.vertical, Spacing.m)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(Spacing.l)
        .accessibilityLabel(L("Traffic connections"))
        .task {
            await Task.yield()
            restoreAccessibilityFocus()
        }
        .onChange(of: selectedNode) { _, _ in restoreAccessibilityFocus() }
        .onChange(of: selectedEdge) { _, _ in restoreAccessibilityFocus() }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(FL.muted)
    }

    private func roleRow(_ item: TrafficGraphRoleListItem) -> some View {
        Button {
            selectedNode = item.node.id
            selectedEdge = nil
        } label: {
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                Text(item.node.title)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.evidence.detail)
                    if let endpoint = item.evidence.configuration?.endpoint, !endpoint.isEmpty {
                        Text(endpoint).font(.caption2).foregroundStyle(FL.muted)
                    }
                }
                Text("—")
                Text("—")
                Text("—")
                Text(L("Relationship evidence"))
                    .foregroundStyle(FL.muted)
            }
            .font(.caption)
            .foregroundStyle(FL.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                selectedNode == item.node.id ? FL.accent.opacity(0.12) : FL.surfaceDeep,
                in: RoundedRectangle(cornerRadius: Radius.chip)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.node.title), \(item.evidence.detail), \(L("Relationship evidence"))")
        .accessibilityAddTraits(selectedNode == item.node.id ? AccessibilityTraits.isSelected : [])
        .accessibilityFocused($accessibilityFocus, equals: .role(item.id))
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
                Text(edge.isTrafficRibbon ? ByteFormat.string(edge.displayedCounters.bytesIn) : "—").monospacedDigit()
                Text(edge.isTrafficRibbon ? ByteFormat.string(edge.displayedCounters.bytesOut) : "—").monospacedDigit()
                Text(edge.isTrafficRibbon ? edge.displayedCounters.flows.formatted()
                     : edge.relationship == .blocked ? edge.enforcement?.count.formatted() ?? "0" : "—")
                    .monospacedDigit()
                FLPill(text: relationshipLabel(edge.relationship),
                       systemImage: relationshipIcon(edge.relationship),
                       color: edge.relationship == .blocked ? FL.critical
                        : edge.relationship == .observed ? FL.muted : FL.graphInvocation)
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedEdge == edge.id ? FL.accent.opacity(0.12) : FL.surfaceDeep,
                        in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibilityLabel(edge))
        .accessibilityAddTraits(selectedEdge == edge.id ? AccessibilityTraits.isSelected : [])
        .accessibilityFocused($accessibilityFocus, equals: .edge(edge.id))
    }

    private func node(_ id: TrafficGraphNodeID) -> TrafficGraphNode? { snapshot.nodes.first { $0.id == id } }

    private func select(_ edge: TrafficGraphEdge) {
        selectedEdge = edge.id
        selectedNode = nil
    }

    private func showMore() {
        let firstNewIndex = page.shownCount
        let nextCount = TrafficGraphListPager.nextVisibleCount(current: page.shownCount, total: page.totalCount)
        let nextPage = TrafficGraphListPager.page(in: snapshot, visibleCount: nextCount)
        visibleCount = nextCount
        if firstNewIndex < nextPage.edges.count {
            accessibilityFocus = .edge(nextPage.edges[firstNewIndex].id)
        } else {
            let roleIndex = firstNewIndex - nextPage.edges.count
            if nextPage.roleItems.indices.contains(roleIndex) {
                accessibilityFocus = .role(nextPage.roleItems[roleIndex].id)
            }
        }
    }

    private func restoreAccessibilityFocus() {
        let all = TrafficGraphListPager.page(in: snapshot, visibleCount: Int.max)
        let targetIndex: Int
        let target: TrafficGraphAccessibilityFocus
        if let selectedEdge, let index = all.edges.firstIndex(where: { $0.id == selectedEdge }) {
            targetIndex = index
            target = .edge(selectedEdge)
        } else if let selectedNode,
                  let index = all.roleItems.firstIndex(where: { $0.node.id == selectedNode }) {
            targetIndex = all.edges.count + index
            target = .role(all.roleItems[index].id)
        } else {
            return
        }
        let requiredCount = min(all.totalCount,
                                ((targetIndex / TrafficGraphListPager.pageSize) + 1) * TrafficGraphListPager.pageSize)
        visibleCount = max(visibleCount, requiredCount)
        accessibilityFocus = target
    }

    private func relationshipLabel(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .observed: return L("Observed")
        case .runs: return L("Runs")
        case .launched: return L("Started")
        case .configuredGateway: return L("Configured gateway")
        case .routedThrough: return L("Observed route")
        case .blocked: return L("Blocked")
        case .invoked: return L("Invoked")
        }
    }

    private func relationshipIcon(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .observed: return "eye"
        case .runs: return "point.topleft.down.to.point.bottomright.curvepath"
        case .launched: return "terminal"
        case .configuredGateway: return "gearshape.2"
        case .routedThrough: return "arrow.triangle.branch"
        case .blocked: return "shield.slash"
        case .invoked: return "bolt"
        }
    }

    private func rowAccessibilityLabel(_ edge: TrafficGraphEdge) -> String {
        let app = node(edge.source)?.title ?? L("App")
        let destination = node(edge.target)?.title ?? L("Destination")
        if edge.relationship == .blocked {
            return L("%@ to %@, %lld blocked attempts", app, destination, edge.enforcement?.count ?? 0)
        }
        if !edge.isTrafficRibbon {
            return "\(app), \(relationshipLabel(edge.relationship)), \(destination)"
        }
        let counters = edge.displayedCounters
        return "\(app), \(destination), \(relationshipLabel(edge.relationship)), "
            + "\(L("Received")) \(ByteFormat.string(counters.bytesIn)), "
            + "\(L("Sent")) \(ByteFormat.string(counters.bytesOut)), \(L("%lld connections", counters.flows))"
    }
}
