import SwiftUI

enum AlertRuleSelection {
    static func retained(_ rule: String, in alerts: [AlertRecord]) -> String {
        rule.isEmpty || alerts.contains(where: { $0.kind == rule }) ? rule : ""
    }
}

struct AlertsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var focus: FocusStore
    @State private var alerts: [AlertRecord] = []
    @State private var selection = Set<AlertRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\AlertRecord.timestamp, order: .reverse)]
    @State private var triageFilter: AlertTriageFilter = .open
    @State private var rule: String = ""
    @State private var noteAlert: AlertRecord?
    @State private var noteDraft = ""

    private var rules: [String] { Array(Set(alerts.map(\.kind))).sorted() }

    private struct LoadKey: Equatable {
        var version: Int
        var newAlerts: Int
        var focus: FocusScope
        var tab: AlertsTab
        var filter: AlertTriageFilter
    }

    private var visible: [AlertRecord] {
        alerts.filter { rule.isEmpty || $0.kind == rule }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Alerts"), selection: $nav.alertsTab) {
                ForEach(AlertsTab.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, 10)

            Divider()

            Group {
                if nav.alertsTab == .detection {
                    DetectionSettingsView()
                } else if visible.isEmpty {
                    ContentUnavailableView(alerts.isEmpty ? L("No matching alerts") : L("Nothing matches this rule"),
                                           systemImage: "checkmark.shield",
                                           description: Text(emptyDescription))
                } else {
                    table
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L("Alerts"))
        .navigationSubtitle(nav.alertsTab == .detection ? L("Detection") : alertSubtitle)
        .toolbar { toolbar }
        .task(id: LoadKey(version: monitor.dataVersion, newAlerts: monitor.unacknowledgedAlerts,
                          focus: focus.scope, tab: nav.alertsTab, filter: triageFilter)) {
            await load()
        }
        .sheet(item: $noteAlert) { alert in noteEditor(alert) }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.severity) { a in
                Image(systemName: a.severity >= 3 ? "exclamationmark.octagon.fill" : a.severity == 2 ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(a.severity >= 3 ? FL.critical : a.severity == 2 ? FL.warning : .secondary)
                    .opacity(a.state == .new ? 1 : 0.55)
                    .accessibilityLabel(a.severity >= 3 ? L("Critical") : a.severity == 2 ? L("Warning") : L("Info"))
            }
            .width(24)
            TableColumn(L("Time"), value: \.timestamp) { a in
                Text(a.timestamp.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    .help(a.timestamp.formatted(date: .complete, time: .standard))
            }
            .width(min: 130, ideal: 150)
            TableColumn(L("App"), value: \.appName) { a in
                Text(a.appName).help(a.bundleID).foregroundStyle(rowStyle(a))
            }
            .width(min: 100, ideal: 150)
            TableColumn(L("State")) { a in
                Text(a.state.title).foregroundStyle(rowStyle(a))
            }
            .width(min: 95, ideal: 115)
            TableColumn(L("Disposition")) { a in
                Text(a.disposition.title).foregroundStyle(a.disposition == .unset ? .secondary : rowStyle(a))
            }
            .width(min: 110, ideal: 145)
            // The stored kind is English — it is a database value as much as a label — so the column shows the
            // same sentence in the chosen language rather than the row as it was written.
            TableColumn(L("Rule"), value: \.kind) { a in
                Text(AnomalyEngine.Kind.localizedName(a.kind)).foregroundStyle(rowStyle(a))
            }
            .width(min: 140, ideal: 190)
            TableColumn(L("Detail"), value: \.detail) { a in
                HStack(spacing: 6) {
                    Text(a.detail).lineLimit(2).help(a.detail).foregroundStyle(rowStyle(a))
                    if !a.note.isEmpty {
                        Image(systemName: "note.text").foregroundStyle(.secondary).help(a.note)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: AlertRecord.ID.self) { ids in
            triageActions(ids)
            Divider()
            // Allow actions remain policy changes, separate from triage metadata and its lifecycle.
            if let a = alert(ids.first), !a.allowPattern.isEmpty {
                Button(L("Allow %@ for %@ from Now On", a.allowPattern, a.appName)) {
                    monitor.allowFromNowOn(pattern: a.allowPattern, agentID: a.bundleID)
                }
                Menu(L("Allow %@ for %@…", a.allowPattern, a.appName)) {
                    Button(L("Just once")) {
                        monitor.rules.save(RuleStore.allow(app: a.bundleID, destination: a.allowPattern,
                                                           once: true, origin: .allowOnce))
                    }
                    Button(L("For an hour")) {
                        monitor.rules.save(RuleStore.allow(app: a.bundleID, destination: a.allowPattern,
                                                           forSeconds: 3600))
                    }
                    Button(L("Until Flowlight quits")) {
                        var rule = RuleStore.allow(app: a.bundleID, destination: a.allowPattern)
                        rule.schedule = .thisSession(RuleStore.session)
                        monitor.rules.save(rule)
                    }
                    Divider()
                    Button(L("Edit a rule instead…")) {
                        nav.writeRule(RuleStore.allow(app: a.bundleID, destination: a.allowPattern, origin: .alert))
                    }
                }
                Divider()
            }
            Button(L("Show Traffic in History")) { if let a = alert(ids.first) { openReport(a) } }
                .disabled(ids.count != 1)
            Button(L("Copy Detail")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.compactMap { alert($0)?.detail }.joined(separator: "\n"), forType: .string)
            }
        } primaryAction: { ids in
            if let a = alert(ids.first) { openReport(a) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if nav.alertsTab == .alerts {
            ToolbarItemGroup {
                Menu {
                    Picker(L("Status"), selection: $triageFilter) {
                        ForEach(AlertTriageFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker(L("Rule"), selection: $rule) {
                        Text(L("All rules")).tag("")
                        ForEach(rules, id: \.self) { Text(AnomalyEngine.Kind.localizedName($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(filterLabel, systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                               : "line.3.horizontal.decrease.circle")
                }
                .labelStyle(.titleAndIcon)
                .help(L("Filter which alerts are listed"))

                Menu {
                    triageActions(selection)
                    Divider()
                    Button(L("Acknowledge all new (%lld)", monitor.unacknowledgedAlerts)) {
                        let scope = focus.scope
                        Task { await monitor.acknowledgeAlerts(ids: nil, focus: scope) }
                    }
                    .disabled(monitor.unacknowledgedAlerts == 0)
                } label: {
                    Label(L("Triage"), systemImage: "checkmark.circle")
                }
                .labelStyle(.titleAndIcon)
                .help(L("Update the selected alerts"))
            }
        }
    }

    @ViewBuilder
    private func triageActions(_ ids: Set<AlertRecord.ID>) -> some View {
        let selected = ids.compactMap { alert($0) }
        Menu(L("Set State")) {
            ForEach(AlertTriageState.allCases, id: \.self) { state in
                Button(state.title) {
                    let selectedIDs = Array(ids)
                    Task { await monitor.setAlertTriageState(state, ids: selectedIDs) }
                }
                    .disabled(selected.isEmpty || selected.contains { !$0.state.canTransition(to: state) })
            }
        }
        .disabled(selected.isEmpty)
        Menu(L("Set Disposition")) {
            ForEach(AlertDisposition.allCases, id: \.self) { disposition in
                Button(disposition.title) {
                    let selectedIDs = Array(ids)
                    Task { await monitor.setAlertDisposition(disposition, ids: selectedIDs) }
                }
            }
        }
        .disabled(selected.isEmpty)
        Button(L("Edit Note…")) {
            guard let alert = selected.first else { return }
            noteDraft = alert.note
            noteAlert = alert
        }
        .disabled(selected.count != 1)
    }

    private func noteEditor(_ alert: AlertRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Triage Note")).font(.headline)
            Text(alert.appName).foregroundStyle(.secondary)
            TextEditor(text: $noteDraft)
                .font(.body)
                .frame(minHeight: 150)
                .onChange(of: noteDraft) { _, value in
                    if value.count > AlertRecord.maximumNoteLength {
                        noteDraft = String(value.prefix(AlertRecord.maximumNoteLength))
                    }
                }
            Text("\(noteDraft.count) / \(AlertRecord.maximumNoteLength)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Spacer()
                Button(L("Cancel")) { noteAlert = nil }
                Button(L("Save")) {
                    let note = noteDraft
                    Task {
                        if await monitor.setAlertNote(note, id: alert.id) {
                            noteAlert = nil
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 300)
    }

    private var isFiltered: Bool { !rule.isEmpty || triageFilter != .open }

    private var filterLabel: String {
        rule.isEmpty ? triageFilter.title : L("%@ · %@", triageFilter.title, AnomalyEngine.Kind.localizedName(rule))
    }

    private var alertSubtitle: String {
        guard !visible.isEmpty else { return "" }
        switch triageFilter {
        case .open:
            let newCount = visible.filter { $0.state == .new }.count
            return newCount == 0 ? L("%lld open, no new", visible.count)
                : L("%lld new of %lld open", newCount, visible.count)
        case .investigating: return L("%lld investigating", visible.count)
        case .resolved: return L("%lld resolved", visible.count)
        case .dismissed: return L("%lld dismissed", visible.count)
        }
    }

    private var emptyDescription: String {
        switch triageFilter {
        case .open: return L("No open alerts match the current Focus scope.")
        case .investigating: return L("No alerts are being investigated in the current Focus scope.")
        case .resolved: return L("No resolved alerts match the current Focus scope.")
        case .dismissed: return L("No dismissed alerts match the current Focus scope.")
        }
    }

    private func rowStyle(_ alert: AlertRecord) -> Color {
        alert.state.isClosed ? .secondary : .primary
    }

    private func alert(_ id: AlertRecord.ID?) -> AlertRecord? {
        alerts.first { $0.id == id }
    }

    /// Opens the app's traffic in the window leading up to the alert.
    private func openReport(_ alert: AlertRecord) {
        nav.showReport(filter: TrafficFilter(bundleID: alert.bundleID), granularity: .minute,
                       end: alert.timestamp.addingTimeInterval(10 * 60))
    }

    private func load() async {
        guard nav.alertsTab == .alerts else { return }
        let scope = focus.scope
        let filter = triageFilter
        let loaded = (try? await monitor.read { try $0.alerts(focus: scope, triageFilter: filter) }) ?? []
        guard !Task.isCancelled, nav.alertsTab == .alerts,
              focus.scope == scope, triageFilter == filter else { return }
        rule = AlertRuleSelection.retained(rule, in: loaded)
        alerts = loaded
        selection.formIntersection(alerts.map(\.id))
    }
}

private extension AlertTriageState {
    var title: String {
        switch self {
        case .new: return L("New")
        case .acknowledged: return L("Acknowledged")
        case .investigating: return L("Investigating")
        case .resolved: return L("Resolved")
        case .dismissed: return L("Dismissed")
        }
    }
}

private extension AlertDisposition {
    var title: String {
        switch self {
        case .unset: return L("Unset")
        case .truePositive: return L("True positive")
        case .expectedBenign: return L("Expected / benign")
        case .falsePositive: return L("False positive")
        }
    }
}

private extension AlertTriageFilter {
    var title: String {
        switch self {
        case .open: return L("Open")
        case .investigating: return L("Investigating")
        case .resolved: return L("Resolved")
        case .dismissed: return L("Dismissed")
        }
    }
}
