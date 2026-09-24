import SwiftUI

enum AgentWindow: String, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return "Last hour"
        case .day: return "24 hours"
        case .week: return "7 days"
        }
    }
    var interval: TimeInterval { self == .hour ? 3600 : self == .day ? 86400 : 7 * 86400 }
    var granularity: Granularity { self == .week ? .hour : .minute }
}

/// AI agents on this Mac: what they talk to besides their model provider, and how risky that looks.
struct AgentsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var focus: FocusStore
    @AppStorage("agents.window") private var window: AgentWindow = .day
    @State private var agents: [AgentSummary] = []
    @State private var agentAlerts = 0
    @State private var policies: [String: AgentPolicy] = [:]
    @State private var toolUsage: [String: [ToolUsage]] = [:]
    @State private var toolActivity: [String: [ToolActivity]] = [:]
    @State private var mcpServers: [String: [MCPServerSummary]] = [:]
    @State private var profiles: [String: AgentProfile] = [:]
    @ObservedObject private var workspaceStore = AgentWorkspaceStore.shared
    @State private var selection: AgentSummary.ID?
    @State private var sortOrder = [KeyPathComparator(\AgentSummary.riskScore, order: .reverse)]
    @State private var loaded = false

    private var selected: AgentSummary? { agents.first { $0.id == selection } ?? agents.first }

    var body: some View {
        GeometryReader { geometry in
            content(height: geometry.size.height)
        }
    }

    /// In a short window the summary tiles and the description give way to the table and the agent's detail, which
    /// are what the view is for. Without this the header is squeezed behind the title bar.
    private func content(height: CGFloat) -> some View {
        let roomy = height > 680
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if roomy {
                    Text("Every AI agent on this Mac, and where it sends data besides its model provider.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(AgentWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            .fixedSize(horizontal: false, vertical: true)
            if roomy { tiles.fixedSize(horizontal: false, vertical: true) }
            if agents.isEmpty && loaded {
                ContentUnavailableView {
                    Label("No AI agents seen", systemImage: "sparkles")
                } description: {
                    Text("Flowlight recognizes agents such as Claude Code, Codex, Cursor and Ollama, and any other app that calls an LLM API (Anthropic, OpenAI, Gemini, Mistral, OpenRouter and more).")
                }
                .frame(maxHeight: .infinity)
            } else {
                // Fit the table to its rows so the selected agent's detail gets the rest of the window.
                table.frame(minHeight: 180, maxHeight: max(180, CGFloat(agents.count) * 38 + 44))
                if let selected {
                    AgentDetail(agent: selected, window: window, toolCalls: toolUsage[selected.bundleID] ?? [],
                                activity: toolActivity[selected.bundleID] ?? [], servers: mcpServers[selected.bundleID] ?? [],
                                profile: profiles[selected.bundleID],
                                workspaces: workspaceStore.workspaces(bundleID: selected.bundleID, name: selected.name),
                                policy: policies[selected.bundleID] ?? AgentPolicy(agentID: selected.bundleID, enabled: false)) { policy in
                        policies[policy.agentID] = policy
                        monitor.savePolicy(policy)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("AI Agents")
        .task(id: LoadKey(window: window, version: monitor.dataVersion, focus: focus.scope)) { await load() }
    }

    private struct LoadKey: Equatable { var window: AgentWindow; var version: Int; var focus: FocusScope }

    private var tiles: some View {
        let ai = agents.reduce(FlowCounters()) { var c = $0; c += $1.ai; return c }
        let egress = agents.reduce(Int64(0)) { $0 + $1.egress.bytesOut }
        let risky = agents.filter { !$0.sensitiveProtocols.isEmpty }.count
        return HStack(spacing: 12) {
            StatTile(title: "Agents active", value: "\(agents.count)", systemImage: "sparkles")
            StatTile(title: "AI API traffic", value: ByteFormat.string(ai.total), systemImage: "brain")
            StatTile(title: "Uploaded to other hosts", value: ByteFormat.string(egress), systemImage: "arrow.up.forward.app",
                     tint: TrafficColors.outbound)
            StatTile(title: "Using sensitive channels", value: "\(risky)", systemImage: "exclamationmark.shield",
                     tint: risky > 0 ? TrafficColors.anomaly : .secondary)
            StatTile(title: "Agent alerts", value: "\(agentAlerts)", systemImage: "bell.badge",
                     tint: agentAlerts > 0 ? TrafficColors.anomaly : .secondary)
        }
    }

    private var table: some View {
        Table(agents.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Agent", value: \.name) { agent in
                HStack(spacing: 8) {
                    AppIconView(path: agent.appPath, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name).lineLimit(1)
                        Text(agent.vendor ?? "Detected: calls an AI API").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(agent.bundleID)
            }
            .width(min: 150, ideal: 190)
            TableColumn("AI providers") { agent in
                Text(agent.providers.map(\.name).joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)
            TableColumn("AI traffic", value: \.aiTotal) { Text(ByteFormat.string($0.ai.total)).monospacedDigit() }.width(80)
            TableColumn("Other hosts", value: \.otherCount) { Text("\($0.otherCount)").monospacedDigit() }.width(70)
            TableColumn("Sent elsewhere", value: \.egressOut) { agent in
                Text(ByteFormat.string(agent.egress.bytesOut)).monospacedDigit()
                    .foregroundStyle(agent.egressShare > 0.5 && agent.egress.bytesOut > 1_000_000 ? TrafficColors.outbound : .primary)
                    .help("\(ShareFormat.string(agent.egressShare)) of this agent's uploads went to non-AI hosts")
            }
            .width(90)
            TableColumn("Allowlist") { agent in AllowlistStatus(agent: agent, policy: policies[agent.bundleID]) }
                .width(min: 80, ideal: 110)
            TableColumn("Risk", value: \.riskScore) { agent in RiskBadges(agent: agent) }
                .width(min: 90, ideal: 160)
            TableColumn("Alerts", value: \.alerts) { agent in
                Text(agent.alerts == 0 ? "–" : "\(agent.alerts)").monospacedDigit()
                    .foregroundStyle(agent.alerts > 0 ? TrafficColors.anomaly : .secondary)
            }
            .width(50)
        }
        .contextMenu(forSelectionType: AgentSummary.ID.self) { ids in
            if let id = ids.first {
                Button("Show Traffic in Reports") { nav.showReport(filter: TrafficFilter(bundleID: id), granularity: window.granularity) }
                FocusMenuItems(app: (id, agents.first { $0.bundleID == id }?.name ?? id))
            }
        } primaryAction: { ids in
            if let id = ids.first { nav.showReport(filter: TrafficFilter(bundleID: id), granularity: window.granularity) }
        }
    }

    private func load() async {
        let (g, from, to) = (window.granularity, Date().addingTimeInterval(-window.interval), Date())
        let scope = focus.scope
        let result = try? await monitor.read { db -> ([BreakdownRow], [AlertRecord], [String: AgentPolicy], [HTTPExchange]) in
            (try db.breakdown(g, from: from, to: to, filter: TrafficFilter(focus: scope)),
             try db.alerts(limit: 2000, focus: scope).filter { $0.timestamp >= from }, try db.loadPolicies(),
             try db.exchanges(since: from, limit: 5000, focus: scope))
        }
        guard let (rows, alerts, loadedPolicies, exchanges) = result else { return }
        policies = loadedPolicies
        let activity = ToolActivityBuilder.activities(exchanges)
        toolActivity = activity
        toolUsage = ToolUsage.build(activity)
        let configured = Dictionary(grouping: rows.filter { !$0.mcpServer.isEmpty && !$0.parentAgent.isEmpty }) { $0.parentAgent }
            .mapValues { Array(Set($0.map(\.mcpServer))) }
        mcpServers = ToolActivityBuilder.servers(exchanges, activities: activity, configured: configured)
        profiles = ToolActivityBuilder.profiles(exchanges, activities: activity)
        let built = AgentsModel.build(rows: rows, alerts: alerts)
        agents = built
        let ids = Set(built.map(\.bundleID))
        agentAlerts = alerts.filter { AnomalyEngine.Kind.agentKinds.contains($0.kind) || ids.contains($0.bundleID) && $0.severity >= 2 }.count
        if selection == nil || !ids.contains(selection!) { selection = built.first?.id }
        loaded = true
    }
}

/// Status badges (icon + label, never color alone) for protocols an agent shouldn't casually use.
struct RiskBadges: View {
    var agent: AgentSummary

    var body: some View {
        HStack(spacing: 4) {
            if agent.sensitiveProtocols.isEmpty && !agent.hasUnnamedHost && !agent.hasLargeUpload {
                Text("None seen").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(agent.sensitiveProtocols.prefix(3), id: \.self) { proto in
                badge(proto.uppercased(), icon: icon(for: ProtocolCatalog.category(of: proto)), color: TrafficColors.anomaly)
            }
            if agent.hasLargeUpload {
                badge("Large upload", icon: "arrow.up.doc", color: .orange)
                    .help("\(ByteFormat.string(agent.egress.bytesOut)) sent to hosts that aren't AI providers")
            }
            if agent.hasUnnamedHost {
                badge("Raw IP", icon: "questionmark.circle", color: .orange)
                    .help("Connected to an address with no hostname")
            }
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.bold())
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func icon(for category: ProtocolCategory) -> String {
        switch category {
        case .mail: return "envelope"
        case .fileTransfer: return "doc.on.doc"
        case .remoteAccess: return "terminal"
        case .tunnel: return "network.badge.shield.half.filled"
        case .database: return "cylinder"
        case .peerToPeer: return "point.3.connected.trianglepath.dotted"
        default: return "exclamationmark.triangle"
        }
    }
}

extension AgentDestination {
    func isAllowed(by policy: AgentPolicy) -> Bool {
        policy.allows(host: hasHostname ? label : "", ip: ip, isAIProvider: provider != nil)
    }

    /// What "Allow" adds: the registrable domain, or the IP when no hostname was seen.
    var allowPattern: String { hasHostname ? AnomalyEngine.registrableDomain(label) : ip }
}

/// Table cell: whether an allowlist is on, and how many destinations break it.
struct AllowlistStatus: View {
    var agent: AgentSummary
    var policy: AgentPolicy?

    var body: some View {
        if let policy, policy.enabled {
            let violations = agent.otherDestinations.filter { !$0.isAllowed(by: policy) }.count
            HStack(spacing: 4) {
                if violations > 0 {
                    Label("\(violations) not allowed", systemImage: "xmark.octagon.fill")
                        .font(.caption.bold()).foregroundStyle(TrafficColors.anomaly)
                } else {
                    Label("All allowed", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                }
                if policy.enforce {
                    Image(systemName: "shield.lefthalf.filled").font(.caption2).foregroundStyle(.orange)
                        .help("Unlisted destinations are refused, not only reported")
                }
            }
        } else {
            Text("Off").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Edits one agent's allowlist: on/off, AI providers, blocking, patterns, presets.
struct AllowlistEditor: View {
    @EnvironmentObject var monitor: TrafficMonitor
    var agentName: String
    var policy: AgentPolicy
    var save: (AgentPolicy) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @State private var confirmBlocking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allowlist").font(.caption.bold()).foregroundStyle(.secondary)
            Toggle("Only allow listed destinations", isOn: Binding(get: { policy.enabled }, set: { var p = policy; p.enabled = $0; save(p) }))
                .font(.caption)
            Toggle("Always allow its AI providers", isOn: Binding(get: { policy.allowAIProviders }, set: { var p = policy; p.allowAIProviders = $0; save(p) }))
                .font(.caption)
                .disabled(!policy.enabled)
            if monitor.canBlock {
                // Turning this on is asked about; turning it off is not. Blocking is the change that can break
                // the agent, and it is never what an existing allowlist did before the user said so here.
                Toggle("Block connections that aren't allowed", isOn: Binding(
                    get: { policy.enforce },
                    set: { on in
                        if on { confirmBlocking = true } else { var p = policy; p.enforce = false; save(p) }
                    }))
                    .font(.caption)
                    .disabled(!policy.enabled)
                    .confirmationDialog("Let Flowlight block \(agentName)'s connections?", isPresented: $confirmBlocking) {
                        Button("Block Unlisted Destinations") { var p = policy; p.enforce = true; save(p) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("""
                        Until now this allowlist only raised alerts. From here on, anything \(agentName) or its tools \
                        contact that isn't listed will be refused, which can stop the agent from working. Local network, \
                        Apple services and Flowlight's own traffic are never blocked, and every refusal appears in Alerts.
                        """)
                    }
            } else if policy.enabled {
                BlockingUnavailableNotice(enforcing: policy.enforce)
            }
            if !policy.patterns.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(policy.patterns, id: \.self) { pattern in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
                                Text(pattern).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button { var p = policy; p.patterns.removeAll { $0 == pattern }; save(p) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(pattern)")
                            }
                        }
                    }
                }
                .frame(minHeight: min(CGFloat(policy.patterns.count) * 18, 72), maxHeight: 90)
            }
            HStack(spacing: 4) {
                TextField("github.com, 10.0.0.0/8…", text: $draft)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit(add)
                Button("Add", action: add).controlSize(.small).disabled(draft.isEmpty)
                Menu("Presets") {
                    ForEach(AgentPolicy.presets) { preset in
                        Button(preset.name) { add(patterns: preset.patterns) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Text(invalid ? "Enter a domain, IP address or CIDR range." : footer)
                .font(.caption2).foregroundStyle(invalid ? TrafficColors.anomaly : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        policy.enforce && monitor.canBlock
            ? "Anything else \(agentName) or its tools contact is refused, and the refusal is listed in Alerts."
            : "Anything else \(agentName) or its tools contact raises an alert. Flowlight doesn't block connections."
    }

    private func add() {
        guard let pattern = AgentPolicy.normalize(draft) else { invalid = true; return }
        invalid = false
        draft = ""
        add(patterns: [pattern])
    }

    private func add(patterns: [String]) {
        var p = policy
        for pattern in patterns where !p.patterns.contains(pattern) { p.patterns.append(pattern) }
        if !p.enabled && policy.patterns.isEmpty { p.enabled = true }   // adding the first entry turns it on
        save(p)
    }
}

struct AgentDetail: View {
    @EnvironmentObject var nav: AppNavigation
    var agent: AgentSummary
    var window: AgentWindow
    var toolCalls: [ToolUsage] = []
    var activity: [ToolActivity] = []
    var servers: [MCPServerSummary] = []
    var profile: AgentProfile?
    var workspaces: [AgentWorkspace] = []
    var policy: AgentPolicy
    var save: (AgentPolicy) -> Void
    @State private var tab = Tab.destinations

    enum Tab: Hashable { case destinations, calls, tools, servers }

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.tools.isEmpty || !toolCalls.isEmpty {
                        Text("Tools & MCP servers").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(toolCalls.prefix(6)) { usage in
                            Button { tab = .calls } label: {
                                HStack {
                                    Image(systemName: usage.isMCP ? "puzzlepiece.extension" : "wrench.and.screwdriver").foregroundStyle(.purple)
                                        .frame(width: 16)
                                    Text(usage.name).lineLimit(1)
                                    Spacer()
                                    if usage.errors > 0 {
                                        Text("\(usage.errors) failed").foregroundStyle(TrafficColors.anomaly)
                                    }
                                    Text("×\(usage.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help(usage.lastSummary.map { "Model asked for \(usage.name) \(usage.count)×. Most recent: \($0)" } ?? usage.name)
                        }
                        ForEach(agent.tools.prefix(8)) { tool in
                            HStack {
                                Image(systemName: tool.isMCP ? "puzzlepiece.extension" : "terminal").foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(tool.displayName).lineLimit(1)
                                Spacer()
                                Text("↑ \(ByteFormat.string(tool.counters.bytesOut))  ↓ \(ByteFormat.string(tool.counters.bytesIn))")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .help(tool.isMCP ? "MCP server started by \(agent.name)" : "Process started by \(agent.name), e.g. from a shell tool")
                        }
                        Divider().padding(.vertical, 2)
                    }
                    Text("AI providers").font(.caption.bold()).foregroundStyle(.secondary)
                    if agent.providers.isEmpty {
                        Text("None in this window").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(agent.providers, id: \.name) { provider in
                        HStack {
                            Image(systemName: "brain").foregroundStyle(.secondary)
                            Text(provider.name)
                            Spacer()
                            Text("↑ \(ByteFormat.string(provider.counters.bytesOut))  ↓ \(ByteFormat.string(provider.counters.bytesIn))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Divider().padding(.vertical, 2)
                    AllowlistEditor(agentName: agent.name, policy: policy, save: save)
                }
                .frame(width: 280, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        do {
                            Picker("Show", selection: $tab) {
                                Text("Destinations (\(agent.otherDestinations.count))").tag(Tab.destinations)
                                Text(activity.isEmpty ? "Tool calls" : "Tool calls (\(activity.count))").tag(Tab.calls)
                                Text(toolCount > 0 ? "Tools (\(toolCount))" : "Tools").tag(Tab.tools)
                                let mcpCount = servers.count + unusedServers.count
                                Text(mcpCount > 0 ? "MCP servers (\(mcpCount))" : "MCP servers").tag(Tab.servers)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                        }
                        Spacer()
                        Button("Open in Reports") {
                            nav.showReport(filter: TrafficFilter(bundleID: agent.bundleID), granularity: window.granularity)
                        }
                        .controlSize(.small)
                    }
                    switch tab {
                    case .destinations:
                        if agent.otherDestinations.isEmpty {
                            Text("Only AI providers. Nothing else was contacted.").font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(agent.otherDestinations.prefix(50)) { destination in
                                    destinationRow(destination)
                                }
                            }
                        }
                    case .calls:
                        if activity.isEmpty { InspectionHint(agent: agent.name, what: "the tool calls its model asks for") }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(activity.prefix(300)) { ToolActivityRow(activity: $0) }
                            }
                            .padding(.trailing, 6)
                        }
                    case .tools:
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                let tools = profile?.tools ?? []
                                if !tools.isEmpty {
                                    Text("Declared to the model · \(tools.filter { $0.used > 0 }.count) of \(tools.count) used in this window")
                                        .font(.caption.bold()).foregroundStyle(.secondary)
                                    ForEach(Array(tools.enumerated()), id: \.offset) { _, entry in
                                        DeclaredToolRow(tool: entry.tool, used: entry.used)
                                    }
                                }
                                ForEach(AgentCapability.Kind.allCases, id: \.self) { kind in
                                    let items = capabilities(kind)
                                    if !items.isEmpty {
                                        Divider().padding(.vertical, 2)
                                        HStack {
                                            Text(Self.sectionTitle(kind, count: items.count)).font(.caption.bold()).foregroundStyle(.secondary)
                                            Spacer()
                                            if kind == .permission, let summary = permissionSummary() {
                                                Text(summary).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        ForEach(items.prefix(kind == .permission ? 12 : 40)) { CapabilityRow(capability: $0) }
                                        if items.count > (kind == .permission ? 12 : 40) {
                                            Text("+\(items.count - (kind == .permission ? 12 : 40)) more").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                Divider().padding(.vertical, 2)
                                AgentSetupBar(agent: agent.name)
                            }
                            .padding(.trailing, 6)
                        }
                    case .servers:
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if servers.isEmpty && unusedServers.isEmpty {
                                    AgentSetupBar(agent: agent.name)
                                    InspectionHint(agent: agent.name, what: "the MCP servers it calls over the network")
                                }
                                ForEach(servers) { MCPServerRow(server: $0) }
                                ForEach(unusedServers, id: \.server.name) { entry in
                                    ConfiguredServerRow(server: entry.server, scope: entry.scope)
                                }
                            }
                            .padding(.trailing, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(agent.name) · \(ByteFormat.string(agent.total.total)) in \(window.title.lowercased())")
                if let profile, profile.requests > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(modelLine(profile)).foregroundStyle(.secondary)
                        .help("From inspected calls to \(profile.providerName ?? "the model provider")")
                    if profile.failures > 0 {
                        Text("· \(profile.failures) failed").foregroundStyle(TrafficColors.anomaly)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    /// Tools declared to the model, plus everything configured on disk.
    private var toolCount: Int {
        (profile?.tools.count ?? 0) + workspaces.reduce(0) { $0 + $1.capabilities.filter { $0.kind != .permission }.count }
    }

    /// Capabilities of one kind, the agent's own configuration before any project's.
    private func capabilities(_ kind: AgentCapability.Kind) -> [AgentCapability] {
        let all = workspaces.flatMap { $0.capabilities }.filter { $0.kind == kind }
        var seen = Set<String>()
        return all.filter { seen.insert($0.name + ($0.detail ?? "")).inserted }
            .sorted { a, b in
                // The agent's own configuration first, then anything sensitive, then by name.
                if a.isProject != b.isProject { return !a.isProject }
                if a.isSensitive != b.isSensitive { return a.isSensitive }
                return a.name < b.name
            }
    }

    private func permissionSummary() -> String? {
        let rules = workspaces.flatMap { $0.capabilities }.filter { $0.kind == .permission }
        guard !rules.isEmpty else { return nil }
        let counts = Dictionary(grouping: rules, by: { $0.detail ?? "allow" }).mapValues(\.count)
        return ["allow", "ask", "deny"].compactMap { decision in
            counts[decision].map { "\($0) \(decision)" }
        }.joined(separator: " · ")
    }

    /// MCP servers configured for this agent that haven't been seen in traffic.
    private var unusedServers: [(server: MCPServerConfig, scope: String)] {
        let known = Set(servers.map(\.id))
        var seen = Set<String>()
        return workspaces.flatMap { workspace in
            workspace.mcpServers.map { (server: $0, scope: workspace.root) }
        }
        .filter { !known.contains($0.server.name.lowercased()) && seen.insert($0.server.name.lowercased()).inserted }
    }

    static func sectionTitle(_ kind: AgentCapability.Kind, count: Int) -> String {
        switch kind {
        case .skill: return "Skills (\(count))"
        case .subagent: return "Subagents (\(count))"
        case .command: return "Slash commands (\(count))"
        case .hook: return "Hooks (\(count))"
        case .plugin: return "Plugins (\(count))"
        case .permission: return "Permission rules (\(count))"
        case .instructions: return "Instructions (\(count))"
        }
    }

    /// "claude-sonnet · 18 calls · 1.2M in / 24k out" from the agent's inspected requests.
    private func modelLine(_ profile: AgentProfile) -> String {
        var parts: [String] = []
        if let model = profile.models.max(by: { $0.requests < $1.requests })?.name {
            parts.append(profile.models.count > 1 ? "\(model) +\(profile.models.count - 1)" : model)
        }
        parts.append("\(profile.requests) \(profile.requests == 1 ? "call" : "calls")")
        if !profile.usage.isEmpty {
            var tokens = "\(Self.count(profile.usage.input)) in / \(Self.count(profile.usage.output)) out"
            if profile.usage.cacheRead > 0 { tokens += " · \(Self.count(profile.usage.cacheRead)) cached" }
            parts.append(tokens)
        }
        return parts.joined(separator: " · ")
    }

    static func count(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return "\(value / 1000)k"
        case 1_000...: return String(format: "%.1fk", Double(value) / 1000)
        default: return "\(value)"
        }
    }

    private func destinationRow(_ d: AgentDestination) -> some View {
        HStack(spacing: 6) {
            Image(systemName: d.isSensitive ? "exclamationmark.shield.fill" : d.isUnnamed ? "questionmark.circle" : "globe")
                .foregroundStyle(d.isSensitive ? TrafficColors.anomaly : d.isUnnamed ? .orange : .secondary)
            Text(d.label).lineLimit(1).truncationMode(.middle)
            if d.isUnnamed && d.label != d.ip { Text(d.ip).foregroundStyle(.secondary) }
            Text(d.protocols.joined(separator: ", ") + (d.ports.isEmpty ? "" : " · " + d.ports))
                .foregroundStyle(d.isSensitive ? TrafficColors.anomaly : .secondary).lineLimit(1)
            if !d.via.isEmpty {
                Text("via " + d.via.prefix(2).joined(separator: ", "))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
                    .help("Opened by " + d.via.joined(separator: ", "))
            }
            Spacer()
            if policy.enabled && !d.isAllowed(by: policy) {
                Text("Not allowed").font(.caption2.bold()).foregroundStyle(TrafficColors.anomaly)
                Button("Allow") {
                    var p = policy
                    if !p.patterns.contains(d.allowPattern) { p.patterns.append(d.allowPattern) }
                    save(p)
                }
                .controlSize(.mini)
                .help("Add \(d.allowPattern) to \(agent.name)'s allowlist")
            }
            Text("↑ \(ByteFormat.string(d.counters.bytesOut))  ↓ \(ByteFormat.string(d.counters.bytesIn))").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// How often the model asked an agent to run each tool, from inspected LLM responses.
struct ToolUsage: Identifiable, Equatable {
    var name: String
    var isMCP: Bool
    var count: Int
    var errors: Int
    var lastSummary: String?
    var lastAt: Date
    var id: String { name }

    /// Agent id → its tools, most used first.
    static func build(_ activities: [String: [ToolActivity]]) -> [String: [ToolUsage]] {
        activities.mapValues { list in
            var byName: [String: ToolUsage] = [:]
            for a in list.reversed() {   // oldest first, so "last" ends up newest
                var u = byName[a.call.displayName]
                    ?? ToolUsage(name: a.call.displayName, isMCP: a.call.mcpServer != nil, count: 0, errors: 0, lastSummary: nil, lastAt: a.at)
                u.count += 1
                if a.outcome == .error { u.errors += 1 }
                u.lastAt = a.at
                if let summary = a.call.summary { u.lastSummary = summary }
                byName[a.call.displayName] = u
            }
            return byName.values.sorted { ($0.count, $0.lastAt) > ($1.count, $1.lastAt) }
        }
    }
}

/// One tool call: what the model asked for, what came back, and the requests its tool made.
struct ToolActivityRow: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                outcomeIcon
                Image(systemName: activity.call.mcpServer == nil ? "wrench.and.screwdriver" : "puzzlepiece.extension")
                    .foregroundStyle(.purple)
                Text(activity.call.displayName).bold()
                Spacer()
                Text(activity.at, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            }
            if let summary = activity.call.summary ?? (activity.call.input.isEmpty ? nil : activity.call.input) {
                Text(summary).font(.caption.monospaced()).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(expanded ? 12 : 2).textSelection(.enabled)
            }
            if let result = activity.result, !result.output.isEmpty {
                Text(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption.monospaced())
                    .foregroundStyle(result.isError ? TrafficColors.anomaly : .secondary)
                    .lineLimit(expanded ? 20 : 2).textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
            if !activity.requests.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(activity.requests.prefix(4).enumerated()), id: \.offset) { _, r in
                        Text("→ \(r.method) \(r.host)\(r.status.map { " \($0)" } ?? "")")
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("\(r.via.map { "\($0): " } ?? "")\(r.method) \(r.host)\(r.path)")
                    }
                    if activity.requests.count > 4 { Text("+\(activity.requests.count - 4)").foregroundStyle(.secondary) }
                }
                .lineLimit(1)
            }
        }
        .font(.caption)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .help(expanded ? "Click to collapse" : "Click to show more of the command and output")
    }

    @ViewBuilder private var outcomeIcon: some View {
        switch activity.outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Completed")
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(TrafficColors.anomaly).help("The tool reported an error")
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary).help("No result seen yet")
        }
    }
}

/// One tool an agent declared to the model, and how often the model asked for it.
struct DeclaredToolRow: View {
    let tool: DeclaredTool
    let used: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(used > 0 ? .purple : .secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(tool.name).bold(used > 0)
                    if tool.kind != .function {
                        Text(tool.kind == .provider ? "runs at the provider" : "MCP server")
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let detail = tool.detail, !detail.isEmpty {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(used > 0 ? "×\(used)" : "unused").monospacedDigit()
                .foregroundStyle(used > 0 ? .primary : .tertiary)
        }
        .font(.caption)
        .opacity(used > 0 ? 1 : 0.75)
        .help(tool.kind == .provider ? "\(tool.name) runs on the provider's servers, not on this Mac" : (tool.detail ?? tool.name))
    }

    private var icon: String {
        switch tool.kind {
        case .function: return "wrench.and.screwdriver"
        case .provider: return "cloud"
        case .mcpToolset: return "puzzlepiece.extension"
        }
    }
}

/// An MCP server: where it runs, what it offers, what was used, and what the agent allowed.
struct MCPServerRow: View {
    let server: MCPServerSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.purple)
                Text(server.name).bold()
                if let version = server.version { Text(version).foregroundStyle(.secondary) }
                Text(kindLabel)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(kindHelp)
                if server.authorized {
                    Image(systemName: "key.fill").foregroundStyle(.secondary).help("The agent sent the provider a token for this server")
                }
                Spacer()
                if server.errors > 0 { Text("\(server.errors) failed").foregroundStyle(TrafficColors.anomaly) }
                Text(server.calls == 0 ? "no calls seen" : "\(server.calls) \(server.calls == 1 ? "call" : "calls")").foregroundStyle(.secondary)
            }
            if let endpoint = server.endpoint {
                Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let approval = server.approval {
                Text("Approval: \(approval)").foregroundStyle(approval == "never" ? TrafficColors.anomaly : .secondary)
                    .help(approval == "never" ? "The agent told the provider to run this server's tools without asking" : "")
            }
            if let allowed = server.allowedTools, !allowed.isEmpty {
                Text("Allowed: " + allowed.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(2)
            }
            if !server.tools.isEmpty {
                Text(toolList).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    .help("Tools this server offers; the ones with a count were called in this window")
            }
        }
        .font(.caption)
    }

    private var kindLabel: String {
        switch server.kind {
        case .local: return "local"
        case .remote: return "remote"
        case .provider: return "via provider"
        }
    }

    private var kindHelp: String {
        switch server.kind {
        case .local: return "Runs as a process on this Mac, started by the agent"
        case .remote: return "This Mac talks to it over HTTPS"
        case .provider: return "The provider connects to it for the agent; that traffic never reaches this Mac"
        }
    }

    private var toolList: String {
        let names = server.tools.prefix(24).map { name in server.used[name].map { "\(name) ×\($0)" } ?? name }
        return names.joined(separator: " · ") + (server.tools.count > 24 ? " · +\(server.tools.count - 24) more" : "")
    }
}

extension AgentCapability.Kind: CaseIterable {
    /// The order sections appear in the Tools tab.
    public static var allCases: [AgentCapability.Kind] { [.hook, .skill, .subagent, .command, .plugin, .instructions, .permission] }
}

/// One thing an agent is configured to do, read from its files on this Mac.
struct CapabilityRow: View {
    let capability: AgentCapability

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(capability.isSensitive ? TrafficColors.anomaly : .secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(capability.name).bold(capability.kind == .hook)
                    if capability.isProject {
                        Text("project").padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                }
                if let detail = capability.detail {
                    Text(detail).font(capability.kind == .hook ? .caption.monospaced() : .caption)
                        .foregroundStyle(capability.isSensitive ? TrafficColors.anomaly : .secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .help("\(capability.source)\(capability.kind == .hook ? " — runs automatically when this event fires" : "")")
    }

    private var icon: String {
        switch capability.kind {
        case .skill: return "book.closed"
        case .subagent: return "person.2"
        case .command: return "chevron.left.forwardslash.chevron.right"
        case .hook: return "bolt.horizontal.circle"
        case .plugin: return "shippingbox"
        case .permission: return "hand.raised"
        case .instructions: return "doc.text"
        }
    }
}

/// An MCP server an agent is configured to run, but which hasn't appeared in traffic.
struct ConfiguredServerRow: View {
    let server: MCPServerConfig
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                Text(server.name).bold()
                Text(server.url == nil ? "local" : "remote")
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
                Text("configured, no calls seen").foregroundStyle(.secondary)
            }
            Text(server.url?.absoluteString ?? ([server.command].compactMap { $0 } + server.args).joined(separator: " "))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(scope).font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .opacity(0.85)
    }
}

/// Explains what Flowlight reads on disk, and puts the person in charge of when and where.
struct AgentSetupBar: View {
    let agent: String
    @ObservedObject private var store = AgentWorkspaceStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading agent configuration…").foregroundStyle(.secondary)
                }
            } else if !store.hasScanned {
                Text("Flowlight can also list what \(agent) is set up with: its skills, subagents, slash commands, hooks and MCP servers. It reads those config files on this Mac and keeps only their names; nothing is sent anywhere.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Look for agent configuration") { store.refresh(force: true) }
                    Button("Why?") { openURL(Help.agentConfiguration) }.buttonStyle(.link)
                }
            } else {
                HStack(spacing: 8) {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    if store.isStale { Text("out of date").foregroundStyle(.orange) }
                    Button("Rescan") { store.refresh(force: true) }.controlSize(.small)
                    Button("Add project folder…") { pickFolder() }.controlSize(.small)
                }
                if !store.roots.isEmpty {
                    ForEach(store.roots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .lineLimit(1).truncationMode(.middle)
                            Button { store.removeRoot(root) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Stop scanning \(root.lastPathComponent)")
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .font(.caption)
    }

    private var summary: String {
        let folders = store.workspaces.count
        let when = store.scannedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never"
        return "\(folders) configuration \(folders == 1 ? "folder" : "folders") found · scanned \(when)"
    }

    /// Project folders are opened through a picker, so macOS grants access to that folder alone.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Pick a folder where your projects live. Flowlight looks for agent configuration inside it."
        if panel.runModal() == .OK, let url = panel.url { store.addRoot(url) }
    }
}

enum Help {
    static let base = URL(string: "https://flowlight.xinbetween.com/docs/")!
    static let agentConfiguration = URL(string: "https://flowlight.xinbetween.com/docs/#agent-configuration")!
    static let faq = URL(string: "https://flowlight.xinbetween.com/docs/#faq")!
    static let privacy = URL(string: "https://flowlight.xinbetween.com/privacy/")!
    static let issues = URL(string: "https://github.com/xinbetween/flowlight/issues")!
}

/// Shown where inspected data would be, when HTTPS inspection is off.
struct InspectionHint: View {
    let agent: String
    let what: String
    @EnvironmentObject private var nav: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Flowlight sees \(agent)'s connections, but not what's inside them. Turn on HTTPS inspection to see \(what).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Set up HTTPS inspection") { nav.selection = .inspect }
                .controlSize(.small)
        }
        .padding(.bottom, 4)
    }
}
