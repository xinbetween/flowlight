import SwiftUI

/// Every rule Flowlight has been given, what each one is doing, and what they have refused.
///
/// The screen answers three questions, in the order people ask them: what have I said, is it actually happening,
/// and why is this getting through? The last two are why the list carries a limitation beside a rule the current
/// engine can't carry out, and why a relaxation appears in the feed beside a refusal.
struct RulesView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var editing: Rule?
    @State private var isNew = false
    @State private var tab = Tab.rules
    @State private var now = Date()

    private enum Tab: String, CaseIterable, Identifiable {
        case rules, activity
        var id: String { rawValue }
        var title: String { self == .rules ? "Rules" : "What they did" }
    }

    private var store: RuleStore { monitor.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 260)
            .padding(.horizontal, 16).padding(.top, 12)

            if tab == .rules { ruleList } else { activityFeed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: isNew) { store.save($0) }
        }
        .onChange(of: nav.ruleRequest) { _, request in
            guard let request else { return }
            editing = request.rule
            isNew = true
            nav.ruleRequest = nil
        }
        .onAppear {
            if let request = nav.ruleRequest { editing = request.rule; isNew = true; nav.ruleRequest = nil }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules").font(.title2.bold())
                    Text("Block anything, anywhere, for as long as you say — and write down the way back out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                pauseControl
                Button("Add Rule…") { editing = Rule(); isNew = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            if let warning = engineWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    /// The escape hatch. A strict rule is only liveable if there is an obvious way to stand it down for a minute,
    /// and an escape hatch that has to be found in Settings isn't one.
    private var pauseControl: some View {
        Group {
            if store.isPaused, let until = store.pausedUntil {
                Button {
                    store.resume()
                } label: {
                    Label("Paused until \(until.formatted(date: .omitted, time: .shortened)) — Resume",
                          systemImage: "play.circle.fill")
                }
                .tint(.orange)
                .help("Nothing is being refused. Click to start again now.")
            } else {
                Menu {
                    Button("10 minutes") { store.pause(for: 600) }
                    Button("1 hour") { store.pause(for: 3600) }
                    Button("Until I resume") { store.pause(for: 60 * 60 * 24 * 365) }
                } label: {
                    Label("Pause Blocking", systemImage: "pause.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Stand every rule down for a while, without deleting anything")
            }
        }
    }

    /// What the rules as a set can't do here. Per-rule limitations sit on the rows; this is the one worth saying
    /// once, loudly, because it applies to almost everything in the list.
    private var engineWarning: String? {
        let blind = RuleBook.unenforceable(store.rules, extensionRunning: monitor.mode == .networkExtension,
                                           inspecting: monitor.inspection.enabled)
        guard !blind.isEmpty else { return nil }
        if monitor.mode != .networkExtension && blind.contains(where: { $0.engine == .flow }) {
            return "\(blind.count == 1 ? "One rule is" : "\(blind.count) rules are") being watched but not carried out. "
                + "Only the Network Extension sits in the data path and can refuse a connection; the nettop sampler "
                + "counts traffic after the fact. Switch source in Capture to make these bite."
        }
        return "\(blind.count == 1 ? "One rule is" : "\(blind.count) rules are") being watched but not carried out — "
            + "a rule that names a path can only be matched by HTTPS inspection, and it is off."
    }

    // MARK: The list

    private var ruleList: some View {
        Group {
            if store.rules.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.rules) { rule in
                            RuleRow(rule: rule, store: store, now: now,
                                    extensionRunning: monitor.mode == .networkExtension,
                                    inspecting: monitor.inspection.enabled,
                                    events: store.events(for: rule).count) {
                                editing = rule; isNew = false
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No rules yet.").font(.callout).foregroundStyle(.secondary)
            Text("A rule names something — an app, an agent, a destination, or a URL — and says block or allow. "
                 + "Right-click any row in Live, Reports, AI Agents or Inspect to write one about what you're looking at, "
                 + "or start from a preset below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(RuleEditor.presets, id: \.name) { preset in
                    Button(preset.name) { editing = preset.rule(); isNew = true }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(16)
    }

    /// A decision can come from a network rule or from a guardrail — the same question asked about a destination
    /// or about a tool — so the feed looks in both lists before giving up on it.
    private func name(of event: RuleEventRecord) -> String {
        if let rule = store.rules.first(where: { $0.id == event.ruleID }) { return rule.title }
        if let guardrail = monitor.guardrails.guardrails.first(where: { $0.id == event.ruleID }) { return guardrail.title }
        return "A rule since deleted"
    }

    // MARK: The violations feed

    private var activityFeed: some View {
        Group {
            if store.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                    Text("Every connection a rule decides lands here — the refusals, and the exceptions that let "
                         + "something through. The second half is how \"why is this getting through?\" stays answerable.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(16)
            } else {
                Table(store.events) {
                    TableColumn("When") { Text($0.timestamp.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }
                        .width(80)
                    TableColumn("") { event in
                        Image(systemName: event.action == .block ? "hand.raised.fill" : "checkmark.shield")
                            .foregroundStyle(event.action == .block ? Color.red : Color.green)
                            .help(event.action == .block ? "Refused" : "Allowed by an exception")
                    }
                    .width(20)
                    TableColumn("App") { event in
                        Text(event.agentName.isEmpty || event.agentName == event.appName
                             ? event.appName : "\(event.agentName) › \(event.appName)").lineLimit(1)
                    }
                    TableColumn("Destination") { event in
                        Text(event.path.isEmpty ? "\(event.destination):\(event.port)"
                                                : "\(event.method) \(event.destination)\(event.path)")
                            .font(.caption.monospaced()).lineLimit(1)
                    }
                    TableColumn("Rule") { event in
                        Text(name(of: event)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    TableColumn("Where") { event in
                        Text(event.engine == .flow ? "Connection" : "Request")
                            .font(.caption).foregroundStyle(.tertiary)
                            .help(event.engine == .flow
                                  ? "Refused by the Network Extension, before the connection was made"
                                  : "Refused by HTTPS inspection, which answered the request itself")
                    }
                    .width(80)
                }
                .padding(.horizontal, 8).padding(.top, 8)
            }
        }
    }
}

/// One rule in the list: what it says, when it applies, what it has done, and what it can't do here.
private struct RuleRow: View {
    let rule: Rule
    let store: RuleStore
    let now: Date
    let extensionRunning: Bool
    let inspecting: Bool
    let events: Int
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Enable \(rule.title)")
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: rule.action == .block ? "hand.raised.fill" : "checkmark.shield")
                        .foregroundStyle(rule.action == .block ? Color.red : Color.green)
                        .font(.caption)
                    Text(rule.title).font(.callout)
                    if rule.origin != .typed {
                        Text(originLabel).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Label(schedule, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    if rule.hits > 0 {
                        Text("· \(rule.hits) \(rule.hits == 1 ? "time" : "times")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let last = rule.lastHit {
                            Text("· last \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    } else if rule.enabled {
                        Text("· never yet").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let limitation = rule.limitation(extensionRunning: extensionRunning, inspecting: inspecting), rule.enabled {
                    Label(limitation, systemImage: "eye")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !rule.isUsable {
                    Label("Used up — a one-off allowance, already spent.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 8)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).accessibilityLabel("Edit \(rule.title)")
            Button(role: .destructive) { store.delete(rule) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).accessibilityLabel("Delete \(rule.title)")
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Edit…", action: edit)
            if rule.hits > 0 { Button("Reset Count") { store.resetHits(rule) } }
            Divider()
            Button("Delete", role: .destructive) { store.delete(rule) }
        }
    }

    private var schedule: String {
        rule.schedule.describe(at: now, session: RuleStore.session)
    }

    private var originLabel: String {
        switch rule.origin {
        case .typed: return "typed"
        case .preset: return "preset"
        case .alert: return "from an alert"
        case .allowOnce: return "allowed once"
        }
    }
}

/// "Block this", wherever traffic is shown. Every table offers it, and every one of them writes the same rule and
/// lands in the same editor — a rule that took effect out of sight would be a rule nobody could find again.
struct RuleMenuItems: View {
    @EnvironmentObject var nav: AppNavigation
    var app: (bundleID: String, name: String)?
    var host: String?

    var body: some View {
        if let app, !app.bundleID.isEmpty {
            Menu("Block \(app.name)…") {
                Button("Everywhere") { write(RuleStore.block(app: app.bundleID, name: "Block \(app.name)")) }
                if let host {
                    Button("From reaching \(host)") {
                        write(RuleStore.block(app: app.bundleID, destination: host,
                                              name: "\(app.name) can't reach \(host)"))
                    }
                }
                Button("For the next hour") {
                    write(RuleStore.block(app: app.bundleID, name: "\(app.name), for an hour",
                                          schedule: .expiring(in: 3600)))
                }
                Button("Until Flowlight quits") {
                    write(RuleStore.block(app: app.bundleID, name: "\(app.name), this session",
                                          schedule: .thisSession(RuleStore.session)))
                }
            }
        }
        if let host, !host.isEmpty {
            Menu("Block \(host)…") {
                Button("For every app") { write(RuleStore.block(destination: host, name: "Nothing reaches \(host)")) }
                Button("For the next hour") {
                    write(RuleStore.block(destination: host, name: "\(host), for an hour",
                                          schedule: .expiring(in: 3600)))
                }
            }
        }
    }

    private func write(_ rule: Rule) { nav.writeRule(rule) }
}
