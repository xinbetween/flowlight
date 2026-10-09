import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    typealias K = AnomalySettings.Keys
    @AppStorage(K.sigma) private var sigma = 3.0
    @AppStorage(K.learningHours) private var learningHours = 24.0
    @AppStorage(K.minAlertMB) private var minAlertMB = 1.0
    @AppStorage(K.idleMinutes) private var idleMinutes = 10.0
    @AppStorage(K.idleUploadMB) private var idleUploadMB = 5.0
    @AppStorage(K.firstContact) private var firstContact = true
    @AppStorage(K.nonStandardPorts) private var nonStandardPorts = true
    @AppStorage(K.ignoreAppleApps) private var ignoreAppleApps = true
    @AppStorage(K.notifications) private var notifications = true
    @AppStorage(K.retentionHours) private var retentionHours = 6.0
    @AppStorage(K.menuBarRates) private var menuBarRates = true
    @AppStorage(K.agentSensitive) private var agentSensitive = true
    @AppStorage(K.agentUnnamed) private var agentUnnamed = true
    @AppStorage(K.agentEgressMB) private var agentEgressMB = 100.0
    @AppStorage(K.agentAway) private var agentAway = true
    @AppStorage(K.agentAwayMinutes) private var agentAwayMinutes = 15.0
    @AppStorage(AnomalySettings.Keys.backgroundOnly) private var backgroundOnly = false
    // Read once the pane is on screen, never in the property's default expression: that
    // expression re-runs every time this struct is constructed, and `Settings { }` is
    // rebuilt whenever the App body is invalidated — which TrafficMonitor does every
    // second. SMAppService.status is a synchronous XPC round trip to smd, so the default
    // form put blocking IPC on the main thread at 1 Hz for the life of the process.
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @State private var showClearLocalRiskConfirmation = false

    var body: some View {
        TabView {
            Form {
                LanguageRow()
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    .task { launchAtLogin = SMAppService.mainApp.status == .enabled }
                if let loginItemError { Text(loginItemError).font(.caption).foregroundStyle(FL.critical) }
                Toggle(isOn: $backgroundOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Run in the background"))
                        Text(L("No Dock icon and no Cmd-Tab entry. Flowlight keeps recording and stays reachable from the menu bar."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(L("Show live rates in the menu bar"), isOn: $menuBarRates)
                Toggle(L("Show notifications for warnings"), isOn: $notifications)
                UpdateSettingsRow()
            }
            .formStyle(.grouped)
            .frame(height: 340)
            .tabItem { Label(L("General"), systemImage: "gearshape") }

            Form {
                Section {
                    Stepper(value: $sigma, in: 1.5...10, step: 0.5) { LabeledContent(L("Z-score threshold"), value: "\(sigma.formatted())σ") }
                    Stepper(value: $learningHours, in: 0...336, step: 6) { LabeledContent(L("Learning period per app"), value: L("%lld h", Int(learningHours))) }
                    Stepper(value: $minAlertMB, in: 0...1000, step: 1) { LabeledContent(L("Ignore hours below"), value: L("%@ MB", minAlertMB.formatted())) }
                } footer: {
                    Text(L("Hourly traffic and daily destination counts are compared with each app's rolling baseline."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Rules")) {
                    Toggle(L("First contact with a new domain"), isOn: $firstContact)
                    Toggle(L("Connections to non-standard ports"), isOn: $nonStandardPorts)
                    Toggle(L("Ignore Apple's own apps"), isOn: $ignoreAppleApps)
                    Text(L("macOS talks to Apple constantly — updates, iCloud, push, time — and reporting all of it buries the one line that matters. Their traffic is still recorded, still shown in Live and Reports, and still subject to every rule and guardrail."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(L("Agent uses email, file transfer, SSH, tunnels or databases"), isOn: $agentSensitive)
                    Toggle(L("Agent connects to a raw IP on an unusual port"), isOn: $agentUnnamed)
                    Stepper(value: $agentEgressMB, in: 1...10_000, step: 10) {
                        LabeledContent(L("Uploads to non-AI hosts above"), value: L("%lld MB/h", Int(agentEgressMB)))
                    }
                    Toggle(L("Agent active while you're away"), isOn: $agentAway)
                    Stepper(value: $agentAwayMinutes, in: 1...240, step: 1) {
                        LabeledContent(L("Away after"), value: L("%lld min without input", Int(agentAwayMinutes)))
                    }
                    .disabled(!agentAway)
                } header: {
                    Text(L("AI agents"))
                } footer: {
                    Text(L("Agents include recognized tools such as Claude Code, Codex and Cursor, plus non-browser apps that contact a known LLM API provider. Their learning period is 1 hour instead of 24 hours."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Traffic without UI activity")) {
                    Stepper(value: $idleMinutes, in: 1...240, step: 1) { LabeledContent(L("App idle for at least"), value: L("%lld min", Int(idleMinutes))) }
                    Stepper(value: $idleUploadMB, in: 0.5...1000, step: 0.5) { LabeledContent(L("Uploading more than"), value: L("%@ MB/min", idleUploadMB.formatted())) }
                }
                LocalRiskSettingsSection(showClearConfirmation: $showClearLocalRiskConfirmation)
            }
            .formStyle(.grouped)
            .frame(height: 640)
            .tabItem { Label(L("Detection"), systemImage: "waveform.badge.exclamationmark") }

            Form {
                Section {
                    Stepper(value: $retentionHours, in: 1...72, step: 1) { LabeledContent(L("Keep per-second data"), value: L("%lld h", Int(retentionHours))) }
                } footer: {
                    Text(L("Minute rollups are kept 14 days, hourly 400 days, daily forever. Alerts are kept 90 days."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 150)
            .tabItem { Label(L("Storage"), systemImage: "internaldrive") }

            PluginSettingsView()
                .tabItem { Label(L("Plugins"), systemImage: "puzzlepiece.extension") }

            ExportSettingsTab()
                .tabItem { Label(L("Export"), systemImage: "arrow.up.forward.square") }
        }
        .frame(width: 500)
        .confirmationDialog(L("Clear local analyses?"), isPresented: $showClearLocalRiskConfirmation, titleVisibility: .visible) {
            Button(L("Clear analyses"), role: .destructive) { monitor.clearLocalRiskAnalyses() }
        } message: {
            Text(L("This removes only local potential-harm scores and explanations. Recorded requests, response bodies, alerts, rules, and inspection settings stay in place."))
        }
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
        if focus.isActive { Text(L("Focus: %@", focus.summary)) }
        Divider()
        ForEach(monitor.talkers.prefix(5)) { t in
            Text("\(t.name): ↓ \(ByteFormat.rate(t.rateIn))  ↑ \(ByteFormat.rate(t.rateOut))")
        }
        if monitor.unacknowledgedAlerts > 0 {
            Divider()
            // Singular and plural are whole sentences rather than a stem with an "s" bolted on: the plural of a
            // noun is not a suffix in most of the languages Flowlight speaks.
            Text(monitor.unacknowledgedAlerts == 1 ? L("%lld unacknowledged alert", monitor.unacknowledgedAlerts)
                                                   : L("%lld unacknowledged alerts", monitor.unacknowledgedAlerts))
        }
        Divider()
        Button(L("Open Flowlight")) {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        if backgroundOnly {
            Button(L("Show Dock Icon")) { backgroundOnly = false }
        }
        if !focus.targets.isEmpty {
            Button(focus.isOn ? L("Turn Focus Off") : L("Turn Focus On")) { focus.isOn.toggle() }
        }
        if monitor.unacknowledgedAlerts > 0 {
            Button(L("Review Alerts…")) {
                nav.selection = .alerts
                openWindow(id: "main")
                NSApp.activate()
            }
        }
        if let update = updater.pendingUpdate {
            Button(L("Update Available: Flowlight %@…", update.version)) {
                openWindow(id: "update")
                NSApp.activate()
            }
        } else {
            CheckForUpdatesButton()
        }
        Button(L("Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Automatic update checks: the toggle, the last result, and a manual check.
struct UpdateSettingsRow: View {
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Check for updates automatically"))
                Text(L("Once a day, Flowlight asks GitHub for the latest release. The request carries only your IP address and Flowlight's version."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        LabeledContent(L("Version %@", updater.currentVersion)) {
            HStack(spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Button(L("Check Now")) {
                    openWindow(id: "update")
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.state == .checking)
            }
        }
    }

    private var status: String {
        switch updater.state {
        case .checking: return L("Checking…")
        case .available(let r): return L("%@ available", r.version)
        case .upToDate: return L("Up to date")
        case .failed: return L("Last check failed")
        case .downloading: return L("Downloading…")
        case .ready(let r, _): return L("%@ ready to install", r.version)
        case .installing: return L("Installing…")
        case .idle:
            return updater.lastCheck.map { L("Checked %@", $0.formatted(.relative(presentation: .named))) } ?? L("Not checked yet")
        }
    }
}

/// Choosing the interface language.
///
/// "System" is the default and the honest one, but it leaves someone guessing which language that turned out to
/// be — so when it is chosen the row says underneath what is actually being shown.
private struct LanguageRow: View {
    @ObservedObject private var localization = Localization.shared
    @State private var confirming: AppLanguage?
    @State private var failure: String?

    var body: some View {
        // One Group so the dialogs below attach to something: the rows themselves are a tuple, and a modifier
        // on a tuple is a modifier on nothing.
        Group {
            Picker(L("Language"), selection: Binding(get: { localization.language },
                                                     set: { confirming = $0 })) {
                Text(L("System")).tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.translated) { language in
                    // Each written in its own language: someone looking for theirs is not reading the others.
                    Text(language.title).tag(language)
                }
            }
            if localization.language == .system {
                Text(L("Now showing %@", localization.effective.title))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("The interface follows your Mac's language when this is set to System, and falls back to English for languages Flowlight hasn't been translated into."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Changing it restarts Flowlight, so the menus macOS draws change too. The Network Extension keeps filtering while it does."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(L("Restart Flowlight in this language?"), isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(L("Restart")) {
                // Stored first, so the copy that starts in a moment reads the new choice.
                if let chosen = confirming { localization.language = chosen }
                confirming = nil
                AppRestart.now { failure = $0 }
            }
            Button(L("Cancel"), role: .cancel) { confirming = nil }
        } message: {
            Text(L("The window follows the new language straight away; the application menu, the open and save panels and the standard buttons only change when Flowlight starts again."))
        }
        .alert(L("Flowlight couldn't restart itself"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L("OK")) { failure = nil }
        } message: {
            // The language is already saved either way, so quitting and opening it again finishes the job.
            Text(L("%@ — the language is saved, so quitting and opening Flowlight again will finish the change.",
                   failure ?? ""))
        }
    }
}
