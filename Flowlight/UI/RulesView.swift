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
        Group {
            if tab == .rules {
                if store.rules.isEmpty { empty } else { ruleList }
            } else {
                activityFeed
            }
        }
        .navigationTitle("Rules")
        // The title bar carries the state that would otherwise need a trip to the screen to discover: how many
        // rules are live, and whether they are standing down.
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
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

    private var subtitle: String {
        if store.isPaused, let until = store.pausedUntil {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        let live = store.liveRules.count
        guard !store.rules.isEmpty else { return "" }
        return live == store.rules.count
            ? "\(live) in force" : "\(live) of \(store.rules.count) in force"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Nothing to switch between until there is something in one of them.
        if !store.rules.isEmpty || !store.events.isEmpty {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }
        ToolbarItemGroup {
            pauseControl
            Button {
                editing = Rule()
                isNew = true
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Write a rule: an app, an agent, a destination or a URL, blocked or allowed")
        }
    }

    /// The escape hatch. A strict rule is only liveable if there is an obvious way to stand it down for a minute,
    /// and an escape hatch that has to be found in Settings isn't one.
    @ViewBuilder
    private var pauseControl: some View {
        if store.isPaused, let until = store.pausedUntil {
            Button {
                store.resume()
            } label: {
                Label("Paused until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "play.circle.fill")
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
            .help("Stand every rule down for a while, without deleting anything")
        }
    }

    /// What the rules as a set can't do here. Per-rule limitations sit on the rows; this is the one worth saying
    /// once, because it applies to almost everything in the list.
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

    /// Rules that would decide something if a connection arrived this second, and the ones that wouldn't. A rule
    /// outside its hours, switched off, expired or already spent is still a rule someone wrote — it belongs on the
    /// screen, just not among the ones doing the work. The global pause deliberately doesn't move anything: it is
    /// said once in the banner, and shuffling the whole list for ten minutes would lose people's place.
    private var inForce: [Rule] {
        store.rules.filter { $0.enabled && $0.isUsable && $0.schedule.isActive(at: now, session: RuleStore.session) }
    }

    private var resting: [Rule] {
        store.rules.filter { !($0.enabled && $0.isUsable && $0.schedule.isActive(at: now, session: RuleStore.session)) }
    }

    private var ruleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !resting.isEmpty && !inForce.isEmpty { heading("In force") }
                ForEach(inForce) { rule in row(rule) }
                if !resting.isEmpty {
                    heading("Not in force").padding(.top, inForce.isEmpty ? 0 : 12)
                    ForEach(resting) { rule in row(rule) }
                }
            }
            .padding(Measure.gutter)
            .measured()
        }
        .safeAreaInset(edge: .top, spacing: 0) { banner }
    }

    private func row(_ rule: Rule) -> some View {
        RuleRow(rule: rule, store: store, now: now,
                extensionRunning: monitor.mode == .networkExtension,
                inspecting: monitor.inspection.enabled,
                events: store.events(for: rule).count) {
            editing = rule; isNew = false
        }
        // A rule that has just been written, or has just crossed between in force and not, is a change of state
        // worth marking. Nothing moves that hasn't changed.
        .entrance()
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    /// The one thing that outranks every row: everything is standing down, or most of it isn't being carried out.
    /// The pause comes first because it explains the rest.
    @ViewBuilder
    private var banner: some View {
        if store.isPaused, let until = store.pausedUntil {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text("Nothing is being refused until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Resume now") { store.resume() }.buttonStyle(.link)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        } else if let warning = engineWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye").foregroundStyle(.orange)
                Text(warning).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No rules yet", systemImage: "hand.raised")
        } description: {
            Text("A rule names something — an app, an agent, a destination, or a URL — and says block or allow. "
                 + "Right-click any row in Live, Reports, AI Agents or Inspect to write one about what you're looking at, "
                 + "or start from a preset.")
        } actions: {
            ForEach(RuleEditor.presets, id: \.name) { preset in
                Button(preset.name) { editing = preset.rule(); isNew = true }
            }
        }
    }

    // MARK: The violations feed

    private var activityFeed: some View {
        Group {
            if store.events.isEmpty {
                ContentUnavailableView {
                    Label("Nothing yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Every connection a rule decides lands here — the refusals, and the exceptions that let "
                         + "something through. The second half is how \"why is this getting through?\" stays answerable.")
                }
            } else {
                feed
            }
        }
    }

    /// The decisions, as the rest of the app reads: a day at a time, newest first. A table would sort and resize,
    /// neither of which anybody asked of a feed — what is asked is "what happened, and which rule did it".
    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(feedDays) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        heading(day.title)
                        VStack(spacing: 0) {
                            ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                                if index > 0 { Divider().padding(.leading, 34) }
                                EventRow(event: event, rule: name(of: event)) {
                                    if let rule = store.rules.first(where: { $0.id == event.ruleID }) {
                                        editing = rule; isNew = false
                                    }
                                }
                            }
                        }
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .entrance()
                }
            }
            .padding(Measure.gutter)
            .measured()
        }
    }

    private struct FeedDay: Identifiable {
        let id: Date
        let title: String
        let events: [RuleEventRecord]
    }

    private var feedDays: [FeedDay] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: store.events) { calendar.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(date: .abbreviated, time: .omitted)
            return FeedDay(id: day, title: title,
                           events: (byDay[day] ?? []).sorted { $0.timestamp > $1.timestamp })
        }
    }

    /// A decision can come from a network rule or from a guardrail — the same question asked about a destination
    /// or about a tool — so the feed looks in both lists before giving up on it.
    private func name(of event: RuleEventRecord) -> String {
        if let rule = store.rules.first(where: { $0.id == event.ruleID }) { return rule.title }
        if let guardrail = monitor.guardrails.guardrails.first(where: { $0.id == event.ruleID }) { return guardrail.title }
        return "A rule since deleted"
    }
}

/// One rule in the list: what it says, when it applies, what it has done, and what it can't do here.
///
/// The row is read top down and the type sizes say so — the subject and the verb first, the technical form of it
/// underneath in monospace, and the bookkeeping last. Everything a rule can't do here is the exception to that:
/// it gets its own strip, because a rule that isn't biting is the thing someone came to the screen to find out.
private struct RuleRow: View {
    let rule: Rule
    let store: RuleStore
    let now: Date
    let extensionRunning: Bool
    let inspecting: Bool
    let events: Int
    let edit: () -> Void

    private var limitation: String? {
        guard rule.enabled else { return nil }
        return rule.limitation(extensionRunning: extensionRunning, inspecting: inspecting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        headline.lineLimit(2)
                        if rule.origin != .typed {
                            Text(originLabel).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    // Only worth a line of its own where the headline is a name someone chose, which hides it.
                    if !rule.name.isEmpty {
                        Text(subject).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    meta
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Enable \(rule.title)")
                    .padding(.top, 2)
                Menu {
                    Button("Edit…", action: edit)
                    if rule.hits > 0 { Button("Reset Count") { store.resetHits(rule) } }
                    Divider()
                    Button("Delete", role: .destructive) { store.delete(rule) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .accessibilityLabel("More for \(rule.title)")
            }
            if let limitation {
                note(limitation, icon: "eye", tint: .orange)
            }
            if !rule.isUsable {
                note("Used up — a one-off allowance, already spent.", icon: "checkmark.circle", tint: .secondary)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            if rule.hits > 0 { Button("Reset Count") { store.resetHits(rule) } }
            Divider()
            Button("Delete", role: .destructive) { store.delete(rule) }
        }
    }

    /// The verb, as a symbol. A rule that is only being watched says so here as well as in the strip below, because
    /// this is the mark the eye lands on first and a red hand over a rule that refuses nothing would be a lie.
    private var glyph: some View {
        let tint: Color = !rule.enabled ? .secondary
            : limitation != nil ? .orange
            : rule.action == .block ? .red : .green
        let symbol = limitation != nil && rule.enabled ? "eye.fill"
            : rule.action == .block ? "hand.raised.fill" : "checkmark.shield.fill"
        return Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(rule.action == .block ? "Blocks" : "Allows")
    }

    /// The name if there is one, otherwise the rule read back as a sentence with the parts it names set in
    /// monospace — the same shape the editor shows while it is being written.
    private var headline: Text {
        if !rule.name.isEmpty { return Text(rule.name).font(.body.weight(.medium)) }
        let verb = rule.action == .block ? "Block " : "Allow "
        return Text(verb).font(.body.weight(.medium))
            + code(rule.app.isEmpty ? "any app" : rule.app)
            + Text(" reaching ").font(.body.weight(.medium))
            + code(target)
    }

    private func code(_ string: String) -> Text {
        Text(string).font(.body.weight(.medium).monospaced())
    }

    private var target: String {
        var text = rule.destination.isEmpty ? "anywhere" : rule.destination
        if !rule.path.isEmpty { text += rule.path }
        if !rule.method.isEmpty { text = "\(rule.method.uppercased()) \(text)" }
        return text
    }

    private var subject: String {
        "\(rule.app.isEmpty ? "any app" : rule.app) → \(target)"
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
            Text(rule.schedule.describe(at: now, session: RuleStore.session))
                .font(.caption).foregroundStyle(.secondary)
            if rule.hits > 0 {
                Text("·").font(.caption).foregroundStyle(.quaternary)
                Text("\(rule.hits) \(rule.hits == 1 ? "time" : "times")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(events == 1 ? "1 decision kept in the feed" : "\(events) decisions kept in the feed")
                if let last = rule.lastHit {
                    Text("·").font(.caption).foregroundStyle(.quaternary)
                    Text("last \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else if rule.enabled {
                Text("·").font(.caption).foregroundStyle(.quaternary)
                Text("never yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.leading, 38)
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

/// One decision, in the feed. The destination is what someone scans for, so it leads and it is set in monospace;
/// who asked and which rule answered sit under it, and the clock sits where a clock belongs.
private struct EventRow: View {
    let event: RuleEventRecord
    let rule: String
    let showRule: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.action == .block ? "hand.raised.fill" : "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(event.action == .block ? Color.red : Color.green)
                .frame(width: 14)
                .padding(.top, 2)
                .help(event.action == .block ? "Refused" : "Allowed by an exception")
            VStack(alignment: .leading, spacing: 2) {
                Text(destination).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").font(.caption).foregroundStyle(.quaternary)
                    Text(rule).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.engine == .flow ? "Connection" : "Request")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(event.engine == .flow
                          ? "Refused by the Network Extension, before the connection was made"
                          : "Refused by HTTPS inspection, which answered the request itself")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show the Rule…", action: showRule)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "\(event.timestamp.formatted(date: .abbreviated, time: .standard))  "
                    + "\(event.action == .block ? "blocked" : "allowed")  \(who)  \(destination)  \(rule)",
                    forType: .string)
            }
        }
    }

    private var destination: String {
        event.path.isEmpty ? "\(event.destination):\(event.port)"
                           : "\(event.method) \(event.destination)\(event.path)"
    }

    private var who: String {
        event.agentName.isEmpty || event.agentName == event.appName
            ? event.appName : "\(event.agentName) › \(event.appName)"
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
