import SwiftUI

/// Writing one rule: what it names, what it does about it, and for how long.
///
/// The sheet is deliberately ordered the way the sentence reads — block or allow, this app, this destination,
/// until then — because a rule someone can't read back is a rule they will be afraid to leave switched on. The
/// sentence at the top is the rule itself, rewritten on every keystroke; the form below is only how it is typed.
struct RuleEditor: View {
    @State var rule: Rule
    let isNew: Bool
    let save: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var appQuery = ""
    @State private var showAdvanced = false

    private var apps: [InstalledApps.App] { InstalledApps.all() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Form {
                Picker(L("Then"), selection: $rule.action) {
                    Text(L("Block it")).tag(Rule.Action.block)
                    Text(L("Allow it")).tag(Rule.Action.allow)
                }
                .pickerStyle(.segmented)

                Section(L("What it names")) {
                    TextField(L("App"), text: $rule.app, prompt: Text(L("Any app — or a name, or a bundle identifier")))
                        .onChange(of: rule.app) { _, new in appQuery = new }
                    if !rule.app.isEmpty, !matchedApps.isEmpty, !exactlyNamed {
                        appSuggestions
                    }
                    TextField(L("Destination"), text: $rule.destination,
                              prompt: Text(L("Anywhere — or a domain, an IP address, or a range")))
                    Text(L("A domain carries its subdomains with it: `example.com` covers `api.example.com`. Naming an agent covers the tools and MCP servers it started."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Section(L("For how long")) {
                    Picker(L("Lasts"), selection: $rule.schedule.kind) {
                        Text(L("Forever")).tag(Rule.Schedule.Kind.always)
                        Text(L("Until a time")).tag(Rule.Schedule.Kind.until)
                        Text(L("Until Flowlight quits")).tag(Rule.Schedule.Kind.session)
                        Text(L("Between chosen hours")).tag(Rule.Schedule.Kind.window)
                    }
                    .onChange(of: rule.schedule.kind) { _, kind in
                        if kind == .until, rule.schedule.until == nil {
                            rule.schedule.until = Date().addingTimeInterval(3600)
                        }
                        if kind == .session { rule.schedule.session = RuleStore.session }
                    }
                    switch rule.schedule.kind {
                    case .until:
                        DatePicker(L("Until"), selection: Binding(
                            get: { rule.schedule.until ?? Date().addingTimeInterval(3600) },
                            set: { rule.schedule.until = $0 }), displayedComponents: [.date, .hourAndMinute])
                    case .window:
                        weekdayPicker
                        HStack {
                            clock(L("From"), minutes: $rule.schedule.start)
                            clock(L("To"), minutes: $rule.schedule.end)
                        }
                        Text(rule.schedule.end <= rule.schedule.start
                             ? L("This window crosses midnight, so it belongs to the day it opened.")
                             : L("Hours are local. A Mac that sleeps through the end of a window finds it closed on waking, and a window closing stops new connections — it doesn't tear down ones already open."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .session:
                        Text(L("Gone when Flowlight quits, including a crash. Nothing is left behind in force."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .always:
                        EmptyView()
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        TextField(L("Path"), text: $rule.path, prompt: Text(L("Any path — or /v1/*")))
                        Picker(L("Method"), selection: $rule.method) {
                            ForEach(MockRule.methods, id: \.self) { method in
                                Text(method).tag(method == "ANY" ? "" : method)
                            }
                        }
                        if rule.action == .block {
                            Picker(L("Answer with"), selection: $rule.status) {
                                ForEach([403, 401, 404, 429, 451, 500, 503], id: \.self) { code in
                                    Text("\(code) \(MockRule.reason(code))").tag(code)
                                }
                            }
                        }
                        Text(L("A path can only be matched where the request can be read, which is HTTPS inspection. That is also what makes this the friendlier refusal: the agent gets a status it can read instead of a connection that died without saying why."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } label: {
                        // The summary a closed row earns: what is set in there, rather than only the offer to look.
                        HStack(spacing: 6) {
                            Text(L("One URL rather than the whole host"))
                            if !advancedSummary.isEmpty {
                                Text(advancedSummary).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }

                Section {
                    TextField(L("Name"), text: $rule.name, prompt: Text(RuleWords.title(rule)))
                }

                // Last, because it answers a question you can only ask once the rule says something — and
                // because the first thing anyone should learn about a blocking rule is what it would break,
                // rather than finding out from something failing later.
                Section(L("What it would have done")) {
                    RuleSimulationView(rule: rule)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !rule.isComplete {
                    Label(L("Name an app or a destination — a rule that names neither would decide every connection on the Mac."),
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(FL.warning).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("Add") : L("Save")) {
                    save(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!rule.isComplete)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 540)
        .frame(minHeight: 520)
    }

    /// The rule, read back, above the fields that make it. An unfinished rule says so here rather than only at the
    /// disabled button, because this is where someone is looking while they type.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: rule.action == .block ? "hand.raised.fill" : "checkmark.shield.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(rule.action == .block ? FL.critical : FL.good)
                    .frame(width: 28, height: 28)
                    .background((rule.action == .block ? FL.critical : FL.good).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isNew ? L("New Rule") : L("Edit Rule")).font(.headline)
                    Text(engineNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            sentence
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.bottom, 4)
    }

    /// Which half of Flowlight would carry this out. It changes as soon as a path is typed, which is the moment
    /// someone has quietly moved from refusing a connection to answering a request.
    private var engineNote: String {
        rule.engine == .flow
            ? L("Refused as a connection, before it is made")
            : L("Answered as a request, with a status the agent can read")
    }

    /// The rule read back as a sentence, which is the only check most people will make. What the rule names is set
    /// in monospace, so the part that has to be typed exactly looks like it.
    ///
    /// The sentence is one key, verb and all — a sentence assembled from a translated preposition and an English
    /// verb reads as neither language. `RuleWords.sentence` fills the placeholders back in as styled `Text`, so a
    /// translator can put the app before or after the destination and still get the monospace where it belongs.
    private var sentence: Text {
        let who = code(rule.app.isEmpty ? L("anything") : rule.app)
        let target = code(destinationPhrase)
        let when = RuleWords.schedule(rule.schedule, at: Date(), session: RuleStore.session)
        let tail = Text(" \(when).").foregroundStyle(.secondary)
        if rule.method.isEmpty {
            let format = rule.action == .block ? L("Refuse %1$@ reaching %2$@.") : L("Allow %1$@ reaching %2$@.")
            return RuleWords.sentence(format, [who, target]) + tail
        }
        let format = rule.action == .block
            ? L("Refuse %1$@ requests from %2$@ to %3$@.")
            : L("Allow %1$@ requests from %2$@ to %3$@.")
        return RuleWords.sentence(format, [code(rule.method.uppercased()), who, target]) + tail
    }

    private func code(_ string: String) -> Text {
        Text(string).font(.body.monospaced())
    }

    private var destinationPhrase: String {
        var target = rule.destination.isEmpty ? L("anywhere") : rule.destination
        if !rule.path.isEmpty { target += rule.path }
        return target
    }

    /// What the advanced section holds while it is closed.
    private var advancedSummary: String {
        var parts: [String] = []
        if !rule.method.isEmpty { parts.append(rule.method.uppercased()) }
        if !rule.path.isEmpty { parts.append(rule.path) }
        if !parts.isEmpty, rule.action == .block { parts.append("→ \(rule.status)") }
        return parts.joined(separator: " ")
    }

    private var matchedApps: [InstalledApps.App] { Array(InstalledApps.search(rule.app, in: apps).prefix(5)) }
    private var exactlyNamed: Bool {
        apps.contains { $0.bundleID.caseInsensitiveCompare(rule.app) == .orderedSame }
    }

    private var appSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matchedApps) { app in
                Button {
                    rule.app = app.bundleID
                } label: {
                    HStack(spacing: 6) {
                        Text(app.name).font(.callout)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = rule.schedule.days.isEmpty || rule.schedule.days.contains(day)
                Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                    var days = rule.schedule.days.isEmpty ? Array(1...7) : rule.schedule.days
                    if days.contains(day) { days.removeAll { $0 == day } } else { days.append(day) }
                    rule.schedule.days = days.count == 7 ? [] : days.sorted()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? FL.accent : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(on ? FL.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func clock(_ label: String, minutes: Binding<Int>) -> some View {
        DatePicker(label, selection: Binding(
            get: { Calendar.current.date(bySettingHour: (minutes.wrappedValue / 60) % 24,
                                         minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}
