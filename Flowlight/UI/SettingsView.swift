import ServiceManagement
import SwiftUI

struct SettingsView: View {
    typealias K = AnomalySettings.Keys
    @AppStorage(K.sigma) private var sigma = 3.0
    @AppStorage(K.learningHours) private var learningHours = 24.0
    @AppStorage(K.minAlertMB) private var minAlertMB = 1.0
    @AppStorage(K.idleMinutes) private var idleMinutes = 10.0
    @AppStorage(K.idleUploadMB) private var idleUploadMB = 5.0
    @AppStorage(K.firstContact) private var firstContact = true
    @AppStorage(K.nonStandardPorts) private var nonStandardPorts = true
    @AppStorage(K.notifications) private var notifications = true
    @AppStorage(K.retentionHours) private var retentionHours = 6.0
    @AppStorage(K.menuBarRates) private var menuBarRates = true
    @AppStorage(K.agentSensitive) private var agentSensitive = true
    @AppStorage(K.agentUnnamed) private var agentUnnamed = true
    @AppStorage(K.agentEgressMB) private var agentEgressMB = 100.0
    @AppStorage(K.agentAway) private var agentAway = true
    @AppStorage(K.agentAwayMinutes) private var agentAwayMinutes = 15.0
    @AppStorage(AnomalySettings.Keys.backgroundOnly) private var backgroundOnly = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        TabView {
            Form {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError { Text(loginItemError).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $backgroundOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run in the background")
                        Text("No Dock icon and no Cmd-Tab entry. Flowlight keeps recording and stays reachable from the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show live rates in the menu bar", isOn: $menuBarRates)
                Toggle("Show notifications for warnings", isOn: $notifications)
                UpdateSettingsRow()
            }
            .formStyle(.grouped)
            .frame(height: 290)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Stepper(value: $sigma, in: 1.5...10, step: 0.5) { LabeledContent("Z-score threshold", value: "\(sigma.formatted())σ") }
                    Stepper(value: $learningHours, in: 0...336, step: 6) { LabeledContent("Learning period per app", value: "\(Int(learningHours)) h") }
                    Stepper(value: $minAlertMB, in: 0...1000, step: 1) { LabeledContent("Ignore hours below", value: "\(minAlertMB.formatted()) MB") }
                } footer: {
                    Text("Hourly traffic and daily destination counts are compared with each app's rolling baseline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Rules") {
                    Toggle("First contact with a new domain", isOn: $firstContact)
                    Toggle("Connections to non-standard ports", isOn: $nonStandardPorts)
                }
                Section {
                    Toggle("Agent uses email, file transfer, SSH, tunnels or databases", isOn: $agentSensitive)
                    Toggle("Agent connects to a raw IP on an unusual port", isOn: $agentUnnamed)
                    Stepper(value: $agentEgressMB, in: 1...10_000, step: 10) {
                        LabeledContent("Uploads to non-AI hosts above", value: "\(Int(agentEgressMB)) MB/h")
                    }
                    Toggle("Agent active while you're away", isOn: $agentAway)
                    Stepper(value: $agentAwayMinutes, in: 1...240, step: 1) {
                        LabeledContent("Away after", value: "\(Int(agentAwayMinutes)) min without input")
                    }
                    .disabled(!agentAway)
                } header: {
                    Text("AI agents")
                } footer: {
                    Text("Agents are known tools (Claude Code, Codex, Cursor…) and any app that calls an LLM API. They get a 1-hour learning period instead of 24 hours.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Traffic without UI activity") {
                    Stepper(value: $idleMinutes, in: 1...240, step: 1) { LabeledContent("App idle for at least", value: "\(Int(idleMinutes)) min") }
                    Stepper(value: $idleUploadMB, in: 0.5...1000, step: 0.5) { LabeledContent("Uploading more than", value: "\(idleUploadMB.formatted()) MB/min") }
                }
            }
            .formStyle(.grouped)
            .frame(height: 640)
            .tabItem { Label("Detection", systemImage: "waveform.badge.exclamationmark") }

            Form {
                Section {
                    Stepper(value: $retentionHours, in: 1...72, step: 1) { LabeledContent("Keep per-second data", value: "\(Int(retentionHours)) h") }
                } footer: {
                    Text("Minute rollups are kept 14 days, hourly 400 days, daily forever. Alerts are kept 90 days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 150)
            .tabItem { Label("Storage", systemImage: "internaldrive") }

            ExportSettingsTab()
                .tabItem { Label("Export", systemImage: "arrow.up.forward.square") }
        }
        .frame(width: 500)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct MenuBarContent: View {
    @AppStorage(AnomalySettings.Keys.backgroundOnly) private var backgroundOnly = false
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var focus: FocusStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("↓ \(ByteFormat.rate(monitor.currentIn))   ↑ \(ByteFormat.rate(monitor.currentOut))")
        if focus.isActive { Text("Focus: \(focus.summary)") }
        Divider()
        ForEach(monitor.talkers.prefix(5)) { t in
            Text("\(t.name): ↓ \(ByteFormat.rate(t.rateIn))  ↑ \(ByteFormat.rate(t.rateOut))")
        }
        if monitor.unacknowledgedAlerts > 0 {
            Divider()
            Text("\(monitor.unacknowledgedAlerts) unacknowledged alert\(monitor.unacknowledgedAlerts == 1 ? "" : "s")")
        }
        Divider()
        Button("Open Flowlight") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        if backgroundOnly {
            Button("Show Dock Icon") { backgroundOnly = false }
        }
        if !focus.targets.isEmpty {
            Button(focus.isOn ? "Turn Focus Off" : "Turn Focus On") { focus.isOn.toggle() }
        }
        if monitor.unacknowledgedAlerts > 0 {
            Button("Review Alerts…") {
                nav.selection = .alerts
                openWindow(id: "main")
                NSApp.activate()
            }
        }
        if let update = updater.pendingUpdate {
            Button("Update Available: Flowlight \(update.version)…") {
                openWindow(id: "update")
                NSApp.activate()
            }
        } else {
            CheckForUpdatesButton()
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Automatic update checks: the toggle, the last result, and a manual check.
struct UpdateSettingsRow: View {
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check for updates automatically")
                Text("Once a day, Flowlight asks GitHub for the latest release. The request carries only your IP address and Flowlight's version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        LabeledContent("Version \(updater.currentVersion)") {
            HStack(spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Button("Check Now") {
                    openWindow(id: "update")
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.state == .checking)
            }
        }
    }

    private var status: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .available(let r): return "\(r.version) available"
        case .upToDate: return "Up to date"
        case .failed: return "Last check failed"
        case .downloading: return "Downloading…"
        case .ready(let r, _): return "\(r.version) ready to install"
        case .installing: return "Installing…"
        case .idle:
            return updater.lastCheck.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        }
    }
}
