import SwiftUI

enum AgentWindow: String, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return L("Last hour")
        case .day: return L("24 hours")
        case .week: return L("7 days")
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
    /// Agents Flowlight actually decrypted something from in this window — not the same question as
    /// whether inspection is on, since an agent has to be routed through the proxy to be seen at all.
    @State private var inspectedAgents: Set<String> = []
    @ObservedObject private var workspaceStore = AgentWorkspaceStore.shared
    @State private var selection: AgentSummary.ID?
    @State private var sortOrder = [KeyPathComparator(\AgentSummary.riskScore, order: .reverse)]
    @State private var loaded = false

    private var selected: AgentSummary? { agents.first { $0.id == selection } ?? agents.first }

    /// The agents "always monitor" could offer to keep routed: known agents Flowlight can edit safely (they have a
    /// `configRecipe`) that are talking to an LLM provider, each paired with whether any of their traffic is actually
    /// being decrypted this window. The banner turns this into a suggestion or a "still not routed" note by comparing
    /// it against which agents are already monitored.
    private var monitorCandidates: [AlwaysMonitorBanner.Candidate] {
        var routedByName: [String: Bool] = [:]
        for agent in agents {
            guard let known = AgentCatalog.knownAgent(bundleID: agent.bundleID, appName: agent.name),
                  known.configRecipe != nil, !agent.providers.isEmpty else { continue }
            routedByName[known.name] = (routedByName[known.name] ?? false) || inspectedAgents.contains(agent.bundleID)
        }
        return routedByName.map { AlwaysMonitorBanner.Candidate(name: $0.key, routed: $0.value) }
            .sorted { $0.name < $1.name }
    }

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
            AlwaysMonitorBanner(inspection: monitor.inspection, candidates: monitorCandidates,
                                demo: DemoData.isEnabled && UserDefaults.standard.bool(forKey: "FLDemoBanner"))
            HStack {
                if roomy {
                    Text(L("Observed AI agent activity, including destinations outside each agent's model provider."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("Window"), selection: $window) {
                    ForEach(AgentWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            .fixedSize(horizontal: false, vertical: true)
            if roomy { tiles.fixedSize(horizontal: false, vertical: true) }
            if agents.isEmpty && loaded {
                ContentUnavailableView {
                    Label(L("No AI agents seen"), systemImage: "sparkles")
                } description: {
                    Text(L("Flowlight recognizes supported agents such as Claude Code, Codex, Cursor and Ollama. It also classifies non-browser apps that contact a known LLM API provider."))
                }
                .frame(maxHeight: .infinity)
            } else {
                // Fit the table to its rows so the selected agent's detail gets the rest of the window.
                table.frame(minHeight: 180, maxHeight: max(180, CGFloat(agents.count) * 38 + 44))
                if let selected {
                    AgentDetail(agent: selected, window: window, toolCalls: toolUsage[selected.bundleID] ?? [],
                                activity: toolActivity[selected.bundleID] ?? [], servers: mcpServers[selected.bundleID] ?? [],
                                profile: profiles[selected.bundleID], inspected: inspectedAgents.contains(selected.bundleID),
                                workspaces: workspaceStore.workspaces(bundleID: selected.bundleID, name: selected.name),
                                policy: policies[selected.bundleID] ?? AgentPolicy(agentID: selected.bundleID, enabled: false)) { policy in
                        policies[policy.agentID] = policy
                        monitor.savePolicy(policy)
                    }
                }
            }
        }
        .padding()
        .navigationTitle(L("AI Agents"))
        .task(id: LoadKey(window: window, version: monitor.dataVersion, focus: focus.scope)) { await load() }
    }

    private struct LoadKey: Equatable { var window: AgentWindow; var version: Int; var focus: FocusScope }

    private var tiles: some View {
        let ai = agents.reduce(FlowCounters()) { var c = $0; c += $1.ai; return c }
        let egress = agents.reduce(Int64(0)) { $0 + $1.egress.bytesOut }
        let risky = agents.filter { !$0.sensitiveProtocols.isEmpty }.count
        return HStack(spacing: 12) {
            StatTile(title: L("Agents active"), value: "\(agents.count)", systemImage: "sparkles")
            StatTile(title: L("AI API traffic"), value: ByteFormat.string(ai.total), systemImage: "brain")
            StatTile(title: L("Uploaded to other hosts"), value: ByteFormat.string(egress), systemImage: "arrow.up.forward.app",
                     tint: TrafficColors.outbound)
            StatTile(title: L("Using sensitive channels"), value: "\(risky)", systemImage: "exclamationmark.shield",
                     tint: risky > 0 ? TrafficColors.anomaly : .secondary)
            StatTile(title: L("Agent alerts"), value: "\(agentAlerts)", systemImage: "bell.badge",
                     tint: agentAlerts > 0 ? TrafficColors.anomaly : .secondary)
        }
    }

    private var table: some View {
        Table(agents.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Agent"), value: \.name) { agent in
                HStack(spacing: 8) {
                    AppIconView(path: agent.appPath, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name).lineLimit(1)
                        Text(agent.vendor ?? L("Detected: calls an AI API")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(agent.bundleID)
            }
            .width(min: 150, ideal: 190)
            TableColumn(L("AI providers")) { agent in
                Text(agent.providers.map(\.name).joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)
            TableColumn(L("AI traffic"), value: \.aiTotal) { Text(ByteFormat.string($0.ai.total)).monospacedDigit() }.width(80)
            TableColumn(L("Other hosts"), value: \.otherCount) { Text("\($0.otherCount)").monospacedDigit() }.width(70)
            TableColumn(L("Sent elsewhere"), value: \.egressOut) { agent in
                Text(ByteFormat.string(agent.egress.bytesOut)).monospacedDigit()
                    .foregroundStyle(agent.egressShare > 0.5 && agent.egress.bytesOut > 1_000_000 ? TrafficColors.outbound : .primary)
                    .help(L("%@ of this agent's uploads went to non-AI hosts", ShareFormat.string(agent.egressShare)))
            }
            .width(90)
            TableColumn(L("Allowlist")) { agent in AllowlistStatus(agent: agent, policy: policies[agent.bundleID]) }
                .width(min: 80, ideal: 110)
            TableColumn(L("Risk"), value: \.riskScore) { agent in RiskBadges(agent: agent) }
                .width(min: 90, ideal: 160)
            TableColumn(L("Alerts"), value: \.alerts) { agent in
                Text(agent.alerts == 0 ? "–" : "\(agent.alerts)").monospacedDigit()
                    .foregroundStyle(agent.alerts > 0 ? TrafficColors.anomaly : .secondary)
            }
            .width(50)
        }
        .contextMenu(forSelectionType: AgentSummary.ID.self) { ids in
            if let id = ids.first {
                Button(L("Show Traffic in Reports")) { nav.showReport(filter: TrafficFilter(bundleID: id), granularity: window.granularity) }
                InspectMenuItems(app: (id, agents.first { $0.bundleID == id }?.name ?? id))
                FocusMenuItems(app: (id, agents.first { $0.bundleID == id }?.name ?? id))
                Divider()
                RuleMenuItems(app: (id, agents.first { $0.bundleID == id }?.name ?? id))
                if let known = AgentCatalog.knownAgent(bundleID: id, appName: agents.first { $0.bundleID == id }?.name ?? id),
                   known.configRecipe != nil {
                    Divider()
                    if monitor.inspection.monitoredAgents.contains(known.name) {
                        Button(L("Stop Monitoring %@", known.name)) { monitor.inspection.setAlwaysMonitor(false, agent: known.name) }
                    } else {
                        Button(L("Always Monitor %@", known.name)) { monitor.inspection.setAlwaysMonitor(true, agent: known.name) }
                    }
                }
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
        inspectedAgents = Set(exchanges.compactMap(\.agent))
        let built = AgentsModel.build(rows: rows, alerts: alerts)
        agents = built
        let ids = Set(built.map(\.bundleID))
        agentAlerts = alerts.filter { AnomalyEngine.Kind.agentKinds.contains($0.kind) || ids.contains($0.bundleID) && $0.severity >= 2 }.count
        if selection == nil || !ids.contains(selection!) { selection = built.first?.id }
        loaded = true
    }
}

/// The one-click way to keep a supported agent routed through Flowlight for good.
///
/// When inspection is on but a known, editable agent (today: Claude Code) is reaching its model provider directly —
/// its traffic isn't being decrypted — this offers to add the proxy to the agent's own settings file, so it routes
/// through Flowlight on every launch without being relaunched by hand. It is honest about the two ways this can sit:
/// a suggestion for an agent going direct, and a "still not routed" note for one already asked-for but not yet seen
/// (it may pin its certificates, or a shell variable may be overriding the file).
struct AlwaysMonitorBanner: View {
    @ObservedObject var inspection: InspectionController
    let candidates: [Candidate]
    /// Marketing-screenshot mode: real inspection state doesn't exist under the demo database, so show a
    /// representative banner with sample agents. Set only by the screenshot launch argument.
    var demo: Bool = false
    @State private var dismissedSuggestions: Set<String> = []
    /// The monitored set the "monitoring" tip was last closed for. The tip shows whenever the current set differs
    /// from it — so closing hides it until the set changes (a new agent monitored), then it comes back on its own.
    /// Keyed by the set rather than a flag so no separate change-watching is needed.
    @State private var dismissedFor: Set<String> = []

    struct Candidate: Equatable { var name: String; var routed: Bool }

    /// Going direct, not yet asked to be monitored, and not dismissed this session: worth offering.
    private var suggestions: [String] {
        candidates.filter { !$0.routed && !inspection.monitoredAgents.contains($0.name) && !dismissedSuggestions.contains($0.name) }
            .map(\.name)
    }

    /// Every agent the user chose to always monitor, so the tip can always say what is being kept routed.
    private var monitored: [String] { inspection.monitoredAgents.sorted() }

    /// Monitored agents whose traffic still isn't being decrypted — the honest "written, but not routed" note.
    private var notRouted: Set<String> {
        Set(candidates.filter { !$0.routed && inspection.monitoredAgents.contains($0.name) }.map(\.name))
    }

    var body: some View {
        if demo {
            card { demoContent }
        } else {
            let showSuggestions = inspection.enabled && inspection.running && !suggestions.isEmpty
            let showMonitoring = inspection.enabled && !monitored.isEmpty && dismissedFor != Set(monitored)
            if showSuggestions || showMonitoring {
                card {
                    if showSuggestions { ForEach(suggestions, id: \.self) { name in suggestion(name) } }
                    if showMonitoring { monitoringTip }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25)))
    }

    /// A representative banner for the marketing screenshot: one agent to offer, two already monitored (one not yet
    /// routed). Buttons are inert — nothing is really being monitored under the demo database.
    private var demoContent: some View {
        Group {
            suggestion("Windsurf")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text(L("Flowlight is keeping these agents routed through it on every launch."))
                        .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                monitoredRow("Claude Code", notRouted: false)
                monitoredRow("Cursor", notRouted: true)
            }
        }
    }

    /// Always shown while agents are monitored, until closed by hand. Lists each one with a one-click stop, and
    /// flags any that were written to their settings file but still aren't routed.
    private var monitoringTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                Text(L("Flowlight is keeping these agents routed through it on every launch."))
                    .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { dismissedFor = Set(monitored) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Hide this until the monitored agents change"))
            }
            ForEach(monitored, id: \.self) { name in
                monitoredRow(name, notRouted: notRouted.contains(name)) { inspection.setAlwaysMonitor(false, agent: name) }
            }
        }
    }

    private func monitoredRow(_ name: String, notRouted: Bool, stop: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text(name)
            if notRouted {
                Text(L("· not routed yet — it may pin its certificates, or a shell setting may override the file"))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("Stop Monitoring"), action: stop).controlSize(.small)
        }
    }

    private func suggestion(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("%@ is reaching its model provider directly, so Flowlight can't see what it sends.", name))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Always monitor it to add the proxy to %@'s own settings, so it routes through Flowlight on every launch. Flowlight removes this again when inspection is off.", name))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Always Monitor %@", name)) { inspection.setAlwaysMonitor(true, agent: name) }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    Button(L("Not Now")) { dismissedSuggestions.insert(name) }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Status badges (icon + label, never color alone) for protocols an agent shouldn't casually use.
struct RiskBadges: View {
    var agent: AgentSummary

    var body: some View {
        HStack(spacing: 4) {
            if agent.sensitiveProtocols.isEmpty && !agent.hasUnnamedHost && !agent.hasLargeUpload {
                Text(L("None seen")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(agent.sensitiveProtocols.prefix(3), id: \.self) { proto in
                badge(proto.uppercased(), icon: icon(for: ProtocolCatalog.category(of: proto)), color: TrafficColors.anomaly)
            }
            if agent.hasLargeUpload {
                badge(L("Large upload"), icon: "arrow.up.doc", color: .orange)
                    .help(L("%@ sent to hosts that aren't AI providers", ByteFormat.string(agent.egress.bytesOut)))
            }
            if agent.hasUnnamedHost {
                badge(L("Raw IP"), icon: "questionmark.circle", color: .orange)
                    .help(L("Connected to an address with no hostname"))
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
                    Label(L("%lld not allowed", violations), systemImage: "xmark.octagon.fill")
                        .font(.caption.bold()).foregroundStyle(TrafficColors.anomaly)
                } else {
                    Label(L("All allowed"), systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                }
                if policy.enforce {
                    Image(systemName: "shield.lefthalf.filled").font(.caption2).foregroundStyle(.orange)
                        .help(L("Unlisted destinations are refused, not only reported"))
                }
            }
        } else {
            Text(L("Off")).font(.caption).foregroundStyle(.secondary)
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
            Text(L("Allowlist")).font(.caption.bold()).foregroundStyle(.secondary)
            Toggle(L("Only allow listed destinations"), isOn: Binding(get: { policy.enabled }, set: { var p = policy; p.enabled = $0; save(p) }))
                .font(.caption)
            Toggle(L("Always allow its AI providers"), isOn: Binding(get: { policy.allowAIProviders }, set: { var p = policy; p.allowAIProviders = $0; save(p) }))
                .font(.caption)
                .disabled(!policy.enabled)
            if monitor.canBlock {
                // Turning this on is asked about; turning it off is not. Blocking is the change that can break
                // the agent, and it is never what an existing allowlist did before the user said so here.
                Toggle(L("Block connections that aren't allowed"), isOn: Binding(
                    get: { policy.enforce },
                    set: { on in
                        if on { confirmBlocking = true } else { var p = policy; p.enforce = false; save(p) }
                    }))
                    .font(.caption)
                    .disabled(!policy.enabled)
                    .confirmationDialog(L("Let Flowlight block %@'s connections?", agentName), isPresented: $confirmBlocking) {
                        Button(L("Block Unlisted Destinations")) { var p = policy; p.enforce = true; save(p) }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L("Until now this allowlist only raised alerts. From here on, anything %@ or its tools contact that isn't listed will be refused, which can stop the agent from working. Local network, Apple services and Flowlight's own traffic are never blocked, and every refusal appears in Alerts.", agentName))
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
                                .accessibilityLabel(L("Remove %@", pattern))
                            }
                        }
                    }
                }
                .frame(minHeight: min(CGFloat(policy.patterns.count) * 18, 72), maxHeight: 90)
            }
            HStack(spacing: 4) {
                TextField(L("github.com, 10.0.0.0/8…"), text: $draft)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit(add)
                Button(L("Add"), action: add).controlSize(.small).disabled(draft.isEmpty)
                Menu(L("Presets")) {
                    ForEach(AgentPolicy.presets) { preset in
                        Button(preset.localizedName) { add(patterns: preset.patterns) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Text(invalid ? L("Enter a domain, IP address or CIDR range.") : footer)
                .font(.caption2).foregroundStyle(invalid ? TrafficColors.anomaly : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        policy.enforce && monitor.canBlock
            ? L("Anything else %@ or its tools contact is refused, and the refusal is listed in Alerts.", agentName)
            : L("Anything else %@ or its tools contact raises an alert. Flowlight doesn't block connections.", agentName)
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
    @EnvironmentObject var monitor: TrafficMonitor
    var agent: AgentSummary
    var window: AgentWindow
    var toolCalls: [ToolUsage] = []
    var activity: [ToolActivity] = []
    var servers: [MCPServerSummary] = []
    var profile: AgentProfile?
    /// True when at least one of this agent's requests was decrypted in this window.
    var inspected = false
    var workspaces: [AgentWorkspace] = []
    var policy: AgentPolicy
    var save: (AgentPolicy) -> Void
    @State private var tab = Tab.fromLaunchArgument

    enum Tab: Hashable {
        case destinations, calls, tools, servers, guardrails

        /// `-FLAgentTab tools`, for the screenshots. The default is what someone actually opens on.
        static var fromLaunchArgument: Tab {
            switch UserDefaults.standard.string(forKey: "FLAgentTab") {
            case "calls": return .calls
            case "tools": return .tools
            case "servers": return .servers
            case "guardrails": return .guardrails
            default: return .destinations
            }
        }
    }

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.tools.isEmpty || !toolCalls.isEmpty {
                        Text(L("Tools & MCP servers")).font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(toolCalls.prefix(6)) { usage in
                            Button { tab = .calls } label: {
                                HStack {
                                    Image(systemName: usage.isMCP ? "puzzlepiece.extension" : "wrench.and.screwdriver").foregroundStyle(.purple)
                                        .frame(width: 16)
                                    Text(usage.name).lineLimit(1)
                                    Spacer()
                                    if usage.errors > 0 {
                                        Text(L("%lld failed", usage.errors)).foregroundStyle(TrafficColors.anomaly)
                                    }
                                    Text("×\(usage.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help(usage.lastSummary.map { L("Model asked for %@ %lld×. Most recent: %@", usage.name, usage.count, $0) } ?? usage.name)
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
                            .help(tool.isMCP ? L("MCP server started by %@", agent.name)
                                             : L("Process started by %@, e.g. from a shell tool", agent.name))
                        }
                        Divider().padding(.vertical, 2)
                    }
                    Text(L("AI providers")).font(.caption.bold()).foregroundStyle(.secondary)
                    if agent.providers.isEmpty {
                        Text(L("None in this window")).font(.caption).foregroundStyle(.secondary)
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
                            Picker(L("Show"), selection: $tab) {
                                Text(L("Destinations (%lld)", agent.otherDestinations.count)).tag(Tab.destinations)
                                Text(activity.isEmpty ? L("Tool calls") : L("Tool calls (%lld)", activity.count)).tag(Tab.calls)
                                Text(toolCount > 0 ? L("Tools (%lld)", toolCount) : L("Tools")).tag(Tab.tools)
                                let mcpCount = servers.count + unusedServers.count
                                Text(mcpCount > 0 ? L("MCP servers (%lld)", mcpCount) : L("MCP servers")).tag(Tab.servers)
                                Text(L("Guardrails")).tag(Tab.guardrails)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                        }
                        Spacer()
                        Button(L("Open in Reports")) {
                            nav.showReport(filter: TrafficFilter(bundleID: agent.bundleID), granularity: window.granularity)
                        }
                        .controlSize(.small)
                    }
                    switch tab {
                    case .destinations:
                        if agent.otherDestinations.isEmpty {
                            Text(L("Only AI providers. Nothing else was contacted.")).font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(agent.otherDestinations.prefix(50)) { destination in
                                    destinationRow(destination)
                                }
                            }
                        }
                    case .calls:
                        if activity.isEmpty {
                            InspectionHint(inspection: monitor.inspection, agent: agent.name,
                                           what: L("the tool calls its model asks for"), subject: L("tool calls"),
                                           seen: inspected, reaching: agent.providers.first?.name,
                                           bundleID: agent.bundleID, appPath: agent.appPath)
                        }
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
                                    Text(L("Declared to the model · %lld of %lld used in this window",
                                           tools.filter { $0.used > 0 }.count, tools.count))
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
                                            Text(L("+%lld more", items.count - (kind == .permission ? 12 : 40)))
                                                .font(.caption).foregroundStyle(.tertiary)
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
                                    InspectionHint(inspection: monitor.inspection, agent: agent.name,
                                                   what: L("the MCP servers it calls over the network"),
                                                   subject: L("MCP servers reached over the network"),
                                                   seen: inspected, reaching: agent.providers.first?.name,
                                                   bundleID: agent.bundleID, appPath: agent.appPath)
                                }
                                ForEach(servers) { MCPServerRow(server: $0) }
                                ForEach(unusedServers, id: \.server.name) { entry in
                                    ConfiguredServerRow(server: entry.server, scope: entry.scope)
                                }
                                // After the servers, because the question "what can I stop it reaching?" only
                                // arises once you have seen what it is.
                                if !servers.isEmpty || !unusedServers.isEmpty {
                                    Divider().padding(.vertical, 4)
                                    MCPDomainsSection(
                                        agent: agent,
                                        entries: MCPDomains.collect(seen: servers,
                                                                    configured: unusedServers.map(\.server),
                                                                    destinations: agent.otherDestinations))
                                }
                            }
                            .padding(.trailing, 6)
                        }
                    case .guardrails:
                        GuardrailsPane(store: monitor.guardrails, agentKey: agent.bundleID, agentName: agent.name,
                                       declared: profile?.tools.map(\.tool) ?? [],
                                       servers: Array(Set(servers.map(\.name) + unusedServers.map(\.server.name))).sorted())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack(spacing: 6) {
                // Not lowercased: the title is already translated, and lowercasing a translated word is an English habit
// that German nouns don't survive. It is a no-op in Chinese, Japanese and Korean anyway.
                Text(L("%@ · %@ in %@", agent.name, ByteFormat.string(agent.total.total), window.title))
                if let profile, profile.requests > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(modelLine(profile)).foregroundStyle(.secondary)
                        .help(L("From inspected calls to %@", profile.providerName ?? L("the model provider")))
                    if profile.failures > 0 {
                        Text("· " + L("%lld failed", profile.failures)).foregroundStyle(TrafficColors.anomaly)
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
        case .skill: return L("Skills (%lld)", count)
        case .subagent: return L("Subagents (%lld)", count)
        case .command: return L("Slash commands (%lld)", count)
        case .hook: return L("Hooks (%lld)", count)
        case .plugin: return L("Plugins (%lld)", count)
        case .permission: return L("Permission rules (%lld)", count)
        case .instructions: return L("Instructions (%lld)", count)
        }
    }

    /// "claude-sonnet · 18 calls · 1.2M in / 24k out" from the agent's inspected requests.
    private func modelLine(_ profile: AgentProfile) -> String {
        var parts: [String] = []
        if let model = profile.models.max(by: { $0.requests < $1.requests })?.name {
            parts.append(profile.models.count > 1 ? "\(model) +\(profile.models.count - 1)" : model)
        }
        parts.append(profile.requests == 1 ? L("%lld call", profile.requests) : L("%lld calls", profile.requests))
        if !profile.usage.isEmpty {
            let input = Self.count(profile.usage.input), output = Self.count(profile.usage.output)
            parts.append(profile.usage.cacheRead > 0
                ? L("%@ tokens in / %@ out · %@ cached", input, output, Self.count(profile.usage.cacheRead))
                : L("%@ tokens in / %@ out", input, output))
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
                Text(L("via %@", d.via.prefix(2).joined(separator: ", ")))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
                    .help(L("Opened by %@", d.via.joined(separator: ", ")))
            }
            Spacer()
            if policy.enabled && !d.isAllowed(by: policy) {
                Text(L("Not allowed")).font(.caption2.bold()).foregroundStyle(TrafficColors.anomaly)
                Button(L("Allow")) {
                    var p = policy
                    if !p.patterns.contains(d.allowPattern) { p.patterns.append(d.allowPattern) }
                    save(p)
                }
                .controlSize(.mini)
                .help(L("Add %@ to %@'s allowlist", d.allowPattern, agent.name))
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
        .help(expanded ? L("Click to collapse") : L("Click to show more of the command and output"))
    }

    @ViewBuilder private var outcomeIcon: some View {
        switch activity.outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L("Completed"))
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(TrafficColors.anomaly).help(L("The tool reported an error"))
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary).help(L("No result seen yet"))
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
                        Text(tool.kind == .provider ? L("runs at the provider") : L("MCP server"))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let detail = tool.detail, !detail.isEmpty {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(used > 0 ? "×\(used)" : L("unused")).monospacedDigit()
                .foregroundStyle(used > 0 ? .primary : .tertiary)
        }
        .font(.caption)
        .opacity(used > 0 ? 1 : 0.75)
        .help(tool.kind == .provider ? L("%@ runs on the provider's servers, not on this Mac", tool.name)
                                     : (tool.detail ?? tool.name))
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
                    Image(systemName: "key.fill").foregroundStyle(.secondary).help(L("The agent sent the provider a token for this server"))
                }
                Spacer()
                if server.errors > 0 { Text(L("%lld failed", server.errors)).foregroundStyle(TrafficColors.anomaly) }
                Text(server.calls == 0 ? L("no calls seen")
                     : server.calls == 1 ? L("%lld call", server.calls) : L("%lld calls", server.calls))
                    .foregroundStyle(.secondary)
            }
            if let endpoint = server.endpoint {
                Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let approval = server.approval {
                Text(L("Approval: %@", approval)).foregroundStyle(approval == "never" ? TrafficColors.anomaly : .secondary)
                    .help(approval == "never" ? L("The agent told the provider to run this server's tools without asking") : "")
            }
            if let allowed = server.allowedTools, !allowed.isEmpty {
                Text(L("Allowed: %@", allowed.joined(separator: " · "))).foregroundStyle(.secondary).lineLimit(2)
            }
            if !server.tools.isEmpty {
                Text(toolList).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    .help(L("Tools this server offers; the ones with a count were called in this window"))
            }
        }
        .font(.caption)
    }

    private var kindLabel: String {
        switch server.kind {
        case .local: return L("local")
        case .remote: return L("remote")
        case .provider: return L("via provider")
        }
    }

    private var kindHelp: String {
        switch server.kind {
        case .local: return L("Runs as a process on this Mac, started by the agent")
        case .remote: return L("This Mac talks to it over HTTPS")
        case .provider: return L("The provider connects to it for the agent; that traffic never reaches this Mac")
        }
    }

    private var toolList: String {
        let names = server.tools.prefix(24).map { name in server.used[name].map { "\(name) ×\($0)" } ?? name }
        var list = names.joined(separator: " · ")
        if server.tools.count > 24 { list += " · " + L("+%lld more", server.tools.count - 24) }
        return list
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
                        Text(L("project")).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
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
        .help(capability.kind == .hook ? L("%@ — runs automatically when this event fires", capability.source)
                                       : capability.source)
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
                Text(server.url == nil ? L("local") : L("remote"))
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
                Text(L("configured, no calls seen")).foregroundStyle(.secondary)
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
                    Text(L("Reading agent configuration…")).foregroundStyle(.secondary)
                }
            } else if !store.hasScanned {
                Text(L("Flowlight can also list what %@ is set up with: its skills, subagents, slash commands, hooks and MCP servers. It reads those config files on this Mac and keeps only their names; nothing is sent anywhere.", agent))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Look for agent configuration")) { store.refresh(force: true) }
                    Button(L("Why?")) { openURL(Help.agentConfiguration) }.buttonStyle(.link)
                }
            } else {
                HStack(spacing: 8) {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    if store.isStale { Text(L("out of date")).foregroundStyle(.orange) }
                    Button(L("Rescan")) { store.refresh(force: true) }.controlSize(.small)
                    Button(L("Add project folder…")) { pickFolder() }.controlSize(.small)
                }
                if !store.roots.isEmpty {
                    ForEach(store.roots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .lineLimit(1).truncationMode(.middle)
                            Button { store.removeRoot(root) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel(L("Stop scanning %@", root.lastPathComponent))
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
        let when = store.scannedAt.map { $0.formatted(.relative(presentation: .named)) } ?? L("never")
        return folders == 1
            ? L("%lld configuration folder found · scanned %@", folders, when)
            : L("%lld configuration folders found · scanned %@", folders, when)
    }

    /// Project folders are opened through a picker, so macOS grants access to that folder alone.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Scan")
        panel.message = L("Pick a folder where your projects live. Flowlight looks for agent configuration inside it.")
        if panel.runModal() == .OK, let url = panel.url { store.addRoot(url) }
    }
}

enum Help {
    static let base = URL(string: "https://flowlight.xinbetween.com/docs/")!

    /// The documentation for one screen. The docs page is grouped the way the sidebar is, so this is a real
    /// mapping rather than a guess: each screen has a section named after it.
    static func forScreen(_ item: SidebarItem) -> URL {
        URL(string: "https://flowlight.xinbetween.com/docs/#\(item.helpAnchor)") ?? base
    }
    static let agentConfiguration = URL(string: "https://flowlight.xinbetween.com/docs/#agent-configuration")!
    static let faq = URL(string: "https://flowlight.xinbetween.com/docs/#faq")!
    static let privacy = URL(string: "https://flowlight.xinbetween.com/privacy/")!
    static let issues = URL(string: "https://github.com/xinbetween/flowlight/issues")!
}

/// Shown where inspected data would be, saying which of the three reasons there is nothing to show.
///
/// Telling someone to turn on a setting they already turned on is worse than saying nothing: it reads as the app
/// not knowing its own state, and it hides the step that would actually help. Inspection being on is not enough —
/// a command-line agent only goes through the proxy once its own shell has been pointed at it.
struct InspectionHint: View {
    @ObservedObject var inspection: InspectionController
    let agent: String
    /// The long form, for the "inspection is off" sentence: "the tool calls its model asks for".
    let what: String
    /// The short noun, for the other two: "tool calls".
    let subject: String
    /// Whether anything of this agent's has actually been decrypted in this window.
    var seen: Bool = false
    /// The model provider it has been talking to, when it has. Naming it turns "nothing arrived" into the
    /// actual finding: the agent reached its provider directly, past the proxy.
    var reaching: String?
    /// What to start again, and what to quit first.
    var bundleID: String = ""
    var appPath: String = ""
    @State private var confirmingRelaunch = false
    @State private var relaunchError: String?
    @EnvironmentObject private var nav: AppNavigation

    private var inspecting: Bool { inspection.enabled && inspection.running }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !inspecting {
                Button(L("Set up HTTPS inspection")) { nav.selection = .inspect }
                    .controlSize(.small)
            } else if !seen {
                HStack(spacing: 8) {
                    // Offered first, because when something else is starting the agents it is the only one of
                    // the three that changes anything: a new window is a shell no agent will ever descend from.
                    if let supervisor, supervisor.kind == .supervisor {
                        Button(L("Restart %@ Through the Proxy", supervisor.name)) { confirmingSupervisor = true }
                            .controlSize(.small)
                    }
                    if relaunchTarget != nil {
                        Button(L("Relaunch Through the Proxy")) { confirmingRelaunch = true }
                            .controlSize(.small)
                    }
                    Button(L("Open Inspected Terminal")) { nav.selection = .inspect }
                        .controlSize(.small)
                }
                if let relaunchError {
                    Text(relaunchError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 4)
        .confirmationDialog(L("Quit %@ and start it again through the proxy?", agent),
                            isPresented: $confirmingRelaunch, titleVisibility: .visible) {
            Button(L("Quit and Relaunch")) { relaunch() }
            Button(L("Cancel"), role: .cancel) { confirmingRelaunch = false }
        } message: {
            // The honest description of what this does, because it closes someone else's editor.
            Text(L("A program reads its proxy settings once, when it starts, so there is no way to route one that is already running. %@ is asked to quit — an unsaved document will refuse, and nothing is discarded — and started again with its HTTPS pointed at Flowlight.", agent))
        }
        .confirmationDialog(supervisor.map { L("Restart %@ through the proxy?", $0.name) } ?? "",
                            isPresented: $confirmingSupervisor, titleVisibility: .visible) {
            Button(L("Restart and End Its Sessions"), role: .destructive) { restartSupervisor() }
            Button(L("Cancel"), role: .cancel) { confirmingSupervisor = false }
        } message: {
            // Said outright, because it is the part someone would only discover by losing work to it.
            Text(L("%@ starts %@, so the proxy settings have to reach %@ rather than a new window — a shell opened now would never be any agent's parent. Restarting it ends every session it is currently running, including this one. It is started again with the same command and its HTTPS pointed at Flowlight.",
                   supervisor?.name ?? "", agent, supervisor?.name ?? ""))
        }
    }

    /// What is actually starting this agent, when it is something other than a terminal.
    ///
    /// Looked up from a live process rather than from the traffic rows: the question is what will start the
    /// *next* agent, which a pid from an old flow cannot answer.
    private var supervisor: AgentLauncher.Launcher? {
        guard let pid = ProxyRelaunch.runningPID(bundleID: bundleID, name: agent) else { return nil }
        let launcher = ProxyRelaunch.launcher(forAgentPID: pid)
        // A terminal is not a supervisor, but knowing which one it is means the relaunch opens there instead
        // of in Terminal.app.
        ProxyRelaunch.rememberTerminal(launcher)
        return launcher
    }

    private func restartSupervisor() {
        confirmingSupervisor = false
        relaunchError = nil
        guard let supervisor else { return }
        if let error = ProxyRelaunch.restartSupervisor(supervisor, environment: inspection.proxyEnvironment) {
            relaunchError = error.localizedDescription
        }
    }

    /// What starting this agent again would mean, if anything. An agent Flowlight only ever saw as traffic —
    /// no path, no name it recognises — has nothing to relaunch, and the terminal is the way in.
    @State private var confirmingSupervisor = false

    private var relaunchTarget: ProxyRelaunch.Target? {
        ProxyRelaunch.target(bundleID: bundleID, name: agent, appPath: appPath)
    }

    private func relaunch() {
        confirmingRelaunch = false
        relaunchError = nil
        guard let relaunchTarget else { return }
        ProxyRelaunch.relaunch(relaunchTarget, bundleID: bundleID, name: agent,
                               environment: inspection.proxyEnvironment, proxyURL: inspection.proxyURL) { error in
            Task { @MainActor in relaunchError = error?.localizedDescription }
        }
    }

    private var message: String {
        if !inspecting {
            return L("Flowlight sees %@'s connections, but not what's inside them. Turn on HTTPS inspection to see %@.", agent, what)
        }
        if !seen {
            guard let reaching else {
                return L("HTTPS inspection is on, but nothing of %@'s has gone through it in this window. A command-line agent has to be started with the proxy set in its own shell — Inspect › Open Inspected Terminal.", agent)
            }
            // The traffic is right there in the table above, which is what makes the empty tab look like a bug.
            return L("%1$@ reached %2$@ directly, not through the proxy, so there was nothing to read. Tool calls are taken from the model's own replies, and those arrived encrypted. A command-line agent only uses the proxy if it was started with it set in its own shell — Inspect › Open Inspected Terminal, then run %1$@ from there.", agent, reaching)
        }
        return L("No %@ in this window. Flowlight is decrypting %@'s traffic; its model just hasn't asked for any.", subject, agent)
    }
}
