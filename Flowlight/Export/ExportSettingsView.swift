import AppKit
import Security
import SwiftUI

/// Settings › Export.
///
/// Every part of this tab exists to make one question answerable *before* the switch goes on: what exactly will
/// my collector see? So the endpoint, the format, the interval and the field list are all on the page rather than
/// behind an Advanced disclosure, the list of fields is generated from `ExportField` so it can't drift from what
/// the code sends, and there is a preview built from the reader's own traffic for the cases a list doesn't cover.
struct ExportSettingsTab: View {
    @EnvironmentObject var monitor: TrafficMonitor
    typealias Keys = ExportConfiguration.Keys

    @AppStorage(Keys.endpoint) private var endpoint = ""
    @AppStorage(Keys.mode) private var mode = ExportMode.otlp.rawValue
    @AppStorage(Keys.intervalSeconds) private var interval = 60.0
    @AppStorage(Keys.includeRollups) private var includeRollups = true
    @AppStorage(Keys.includeAlerts) private var includeAlerts = true
    @AppStorage(Keys.serviceName) private var serviceName = "flowlight"
    @AppStorage(Keys.includeHostName) private var includeHostName = true

    /// Edited in the view and written to the Keychain on change, so the values are never in a @AppStorage.
    @State private var headers: [HeaderRow] = []
    @State private var headerError: String?
    @State private var showPreview = false
    @State private var preview = ""
    @State private var loadingPreview = false

    private struct HeaderRow: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    private var exporter: ExportController { monitor.exporter }
    private var config: ExportConfiguration { .load() }

    var body: some View {
        Form {
            switchSection
            endpointSection
            headerSection
            contentSection
            fieldsSection
            checkSection
            statusSection
        }
        .formStyle(.grouped)
        .frame(height: 700)
        .onAppear(perform: loadHeaders)
        .sheet(isPresented: $showPreview) { previewSheet }
    }

    // MARK: Sections

    private var switchSection: some View {
        Section {
            Toggle(isOn: Binding(get: { exporter.enabled }, set: { exporter.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Send to my collector"))
                    Text(exporter.enabled
                         ? "On. Flowlight is sending to the endpoint below."
                         : "Off. Nothing about your traffic leaves this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(config.endpointURL == nil || !(includeRollups || includeAlerts))
        } header: {
            Text(L("Export to OpenTelemetry / SIEM"))
        } footer: {
            Text("""
            Flowlight has no service of its own and never will: the endpoint below is yours. This is off until you \
            fill it in and turn it on, and turning it on starts from that moment — what was recorded before the \
            decision stays in the local database. Turning it off again discards whatever was waiting to be sent.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var endpointSection: some View {
        Section(L("Endpoint")) {
            Picker(L("Format"), selection: $mode) {
                ForEach(ExportMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: mode) { _, _ in exporter.settingsChanged() }
            TextField(L("Endpoint"), text: $endpoint, prompt: Text(L("https://collector.example.com:4318")))
                .textFieldStyle(.roundedBorder)
                .onChange(of: endpoint) { _, _ in exporter.settingsChanged() }
            if config.endpointURL == nil {
                Text(endpoint.isEmpty ? "No endpoint yet." : "That isn't an http:// or https:// address with a host in it.")
                    .font(.caption).foregroundStyle(endpoint.isEmpty ? Color.secondary : Color.red)
            } else {
                ForEach(exporter.destinations, id: \.self) { url in
                    Text("POST \(url)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var headerSection: some View {
        Section {
            ForEach($headers) { $row in
                HStack(spacing: 8) {
                    TextField(L("Name"), text: $row.name, prompt: Text(L("Authorization")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    SecureField(L("Value"), text: $row.value, prompt: Text(L("Bearer …")))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        headers.removeAll { $0.id == row.id }
                        saveHeaders()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Remove this header"))
                }
                .onChange(of: row) { _, _ in saveHeaders() }
            }
            Button(L("Add Header")) { headers.append(HeaderRow()) }
            if let headerError {
                Text(headerError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(L("Headers"))
        } footer: {
            Text("""
            Header values are kept in your login Keychain, not in Flowlight's preferences — a token for your \
            collector shouldn't sit in a file every process running as you can read.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contentSection: some View {
        Section {
            Toggle(L("Per-app and destination rollups"), isOn: $includeRollups)
                .onChange(of: includeRollups) { _, _ in exporter.settingsChanged() }
            Toggle(L("Alerts"), isOn: $includeAlerts)
                .onChange(of: includeAlerts) { _, _ in exporter.settingsChanged() }
            Stepper(value: $interval, in: 10...3600, step: 10) {
                LabeledContent("Send every", value: "\(Int(interval)) s")
            }
            .onChange(of: interval) { _, _ in exporter.settingsChanged() }
            TextField(L("Service name"), text: $serviceName, prompt: Text(L("flowlight")))
                .textFieldStyle(.roundedBorder)
                .onChange(of: serviceName) { _, _ in exporter.settingsChanged() }
            Toggle(L("Include this Mac's host name"), isOn: $includeHostName)
                .onChange(of: includeHostName) { _, _ in exporter.settingsChanged() }
        } header: {
            Text(L("What Flowlight sends"))
        } footer: {
            Text("""
            A rollup is one app, one hostname and one IP address added up over the window, at the same minute \
            granularity Reports uses — never per connection and never per packet. Rollups go about two minutes \
            behind, once the minute they belong to is complete; alerts go as they are raised. A collector that \
            can't be reached is retried with a growing delay, and at most 10,000 records are held while it's down.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fieldsSection: some View {
        Section {
            DisclosureGroup("Every field that can leave this Mac (\(ExportField.allCases.count))") {
                ForEach(ExportField.allCases) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.rawValue).font(.caption.monospaced())
                        Text(field.what).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        } footer: {
            Text("""
            That list is the whole of it — it is generated from the same declaration the payload is built from, so \
            it can't fall behind the code. Never sent, in any format and whatever else is switched on: anything \
            HTTPS inspection records. Request and response headers, bodies, tool calls and the contents of any \
            decrypted exchange have no path into an export.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var checkSection: some View {
        Section {
            Button(L("Show What Would Be Sent…")) {
                loadingPreview = true
                showPreview = true
                Task {
                    preview = await exporter.preview()
                    loadingPreview = false
                }
            }
            LabeledContent("Test connection") {
                HStack(spacing: 8) {
                    Text(testSummary).font(.caption).foregroundStyle(testColour)
                    Button(L("Test")) { Task { await exporter.testConnection() } }
                        .disabled(config.endpointURL == nil || exporter.testState == .running)
                }
            }
        } footer: {
            Text("""
            The preview is built from your own traffic and is never sent. Test connection sends the smallest thing \
            the format allows — an OpenTelemetry request with no records in it, or one line marked as a test — and \
            reports what the collector actually answered.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Last successful export",
                           value: exporter.lastSuccess.map { "\($0.formatted(.relative(presentation: .named))) · \(exporter.lastRecordsSent) records" }
                               ?? "Never")
            LabeledContent("Last error") {
                Text(exporter.lastError ?? "None").foregroundStyle(exporter.lastError == nil ? Color.secondary : Color.red)
            }
            LabeledContent("Waiting to be sent", value: "\(exporter.buffered) records")
            if exporter.dropped > 0 {
                LabeledContent("Dropped") {
                    Text("\(exporter.dropped) records").foregroundStyle(.orange)
                }
            }
            if let next = exporter.nextAttempt, next > Date() {
                LabeledContent("Retrying", value: next.formatted(.relative(presentation: .named)))
            }
        } header: {
            Text(L("Status"))
        } footer: {
            Text("""
            Exports leave as Flowlight's own traffic, so you'll see them in Live and Reports like any other app's, \
            and the first time they go somewhere new you'll get a first-contact alert about Flowlight.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("What would be sent")).font(.headline)
            if loadingPreview {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                }
                .disabled(loadingPreview)
                Spacer()
                Button(L("Done")) { showPreview = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 480)
    }

    // MARK: Headers

    private var testSummary: String {
        switch exporter.testState {
        case .idle: return "Not tested"
        case .running: return "Testing…"
        case .succeeded(let message): return message
        case .failed(let message): return message
        }
    }

    private var testColour: Color {
        switch exporter.testState {
        case .succeeded: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func loadHeaders() {
        headers = ExportSecrets.load().sorted { $0.key < $1.key }.map { HeaderRow(name: $0.key, value: $0.value) }
    }

    private func saveHeaders() {
        var merged: [String: String] = [:]
        for row in headers { merged[row.name.trimmingCharacters(in: .whitespacesAndNewlines)] = row.value }
        let status = ExportSecrets.save(merged)
        headerError = status == errSecSuccess ? nil
            : "Couldn't save to the Keychain: \((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")"
    }
}
