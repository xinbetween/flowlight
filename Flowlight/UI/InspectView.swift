import SwiftUI

/// HTTPS inspection: setup while it's off, then the decrypted requests and the tool calls read from them.
struct InspectView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View {
        InspectContent(inspection: monitor.inspection)
    }
}

private struct InspectContent: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @ObservedObject var inspection: InspectionController
    @State private var exchanges: [HTTPExchange] = []
    @State private var links: [Int64: ToolCallLinks.Link] = [:]
    @State private var results: [String: ToolResult] = [:]
    @State private var selection: HTTPExchange.ID?
    @State private var search = ""
    @State private var window: AgentWindow = .day
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if DemoData.isEnabled {
                ContentUnavailableView("Not available in demo mode", systemImage: "lock.open.display",
                                       description: Text("HTTPS inspection runs only on your real traffic."))
            } else if !inspection.enabled || showSetup {
                ScrollView { InspectionSetup(inspection: inspection, done: { showSetup = false }).padding(.bottom, 20) }
            } else {
                statusBar
                if exchanges.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing inspected yet", systemImage: "lock.open.display")
                    } description: {
                        Text("Start an agent from an inspected Terminal window, or turn on the system proxy in Setup. Its requests appear here.")
                    } actions: {
                        Button("Open Inspected Terminal") { inspection.openInspectedTerminal() }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    HSplitView {
                        table.frame(minWidth: 460, maxHeight: .infinity)
                        detail.padding(.leading, 12).frame(minWidth: 360, idealWidth: 460, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
        .navigationTitle("Inspect")
        .searchable(text: $search, placement: .toolbar, prompt: "Host, path, app or tool")
        .task(id: LoadKey(version: monitor.inspectionVersion, search: search, window: window, enabled: inspection.enabled)) {
            // Coalesce bursts of new exchanges.
            try? await Task.sleep(for: .milliseconds(300))
            await load()
        }
    }

    private struct LoadKey: Equatable { var version: Int; var search: String; var window: AgentWindow; var enabled: Bool }

    private func load() async {
        let since = Date().addingTimeInterval(-window.interval), term = search
        exchanges = (try? await monitor.read { try $0.exchanges(since: since, search: term) }) ?? []
        // Link with the unfiltered list, so a search for "curl" still shows which tool call started it.
        let all = term.isEmpty ? exchanges : ((try? await monitor.read { try $0.exchanges(since: since) }) ?? [])
        links = ToolCallLinks.link(all)
        var found: [String: ToolResult] = [:]
        for e in all { for r in e.toolResults where found[r.callID] == nil { found[r.callID] = r } }
        results = found
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(inspection.running && inspection.trusted ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(statusText).font(.callout)
            Spacer()
            Picker("Window", selection: $window) {
                ForEach(AgentWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Button("Open Inspected Terminal") { inspection.openInspectedTerminal() }
                .help("A Terminal window whose agents and tools go through Flowlight")
            Button("Setup…") { showSetup = true }
        }
    }

    private var statusText: String {
        guard inspection.running, let port = inspection.port else { return "Starting the proxy…" }
        var parts = ["Proxy on 127.0.0.1:\(port)"]
        if !inspection.trusted { parts.append("certificate not trusted yet") }
        parts.append(inspection.scope == .agents ? "decrypting AI agents only" : "decrypting every app")
        if inspection.systemProxyOn { parts.append("system proxy on") }
        return parts.joined(separator: " · ")
    }

    private var table: some View {
        Table(exchanges, selection: $selection) {
            TableColumn("Time") { e in
                Text(e.started, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 78, ideal: 84)
            TableColumn("App") { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.agentName ?? e.appName).lineLimit(1)
                    if let via = e.via {
                        Text("via \(via)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn("Request") { e in
                VStack(alignment: .leading, spacing: 1) {
                    if e.note != nil {
                        Label("Not inspected: \(e.host)", systemImage: "lock").foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text("\(e.method) \(e.host)").lineLimit(1)
                        Text(e.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Status") { e in
                Text(e.status.map(String.init) ?? "–").monospacedDigit()
                    .foregroundStyle((e.status ?? 0) >= 400 ? .red : .primary)
            }
            .width(min: 44, ideal: 50)
            TableColumn("Size") { e in
                Text(ByteFormat.string(Int64(e.requestSize + e.responseSize))).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 76, ideal: 84)
            TableColumn("Tool calls") { e in
                if !e.toolCalls.isEmpty {
                    Text(e.toolCalls.map(\.displayName).joined(separator: ", ")).lineLimit(1).foregroundStyle(.purple)
                } else if let id = e.id, let link = links[id] {
                    Text("← \(link.call.displayName): \(link.call.summary ?? "")").lineLimit(1).foregroundStyle(.secondary)
                        .help("Made by the tool the model asked for: \(link.call.summary ?? link.call.input)")
                }
            }
            .width(min: 80, ideal: 160)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected = exchanges.first(where: { $0.id == selection }) {
            ExchangeDetail(exchange: selected, cause: selected.id.flatMap { links[$0] }, results: results)
                .id(selected.id)
        } else {
            ContentUnavailableView("Select a request", systemImage: "doc.text.magnifyingglass")
        }
    }
}

/// Setup: what inspection does, the certificate, how traffic gets routed, and what's never decrypted.
private struct InspectionSetup: View {
    @ObservedObject var inspection: InspectionController
    var done: () -> Void
    @State private var newPattern = ""
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.open.display").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("HTTPS inspection").font(.title2.bold())
                    Text("See the full requests and responses your AI agents exchange, including every tool call the model asks them to run. Flowlight becomes a local proxy with its own certificate authority, created on this Mac and trusted only if you approve it. It's off by default, stays on your Mac, and only decrypts traffic you route through it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { inspection.enabled }, set: { inspection.enabled = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Turn on HTTPS inspection").font(.headline)
                            Text("Starts the proxy on 127.0.0.1:\(String(inspection.port ?? inspection.configuredPort)). Nothing is routed to it until you choose below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    Picker("Decrypt", selection: Binding(get: { inspection.scope }, set: { inspection.scope = $0 })) {
                        ForEach(InspectionController.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Text("With AI agents only, other apps sent through the proxy are passed through encrypted and not recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            step(1, "Trust the Flowlight certificate", done: inspection.trusted) {
                Text("Apps only accept Flowlight's certificates if you trust its authority. macOS asks for your password. Command-line tools started from an inspected Terminal trust it without this step.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(inspection.trusted ? "Trusted" : "Trust Certificate…") { inspection.trustCertificate() }
                        .disabled(inspection.trusted || !inspection.enabled)
                    Button("Show in Finder") { inspection.revealCertificate() }.disabled(!inspection.caExists)
                }
            }

            step(2, "Route an agent through Flowlight", done: inspection.recordedCount > 0) {
                Text("Command-line agents (Claude Code, Codex, Gemini CLI, Aider) and the tools they run follow proxy variables. Start them from an inspected Terminal, or paste the setup into any shell.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Inspected Terminal") { inspection.openInspectedTerminal() }
                    Button("Copy Shell Setup") { inspection.copyShellSetup() }
                }
                .disabled(!inspection.enabled)
                Toggle(isOn: Binding(get: { inspection.systemProxyOn }, set: { inspection.setSystemProxy($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also use it for apps that follow system proxy settings")
                        Text("Desktop apps such as Cursor, VS Code and Claude go through Flowlight. If Flowlight quits, they connect directly. Asks for an administrator password.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!inspection.enabled || !inspection.running)
            }

            GroupBox("Never decrypted") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These hosts and their subdomains are always passed through encrypted. Apps that pin their certificates are detected and passed through automatically.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(inspection.neverInspect, id: \.self) { pattern in
                            HStack(spacing: 4) {
                                Text(pattern).font(.caption.monospaced())
                                Button { inspection.neverInspect.removeAll { $0 == pattern } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(pattern)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                    HStack {
                        TextField("bank.example", text: $newPattern).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .onSubmit(add)
                        Button("Add", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Button("Restore Defaults") { inspection.neverInspect = InspectionController.defaultNeverInspect }
                    }
                }
                .padding(6)
            }

            if let error = inspection.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                Button("Remove Certificate & Recorded Data…", role: .destructive) { confirmRemove = true }
                    .disabled(!inspection.caExists)
                Spacer()
                if inspection.enabled { Button("Done") { done() }.keyboardShortcut(.defaultAction) }
            }
            Text("Recorded requests are kept for 3 days. API keys, cookies and other credential headers are never stored. Some apps refuse any certificate but their own; those stay encrypted.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .confirmationDialog("Remove HTTPS inspection?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { inspection.removeEverything() }
        } message: {
            Text("Turns inspection off, removes the certificate and its trust setting, and deletes every recorded request.")
        }
        .onAppear { inspection.refreshStatus() }
    }

    private func add() {
        let p = newPattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty, !inspection.neverInspect.contains(p) else { return }
        inspection.neverInspect.append(p)
        newPattern = ""
    }

    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                    .font(.title2).foregroundStyle(done ? .green : .secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    content()
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }
}

/// One request and response: tool calls first, then headers and bodies.
private struct ExchangeDetail: View {
    @EnvironmentObject var monitor: TrafficMonitor
    let exchange: HTTPExchange
    var cause: ToolCallLinks.Link?
    var results: [String: ToolResult] = [:]
    @State private var bodies: (request: Data, response: Data)?
    @State private var tab = 0
    @State private var headersOpen: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exchange.note == nil ? "\(exchange.method) \(exchange.url)" : exchange.host)
                    .font(.headline).textSelection(.enabled).lineLimit(3)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let note = exchange.note {
                Label(note, systemImage: "lock").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let cause {
                GroupBox("Made by a tool call") {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(cause.call.displayName, systemImage: "arrow.turn.down.right").font(.callout.bold())
                        Text(cause.call.summary ?? cause.call.input).font(.caption.monospaced()).textSelection(.enabled).lineLimit(6)
                            .foregroundStyle(.secondary)
                        Text("Requested by the model \(cause.requestedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))), then run by \(exchange.appName) for \(exchange.agentName ?? "the agent").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !exchange.toolCalls.isEmpty {
                GroupBox("Tool calls the model asked for") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(exchange.toolCalls.enumerated()), id: \.offset) { _, call in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(call.displayName, systemImage: call.mcpServer == nil ? "wrench.and.screwdriver" : "puzzlepiece.extension")
                                    .font(.callout.bold())
                                Text(call.summary ?? call.input).font(.caption.monospaced()).textSelection(.enabled)
                                    .lineLimit(6).foregroundStyle(.secondary)
                                if let result = call.callID.flatMap({ results[$0] }) {
                                    resultView(result)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
            }
            if !exchange.toolResults.isEmpty {
                GroupBox("Tool results sent to the model (\(exchange.toolResults.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(exchange.toolResults.prefix(20).enumerated()), id: \.offset) { _, result in
                            resultView(result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !exchange.mcp.isEmpty {
                GroupBox("MCP") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(exchange.mcp.enumerated()), id: \.offset) { _, m in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: m.isError ? "xmark.octagon.fill" : "puzzlepiece.extension")
                                        .foregroundStyle(m.isError ? TrafficColors.anomaly : .purple)
                                    Text("\(m.server)\(m.version.map { " \($0)" } ?? "") · \(m.method)\(m.tool.map { " · \($0)" } ?? "")")
                                        .font(.callout.bold())
                                }
                                if let summary = m.summary { Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4) }
                                if let tools = m.tools { Text("\(tools.count) tools: " + tools.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                                if let output = m.output, !output.isEmpty {
                                    Text(output).font(.caption.monospaced()).lineLimit(6).textSelection(.enabled)
                                        .foregroundStyle(m.isError ? TrafficColors.anomaly : .secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            Picker("Part", selection: $tab) {
                Text("Request").tag(0)
                Text("Response").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let headers = tab == 0 ? exchange.requestHeaders : exchange.responseHeaders
                    let data = tab == 0 ? bodies?.request : bodies?.response
                    if !headers.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { headersOpen ?? (data?.isEmpty ?? true) }, set: { headersOpen = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                                    (Text(h.name + ": ").bold() + Text(h.value)).font(.caption.monospaced())
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        } label: {
                            Text("Headers (\(headers.count))").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if let data, !data.isEmpty {
                        BodyView(data: data, truncated: tab == 0 ? exchange.requestTruncated : exchange.responseTruncated)
                            .id("\(tab)-\(exchange.id ?? 0)")
                    } else {
                        Text(bodies == nil ? "Loading…" : emptyReason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
        }
        .task {
            guard let id = exchange.id else { return }
            bodies = (try? await monitor.read { try $0.exchangeBodies(id: id) }) ?? (Data(), Data())
        }
    }

    private func resultView(_ result: ToolResult) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(result.isError ? "Error" : "Result", systemImage: result.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .font(.caption.bold()).foregroundStyle(result.isError ? TrafficColors.anomaly : .green)
            Text(result.output.isEmpty ? "(empty)" : result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption.monospaced()).lineLimit(6).textSelection(.enabled).foregroundStyle(.secondary)
            if result.outputSize > result.output.count {
                Text("\(result.outputSize) characters in total").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
    }

    private var emptyReason: String {
        if tab == 1, exchange.status == 304 { return "No body: 304 Not Modified means the app's cached copy is still current." }
        if tab == 1, exchange.status == 204 { return "No body: 204 No Content." }
        if tab == 0, ["GET", "HEAD", "DELETE", "OPTIONS"].contains(exchange.method) { return "No body (a \(exchange.method) request normally has none)." }
        return "No body"
    }

    private var subtitle: String {
        var parts = [exchange.agentName ?? exchange.appName]
        if let via = exchange.via { parts.append("via \(via)") }
        if exchange.pid > 0 { parts.append("pid \(exchange.pid)") }
        if let status = exchange.status { parts.append("HTTP \(status)") }
        parts.append(String(format: "%.2f s", exchange.duration))
        parts.append("↑ \(ByteFormat.string(Int64(exchange.requestSize))) ↓ \(ByteFormat.string(Int64(exchange.responseSize)))")
        return parts.joined(separator: " · ")
    }
}
