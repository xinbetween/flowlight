import SwiftUI

/// Which tools this agent may use: a switch beside each one, the presets worth having, and a plain account of
/// what this is and isn't.
struct GuardrailsPane: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @ObservedObject var store: GuardrailStore
    let agentKey: String
    let agentName: String
    /// Tools the agent declared to its model, which is the list a guardrail edits.
    let declared: [DeclaredTool]
    /// MCP servers it reached over the network.
    let servers: [String]
    @State private var typed = ""

    private var mine: [Guardrail] { store.guardrails(for: agentKey) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                explanation
                if !monitor.inspection.enabled {
                    Label(L("HTTPS inspection is off, so Flowlight can't read the tool list — nothing here is being carried out yet."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }

                presets
                if !declared.isEmpty { tools }
                if !servers.isEmpty { serverList }
                if !mine.isEmpty { existing }
                custom
                Divider().padding(.vertical, 2)
                limits
            }
            .padding(.trailing, 6)
        }
    }

    private var explanation: some View {
        Text(L("An agent re-sends its whole tool list on every turn. Switching a tool off here removes it from that list before the model ever sees it — so there is no refusal to argue with and no retry loop. For MCP servers reached over HTTP, a refused call is answered here too, with a sentence the model can read."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Presets")).font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                ForEach(Guardrail.presets) { preset in
                    Button(preset.name) { store.save(Guardrail.preset(preset, agent: agentKey)) }
                        .controlSize(.small)
                        .help(preset.detail)
                }
            }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Declared to the model · \(declared.count)").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(declared.enumerated()), id: \.offset) { _, tool in
                toggleRow(name: tool.name, server: tool.server, detail: tool.detail)
            }
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("MCP servers")).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(servers, id: \.self) { server in
                toggleRow(name: "", server: server, detail: "every tool on this server")
            }
        }
    }

    /// One switch. On means allowed, which is how everything starts: a guardrail is something you add.
    private func toggleRow(name: String, server: String?, detail: String?) -> some View {
        let existing = store.refusing(agent: agentKey, server: server, tool: name)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { existing == nil },
                set: { allowed in
                    if allowed {
                        if let existing { store.delete(existing) }
                    } else {
                        store.refuse(agent: agentKey, server: server, tool: name)
                    }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Allow \(name.isEmpty ? (server ?? "") : name)")
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? (server ?? "") : (server.map { "\($0) › \(name)" } ?? name))
                    .font(.callout)
                    .strikethrough(existing != nil)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let existing, existing.hits > 0 {
                Text("\(existing.hits) taken away").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var existing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Guardrails on \(agentName)").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(mine) { guardrail in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { guardrail.enabled }, set: { store.setEnabled(guardrail, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(guardrail.title).font(.callout).lineLimit(1)
                        if guardrail.hits > 0, let last = guardrail.lastHit {
                            Text("\(guardrail.hits) times · last \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.tertiary)
                        } else {
                            Text(L("never yet")).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { store.delete(guardrail) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var custom: some View {
        HStack {
            TextField(L("Refuse a tool by name or pattern, e.g. write*"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button(L("Add"), action: add).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.save(Guardrail(agent: agentKey, tool: name))
        typed = ""
    }

    /// What this is not. A blocked tool stops being offered and stops being answered; an agent with a shell can
    /// still do by hand what the tool would have done. Flowlight reports that; it doesn't pretend to prevent it.
    private var limits: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("This is not a sandbox."), systemImage: "info.circle").font(.caption.bold()).foregroundStyle(.secondary)
            Text(L("A refused tool stops being offered to the model and stops being answered. An agent that still has a shell can do by hand what the tool would have done — Flowlight will record that, but it can't stop it. Local MCP servers speak over pipes, which no proxy can see: what Flowlight can do there is watch the server's own network traffic, which is already attributed to the agent that started it, and offer to write the agent's own deny list."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !mine.isEmpty {
                DenyListOffer(agent: agentName, guardrails: mine)
            }
        }
    }
}

/// The honest lever for a local stdio server: the agent's own switch. Claude Code takes `mcp__server__tool` in
/// `permissions.deny`, and its neighbours have equivalents — so the useful thing Flowlight can do is write the
/// lines out, ready to paste, rather than edit someone's configuration behind their back.
private struct DenyListOffer: View {
    let agent: String
    let guardrails: [Guardrail]
    @State private var copied = false

    private var lines: [String] {
        guardrails.filter { !$0.tool.isEmpty }.map { guardrail in
            guardrail.server.isEmpty ? guardrail.tool : "mcp__\(guardrail.server)__\(guardrail.tool)"
        }
    }

    var body: some View {
        HStack {
            Button(copied ? "Copied" : "Copy as a deny list") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.map { "\"\($0)\"" }.joined(separator: ",\n"), forType: .string)
                copied = true
            }
            .controlSize(.small)
            Text("for `permissions.deny` in \(agent)'s own settings — it takes effect when the agent restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
