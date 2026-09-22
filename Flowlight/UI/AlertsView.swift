import SwiftUI

struct AlertsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var alerts: [AlertRecord] = []
    @State private var selection = Set<AlertRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\AlertRecord.timestamp, order: .reverse)]
    @State private var showAcknowledged = false
    @State private var rule: String = ""

    private var rules: [String] { Array(Set(alerts.map(\.kind))).sorted() }

    private var visible: [AlertRecord] {
        alerts.filter { (showAcknowledged || !$0.acknowledged) && (rule.isEmpty || $0.kind == rule) }.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView(alerts.isEmpty ? "No alerts" : "Nothing to review", systemImage: "checkmark.shield",
                                       description: Text(alerts.isEmpty
                                                         ? "Each app has a learning period (24 h by default) before first-contact and spike rules fire."
                                                         : "All matching alerts have been acknowledged."))
            } else {
                table
            }
        }
        .navigationTitle("Alerts")
        .toolbar { toolbar }
        .task(id: monitor.dataVersion) { await load() }
        .task(id: monitor.unacknowledgedAlerts) { await load() }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.severity) { a in
                Image(systemName: a.severity >= 3 ? "exclamationmark.octagon.fill" : a.severity == 2 ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(a.severity >= 3 ? .red : a.severity == 2 ? .orange : .secondary)
                    .opacity(a.acknowledged ? 0.4 : 1)
                    .accessibilityLabel(a.severity >= 3 ? "Critical" : a.severity == 2 ? "Warning" : "Info")
            }
            .width(24)
            TableColumn("Time", value: \.timestamp) { a in
                Text(a.timestamp.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    .help(a.timestamp.formatted(date: .complete, time: .standard))
            }
            .width(min: 130, ideal: 150)
            TableColumn("App", value: \.appName) { a in
                Text(a.appName).help(a.bundleID).foregroundStyle(a.acknowledged ? .secondary : .primary)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Rule", value: \.kind).width(min: 140, ideal: 190)
            TableColumn("Detail", value: \.detail) { a in
                Text(a.detail).lineLimit(2).help(a.detail).foregroundStyle(a.acknowledged ? .secondary : .primary)
            }
        }
        .contextMenu(forSelectionType: AlertRecord.ID.self) { ids in
            Button("Show Traffic in Reports") { if let a = alert(ids.first) { openReport(a) } }.disabled(ids.count != 1)
            Button("Acknowledge") { monitor.acknowledgeAlerts(ids: Array(ids)) }
            Button("Copy Detail") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.compactMap { alert($0)?.detail }.joined(separator: "\n"), forType: .string)
            }
        } primaryAction: { ids in
            if let a = alert(ids.first) { openReport(a) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Rule", selection: $rule) {
                Text("All rules").tag("")
                ForEach(rules, id: \.self) { Text($0).tag($0) }
            }
            .help("Filter by rule")
            .disabled(alerts.isEmpty)
            Toggle("Show acknowledged", isOn: $showAcknowledged).toggleStyle(.checkbox)
                .disabled(alerts.isEmpty)
            Button("Acknowledge") { monitor.acknowledgeAlerts(ids: Array(selection)) }
                .disabled(selection.isEmpty)
                .help("Acknowledge the selected alerts")
            Button("Acknowledge All") { monitor.acknowledgeAlerts(ids: nil) }
                .disabled(monitor.unacknowledgedAlerts == 0)
        }
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
        alerts = (try? await monitor.read { try $0.alerts() }) ?? []
    }
}
