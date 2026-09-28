import SwiftUI

/// The domains an agent's MCP servers involve, and two ways to refuse each one.
///
/// Two buttons rather than one, because "stop this agent using it" and "stop anything on this Mac using it" are
/// different decisions and the difference is invisible once a rule has been written. Offering one and leaving
/// the other to be discovered in the rule editor would make the narrower choice look like the only choice.
struct MCPDomainsSection: View {
    let agent: AgentSummary
    let entries: [MCPDomains.Entry]
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Domains (%lld)", entries.count)).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if monitor.mode != .networkExtension {
                    // Said here as well as on the Rules screen: a button that writes a rule nothing can carry
                    // out should not look like a button that stops traffic.
                    Text(L("Rules are recorded but not enforced in this capture mode."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if entries.isEmpty {
                Text(L("No MCP server on this agent has a domain yet — local servers that never reach the network have none, and a remote one appears once it is configured or called."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(entries) { entry in
                row(entry)
                Divider()
            }
        }
    }

    private func row(_ entry: MCPDomains.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.host).font(.callout.monospaced())
                    if let counters = entry.counters {
                        Text(ByteFormat.string(counters.total)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.servers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.sortedSources, id: \.self) { source in
                        Text(source.label)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                }
            }
            Spacer()
            if entry.blockable {
                Button(L("Block for %@", agent.name)) { block(entry, global: false) }
                    .controlSize(.small)
                    .help(L("Refuse this host for %@ and the tools it starts. Everything else on this Mac is unaffected.", agent.name))
                Button(L("Block everywhere")) { block(entry, global: true) }
                    .controlSize(.small)
                    .help(L("Refuse this host for every app on this Mac."))
            } else {
                // The honest version of a disabled button: why, rather than a grey rectangle.
                Text(L("The provider connects to this, not your Mac — a rule here cannot reach it."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func block(_ entry: MCPDomains.Entry, global: Bool) {
        // Named after where it came from, so the rules list explains itself six weeks later.
        let name = global
            ? L("Block %@ (MCP)", entry.host)
            : L("Block %@ for %@ (MCP)", entry.host, agent.name)
        monitor.rules.save(RuleStore.block(app: global ? "" : agent.bundleID,
                                           destination: entry.host,
                                           name: name))
        // Straight to the rule, because the next question is always "what would that have stopped?" — which
        // 0.9.4's simulation answers in the editor.
        nav.selection = .rules
    }
}
