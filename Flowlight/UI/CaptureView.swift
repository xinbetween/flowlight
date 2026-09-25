import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var extensionManager: ExtensionManager
    @State private var confirmClear = false
    @State private var showExtensionSetup = false
    @State private var otherFilters: [InstalledSystemExtension] = []

    /// The dot beside the status line. Three states, because there are three: nothing arriving, arriving from the
    /// source that was chosen, and arriving from the one that stepped in when that source gave up.
    private var statusColor: Color {
        if monitor.extensionFellBack { return .yellow }
        return monitor.isReceiving ? .green : .orange
    }

    private var extensionDetailsVisible: Bool {
        monitor.mode == .networkExtension || showExtensionSetup
    }

    var body: some View {
        Form {
            Section("Capture source") {
                Picker("Source", selection: Binding(get: { monitor.mode }, set: { monitor.setMode($0) })) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                CaptureWarningBanner()
                if !otherFilters.isEmpty { OtherFiltersNotice(filters: otherFilters) }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        // Green means "data is arriving from the source you chose". After a fallback the sampler
                        // is genuinely receiving, so a plain green dot beside a line explaining that the extension
                        // failed would contradict itself. Yellow is that third state: working, but not as asked.
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(monitor.status)
                    }
                }
            }

            Section {
                LabeledContent("Extension", value: extensionManager.state.label)
                if monitor.mode == .nettop {
                    Button(showExtensionSetup ? "Hide extension setup" : "Show extension setup…") {
                        showExtensionSetup.toggle()
                    }
                }
                if extensionDetailsVisible {
                    if let blocker = extensionManager.blocker {
                        Label(blocker, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Install & enable filter") { extensionManager.activate() }
                            .disabled(extensionManager.blocker != nil)
                        Button("Disable filter") { extensionManager.setFilterEnabled(false) }
                            .disabled(extensionManager.state != .enabled)
                        Button("Uninstall") { extensionManager.deactivate() }
                            .disabled(!extensionManager.hasEntitlement)
                        Button("Refresh") {
                            extensionManager.refresh()
                            // Also redial the extension: reloading its settings tells you nothing about whether
                            // the app can actually reach it, which is the part that looked broken.
                            monitor.reconnectSource()
                        }
                        .help("Re-check the filter and reconnect to it")
                        if monitor.extensionFellBack {
                            Button("Try the extension again") { monitor.reconnectSource() }
                                .help("Stop sampling with nettop and reconnect to the filter extension")
                        }
                    }
                    if monitor.extensionFellBack {
                        Text("Flowlight couldn't reach the filter extension and is sampling with nettop so you still "
                             + "get data. Your chosen source is still the extension.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("""
                    The content filter (NEFilterDataProvider) attributes every TCP/UDP flow to its app via the audit token, \
                    extracts TLS SNI, HTTP Host and DNS answers, and sends one-second summaries to this app over XPC. \
                    It requires the Network Extension entitlement (content-filter-provider-systemextension) on a paid \
                    developer team, and the app must be in the Applications folder. It never blocks traffic.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    Label {
                        Text("""
                        **Nothing short-lived escapes it.** macOS calls the filter as each connection is made, so a request \
                        that lasts five milliseconds is recorded like any other. It also costs less energy than sampling, \
                        which starts a process every second. Traffic from before you enable it isn't there, some system \
                        traffic is exempt from content filters, and byte counts come from the filter's own statistics.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green)
                    }
                    Label {
                        Text("""
                        **It keeps filtering after you quit Flowlight.** A system extension runs on its own, so the \
                        filter carries on inspecting connections and holding what it sees until you press Disable or \
                        Uninstall above. Nothing reaches this app while it isn't running, but the filter is still there.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    Label {
                        Text("""
                        **macOS runs one content filter at a time.** If a VPN or security agent already has that slot — \
                        Palo Alto Networks GlobalProtect, CrowdStrike Falcon and similar all use it — Flowlight's filter installs and \
                        connects but is never asked to filter anything, so nothing appears. Use the sampler on those Macs.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Network Extension")
            }

            if monitor.mode == .nettop { HostnameSection() }

            Section {
                Text("""
                Without the extension, Flowlight reads /usr/bin/nettop once per second. You get per-process, \
                per-connection byte counts with no entitlements, and protocols from port heuristics.
                """)
                .font(.callout).foregroundStyle(.secondary)
                Label {
                    Text("""
                    **What it misses is whole connections, not bytes.** nettop reports running totals, and Flowlight \
                    records the difference between one second and the next — so a long transfer is counted exactly, \
                    however bursty it was. What never appears is anything that starts *and* finishes between two \
                    readings: a quick DNS lookup, a fast API call, a script that runs curl and exits. The extension \
                    sees those.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Fallback sampler")
            }

            Section("Storage") {
                LabeledContent("Database") {
                    Text(monitor.db.url.path).textSelection(.enabled).font(.caption.monospaced())
                }
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([monitor.db.url]) }
                    Button("Clear all data…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture")
        // Which other content filters exist decides whether ours can work at all, so it's read when the screen opens.
        .task { otherFilters = SystemExtensionScan.competingFilters(in: await SystemExtensionScan.read()) }
        .confirmationDialog("Delete all recorded traffic, baselines and alerts?", isPresented: $confirmClear) {
            Button("Delete everything", role: .destructive) { monitor.clearAllData() }
        }
    }
}

/// Where hostnames come from in nettop mode, with the one-time packet-capture setup.
struct HostnameSection: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @AppStorage(AnomalySettings.Keys.packetCapture) private var packetCapture = true
    @AppStorage(AnomalySettings.Keys.ownerLookup) private var ownerLookup = true
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            LabeledContent("Coverage (last hour)") {
                HStack(spacing: 12) {
                    coverageLabel("Hostname", monitor.coverage.named)
                    coverageLabel("Hostname or owner", monitor.coverage.owned)
                }
            }

            Toggle(isOn: $packetCapture) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn hostnames from DNS and TLS")
                    Text("Reads DNS answers and TLS server names (SNI) on the primary network interface. Packet contents are not stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: packetCapture) { monitor.updatePacketCapture() }

            if packetCapture {
                LabeledContent("Packet capture") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                if monitor.captureState == .noPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CaptureAccess.isInstalled
                             ? "Setup is installed, but this login session doesn't have access yet. Log out and back in, or restart your Mac."
                             : "macOS only lets administrators read network packets. A one-time setup grants your account read access, as Wireshark does. It asks for your password once.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(CaptureAccess.isInstalled ? "Run Setup Again…" : "Enable Packet Capture…") { run(.install) }
                                .disabled(working)
                            if working { ProgressView().controlSize(.small) }
                        }
                    }
                } else if CaptureAccess.isInstalled {
                    Button("Remove Packet Capture Access…") { run(.uninstall) }.disabled(working)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }

            Toggle(isOn: $ownerLookup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify network owners")
                    Text("When no hostname is known, look up who operates the IP (e.g. Cloudflare, Google) using Team Cymru's DNS service. Public IPs are sent to that service; private addresses never are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Hostnames")
        } footer: {
            Text("Order of preference: TLS server name, DNS answer, reverse DNS, network owner.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func coverageLabel(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value.formatted(.percent.precision(.fractionLength(0)))).font(.body.monospacedDigit().bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch monitor.captureState {
        case .running: return .green
        case .noPermission, .stopped: return .orange
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch monitor.captureState {
        case .running(let interface): return "Capturing on \(interface) · \(monitor.hostnamesLearned.formatted()) hostnames learned this session"
        case .noPermission: return "Needs one-time setup"
        case .stopped: return "Stopped"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private func run(_ action: CaptureAccess.Action) {
        working = true
        message = nil
        // Let the button redraw before the modal admin prompt blocks the main thread.
        DispatchQueue.main.async {
            message = monitor.performCaptureSetup(action)
            working = false
        }
    }
}

/// Shown once on first launch when packet capture has not been set up.
struct CaptureOnboardingView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @AppStorage(AnomalySettings.Keys.ownerLookup) private var ownerLookup = true
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 38)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("See which sites your apps talk to").font(.title2.bold())
                    Text("Without this, most traffic shows only an IP address or network owner.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                point("text.magnifyingglass", "Flowlight reads DNS answers and TLS server names on your primary network interface to name connections.")
                point("lock.shield", "Packet contents are never stored or sent anywhere. Only hostnames are kept.")
                point("key", "macOS only lets administrators read packets, so this asks for your password once. You can remove it any time in Capture.")
            }

            Toggle(isOn: $ownerLookup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify network owners when no hostname is available")
                    Text("On by default. Sends public destination IPs to Team Cymru's DNS service. Turn off to keep these lookups on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }

            HStack {
                Button("Not Now") { monitor.dismissCaptureOnboarding() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Enable Hostnames…") {
                    working = true
                    DispatchQueue.main.async {
                        message = monitor.performCaptureSetup(.install)
                        working = false
                        if case .running = monitor.captureState { monitor.dismissCaptureOnboarding() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
