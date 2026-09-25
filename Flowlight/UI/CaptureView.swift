import SwiftUI

/// Where Flowlight's data comes from, and everything that decides whether it can come from there.
///
/// The screen is read top down, in the order the questions are asked: which source is chosen, whether anything is
/// arriving from it, and then — only when asked — how that source works and what it cannot see. The long
/// explanations are all still here and all still true, but they are not what someone opens this panel for, so they
/// sit behind a summary row instead of in front of the controls.
struct CaptureView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var extensionManager: ExtensionManager
    @State private var confirmClear = false
    @State private var showExtensionSetup = false
    @State private var otherFilters: [InstalledSystemExtension] = []
    @State private var showFilterNotes = false
    @State private var showSamplerNotes = false

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                sourceSection
                extensionSection
                if monitor.mode == .nettop { HostnameSection() }
                samplerSection
                storageSection
            }
            // A settings panel is read, not scanned, and a line of prose stretched across a maximised window is
            // unreadable. The column stops at a comfortable measure and stays against the sidebar rather than
            // floating in the middle of the window.
            .frame(maxWidth: 820, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Capture")
        // The one thing worth a trip to this screen to find out — what is feeding the app right now — said in the
        // title bar, so it can be read from any other screen's neighbour.
        .navigationSubtitle(subtitle)
        // Which other content filters exist decides whether ours can work at all, so it's read when the screen opens.
        .task { otherFilters = SystemExtensionScan.competingFilters(in: await SystemExtensionScan.read()) }
        .confirmationDialog("Delete all recorded traffic, baselines and alerts?", isPresented: $confirmClear) {
            Button("Delete everything", role: .destructive) { monitor.clearAllData() }
        }
    }

    private var subtitle: String {
        if monitor.extensionFellBack { return "nettop sampler · the extension didn't answer" }
        let source = monitor.mode == .networkExtension ? "Network Extension" : "nettop sampler"
        return monitor.isReceiving ? "\(source) · receiving" : "\(source) · nothing arriving yet"
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading("Source")
            VStack(spacing: 0) {
                sourceRow(.networkExtension)
                Divider().padding(.leading, 50)
                sourceRow(.nettop)
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            statusCard
            CaptureWarningBanner()
            if !otherFilters.isEmpty { OtherFiltersNotice(filters: otherFilters) }
        }
    }

    /// One source, with the sentence that decides between them. A radio group can only offer the two names, and
    /// the names are not the choice — what each one can see is.
    private func sourceRow(_ mode: CaptureMode) -> some View {
        let chosen = monitor.mode == mode
        return Button {
            monitor.setMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(chosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceName(mode)).font(.body.weight(.medium))
                    Text(sourceBlurb(mode))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Color.accentColor.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? AccessibilityTraits.isSelected : [])
        .help(mode.title)
    }

    private func sourceName(_ mode: CaptureMode) -> String {
        mode == .networkExtension ? "Network Extension" : "nettop sampler"
    }

    private func sourceBlurb(_ mode: CaptureMode) -> String {
        mode == .networkExtension
            ? "A content filter in the path of every connection. Nothing short-lived escapes it, and it needs the "
              + "entitlement and your approval."
            : "Reads nettop once a second. No entitlement, no approval, and no trace of a connection that starts "
              + "and finishes between two readings."
    }

    /// Whether anything is actually arriving. The source rows say what was asked for; this says what happened.
    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            // Green means "data is arriving from the source you chose". After a fallback the sampler is genuinely
            // receiving, so a plain green dot beside a line explaining that the extension failed would contradict
            // itself. Yellow is that third state: working, but not as asked.
            LiveDot(color: statusColor, active: monitor.isReceiving, size: 10)
                .frame(width: 26, height: 26)
                .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(statusHeadline).font(.body.weight(.medium))
                Text(monitor.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .captureCard()
    }

    private var statusHeadline: String {
        if monitor.extensionFellBack { return "Arriving from nettop, not the extension" }
        return monitor.isReceiving ? "Data is arriving" : "Nothing is arriving"
    }

    // MARK: Network Extension

    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading("Network Extension")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    CaptureGlyph(symbol: extensionSymbol, tint: extensionTint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(extensionManager.state.label)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(extensionFacts)
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    if monitor.mode == .nettop {
                        Button(showExtensionSetup ? "Hide Setup" : "Show Setup…") { showExtensionSetup.toggle() }
                            .controlSize(.small)
                    }
                }
                if extensionDetailsVisible {
                    if let blocker = extensionManager.blocker { CaptureNote(text: blocker) }
                    if monitor.extensionFellBack {
                        CaptureNote(text: "Flowlight couldn't reach the filter extension and is sampling with nettop "
                                    + "so you still get data. Your chosen source is still the extension.",
                                    icon: "arrow.uturn.down.circle.fill")
                    }
                    extensionButtons
                }
            }
            .captureCard()
            if extensionDetailsVisible { filterNotes }
        }
    }

    private var extensionButtons: some View {
        HStack(spacing: 8) {
            Button("Install & Enable Filter") { extensionManager.activate() }
                .disabled(extensionManager.blocker != nil)
            Button("Disable Filter") { extensionManager.setFilterEnabled(false) }
                .disabled(extensionManager.state != .enabled)
            Button("Uninstall") { extensionManager.deactivate() }
                .disabled(!extensionManager.hasEntitlement)
            Button("Refresh") {
                extensionManager.refresh()
                // Also redial the extension: reloading its settings tells you nothing about whether the app can
                // actually reach it, which is the part that looked broken.
                monitor.reconnectSource()
            }
            .help("Re-check the filter and reconnect to it")
            if monitor.extensionFellBack {
                Button("Try the Extension Again") { monitor.reconnectSource() }
                    .help("Stop sampling with nettop and reconnect to the filter extension")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var extensionTint: Color {
        switch extensionManager.state {
        case .enabled: return .green
        case .failed: return .red
        case .awaitingApproval, .installing: return .orange
        case .unknown, .notInstalled, .disabled: return .secondary
        }
    }

    private var extensionSymbol: String {
        switch extensionManager.state {
        case .enabled: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .awaitingApproval: return "hourglass"
        case .installing: return "arrow.down.circle"
        case .unknown: return "questionmark.circle"
        case .notInstalled, .disabled: return "shield.slash"
        }
    }

    /// The two facts that decide whether the filter can ever run, stated before anyone presses a button that will
    /// fail because of them.
    private var extensionFacts: String {
        (ExtensionManager.isEntitled ? "entitled" : "not entitled")
            + " · " + (extensionManager.isInApplications ? "in /Applications" : "not in /Applications")
    }

    /// What the filter is and what it costs, folded away. Every word of it matters the first time and none of it
    /// matters the twentieth, which is exactly what a disclosure is for.
    private var filterNotes: some View {
        DisclosureGroup(isExpanded: $showFilterNotes) {
            VStack(alignment: .leading, spacing: 10) {
                Text("""
                The content filter (NEFilterDataProvider) attributes every TCP/UDP flow to its app via the audit token, \
                extracts TLS SNI, HTTP Host and DNS answers, and sends one-second summaries to this app over XPC. It \
                requires the Network Extension entitlement (content-filter-provider-systemextension) on a paid \
                developer team, and the app must be in the Applications folder. It never blocks traffic.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                CaptureFact(icon: "checkmark.seal", tint: .green, title: "Nothing short-lived escapes it",
                            detail: "macOS calls the filter as each connection is made, so a request that lasts five "
                            + "milliseconds is recorded like any other. It also costs less energy than sampling, which "
                            + "starts a process every second. Traffic from before you enable it isn't there, some "
                            + "system traffic is exempt from content filters, and byte counts come from the filter's "
                            + "own statistics.")
                CaptureFact(icon: "info.circle", tint: .secondary, title: "It keeps filtering after you quit Flowlight",
                            detail: "A system extension runs on its own, so the filter carries on inspecting "
                            + "connections and holding what it sees until you press Disable or Uninstall above. "
                            + "Nothing reaches this app while it isn't running, but the filter is still there.")
                CaptureFact(icon: "exclamationmark.triangle", tint: .orange,
                            title: "macOS runs one content filter at a time",
                            detail: "If a VPN or security agent already has that slot — Palo Alto Networks "
                            + "GlobalProtect, CrowdStrike Falcon and similar all use it — Flowlight's filter installs "
                            + "and connects but is never asked to filter anything, so nothing appears. Use the sampler "
                            + "on those Macs.")
            }
            .padding(.top, 10)
        } label: {
            Text("How the content filter works")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .captureCard()
    }

    // MARK: Fallback sampler

    private var samplerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading("Fallback sampler")
            VStack(alignment: .leading, spacing: 10) {
                (Text("Without the extension, Flowlight reads ").font(.callout)
                 + Text("/usr/bin/nettop").font(.callout.monospaced())
                 + Text(" once per second. You get per-process, per-connection byte counts with no entitlements, "
                        + "and protocols from port heuristics.").font(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup(isExpanded: $showSamplerNotes) {
                    CaptureFact(icon: "exclamationmark.triangle", tint: .orange,
                                title: "What it misses is whole connections, not bytes",
                                detail: "nettop reports running totals, and Flowlight records the difference between "
                                + "one second and the next — so a long transfer is counted exactly, however bursty it "
                                + "was. What never appears is anything that starts and finishes between two readings: "
                                + "a quick DNS lookup, a fast API call, a script that runs curl and exits. The "
                                + "extension sees those.")
                        .padding(.top, 10)
                } label: {
                    Text("What it can't see")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .captureCard()
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading("Storage")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    CaptureGlyph(symbol: "internaldrive", tint: .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Database").font(.body.weight(.medium))
                        Text(monitor.db.url.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 8) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([monitor.db.url]) }
                    Spacer(minLength: 8)
                    Button("Clear All Data…", role: .destructive) { confirmClear = true }
                }
                .controlSize(.small)
            }
            .captureCard()
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
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading("Hostnames")
            coverageCard
            packetCaptureCard
            ownerCard
        }
    }

    /// How well it is going, before any of the switches that decide it. Two numbers rather than a sentence: this
    /// is the one place on the panel where a figure is the whole answer.
    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 40) {
                figure("Named", monitor.coverage.named)
                figure("Named or owner known", monitor.coverage.owned)
                Spacer(minLength: 0)
            }
            Text("Of the connections seen in the last hour. Order of preference: TLS server name, DNS answer, "
                 + "reverse DNS, network owner.")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .captureCard()
    }

    private func figure(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted(.percent.precision(.fractionLength(0))))
                .font(.title2.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .motion(Motion.value, value: value)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var packetCaptureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleHeader("Learn hostnames from DNS and TLS",
                         "Reads DNS answers and TLS server names (SNI) on the primary network interface. Packet "
                         + "contents are not stored.",
                         isOn: $packetCapture)
                .onChange(of: packetCapture) { monitor.updatePacketCapture() }
            if packetCapture {
                Divider()
                HStack(spacing: 8) {
                    LiveDot(color: captureColor, active: isCapturing)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if monitor.captureState != .noPermission, CaptureAccess.isInstalled {
                        Button("Remove Access…") { run(.uninstall) }
                            .controlSize(.small).disabled(working)
                    }
                }
                if monitor.captureState == .noPermission { permissionPrompt }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .captureCard()
    }

    /// The one step that needs an administrator. It keeps its own strip because it is the difference between a
    /// screen full of IP addresses and a screen full of names.
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key.fill").font(.caption)
                Text(CaptureAccess.isInstalled
                     ? "Setup is installed, but this login session doesn't have access yet. Log out and back in, or "
                       + "restart your Mac."
                     : "macOS only lets administrators read network packets. A one-time setup grants your account "
                       + "read access, as Wireshark does. It asks for your password once.")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button(CaptureAccess.isInstalled ? "Run Setup Again…" : "Enable Packet Capture…") { run(.install) }
                    .controlSize(.small).disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private var ownerCard: some View {
        toggleHeader("Identify network owners",
                     "When no hostname is known, look up who operates the IP (e.g. Cloudflare, Google) using Team "
                     + "Cymru's DNS service. Public IPs are sent to that service; private addresses never are.",
                     isOn: $ownerLookup)
            .captureCard()
    }

    private func toggleHeader(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("", isOn: isOn)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .accessibilityLabel(title)
                .padding(.top, 1)
        }
    }

    private var isCapturing: Bool {
        if case .running = monitor.captureState { return true }
        return false
    }

    private var captureColor: Color {
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
