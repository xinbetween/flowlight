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
    @AppStorage("agents.window") private var window: AgentWindow = .day
    @State private var agents: [AgentSummary] = []
    @State private var agentAlerts = 0
    @State private var selection: AgentSummary.ID?
    @State private var sortOrder = [KeyPathComparator(\AgentSummary.riskScore, order: .reverse)]
    @State private var loaded = false

    private var selected: AgentSummary? { agents.first { $0.id == selection } ?? agents.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Every AI agent on this Mac, and where it sends data besides its model provider.")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(AgentWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            }
            tiles
            if agents.isEmpty && loaded {
                ContentUnavailableView {
                    Label("No AI agents seen", systemImage: "sparkles")
                } description: {
                    Text("Flowlight recognizes agents such as Claude Code, Codex, Cursor and Ollama, and any other app that calls an LLM API (Anthropic, OpenAI, Gemini, Mistral, OpenRouter and more).")
                }
                .frame(maxHeight: .infinity)
            } else {
                table.frame(minHeight: 180)
                if let selected { AgentDetail(agent: selected, window: window) }
            }
        }
        .padding()
        .navigationTitle("AI Agents")
        .task(id: LoadKey(window: window, version: monitor.dataVersion)) { await load() }
    }

    private struct LoadKey: Equatable { var window: AgentWindow; var version: Int }

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
            }
        } primaryAction: { ids in
            if let id = ids.first { nav.showReport(filter: TrafficFilter(bundleID: id), granularity: window.granularity) }
        }
    }

    private func load() async {
        let (g, from, to) = (window.granularity, Date().addingTimeInterval(-window.interval), Date())
        let result = try? await monitor.read { db -> ([BreakdownRow], [AlertRecord]) in
            (try db.breakdown(g, from: from, to: to), try db.alerts(limit: 2000).filter { $0.timestamp >= from })
        }
        guard let (rows, alerts) = result else { return }
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

struct AgentDetail: View {
    @EnvironmentObject var nav: AppNavigation
    var agent: AgentSummary
    var window: AgentWindow

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.tools.isEmpty {
                        Text("Tools & MCP servers").font(.caption.bold()).foregroundStyle(.secondary)
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
                }
                .frame(width: 260, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Other destinations").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Reports") {
                            nav.showReport(filter: TrafficFilter(bundleID: agent.bundleID), granularity: window.granularity)
                        }
                        .controlSize(.small)
                    }
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
                    .frame(maxHeight: 150)
                }
            }
        } label: {
            Text("\(agent.name) · \(ByteFormat.string(agent.total.total)) in \(window.title.lowercased())")
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
            Text("↑ \(ByteFormat.string(d.counters.bytesOut))  ↓ \(ByteFormat.string(d.counters.bytesIn))").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
