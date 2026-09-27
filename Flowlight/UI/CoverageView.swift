import SwiftUI

/// What Flowlight can and cannot account for, per app.
///
/// Every other screen answers "what happened". This one answers "what would I not have been told", which is
/// the question a monitoring tool usually leaves to its documentation — and which decides how much the other
/// screens are worth.
struct CoverageView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View { CoverageContent(inspection: monitor.inspection) }
}

private struct CoverageContent: View {
    @ObservedObject var inspection: InspectionController
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @AppStorage("coverage.window") private var window: AgentWindow = .day
    @State private var rows: [AppCoverage] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summary
                if rows.isEmpty && loaded {
                    ContentUnavailableView {
                        Label(L("Nothing recorded yet"), systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text(L("Coverage is worked out from traffic Flowlight has already recorded. Leave it running for a moment."))
                    }
                } else {
                    table
                }
            }
            .padding(Measure.gutter)
        }
        .navigationTitle(L("Coverage"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L("Window"), selection: $window) {
                    ForEach(AgentWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .task(id: LoadKey(window: window, version: monitor.dataVersion, inspecting: inspection.enabled)) { await load() }
    }

    private struct LoadKey: Equatable { var window: AgentWindow; var version: Int; var inspecting: Bool }

    private var subtitle: String {
        guard !rows.isEmpty else { return L("Nothing recorded yet") }
        return L("%@ of traffic fully accounted for",
                 CoverageReport.overall(rows).formatted(.percent.precision(.fractionLength(0))))
    }

    /// The two engine-wide facts first, because they explain most of the rows underneath and are fixed in one
    /// place rather than per app.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading(L("How much of this Mac is covered"))
            VStack(alignment: .leading, spacing: 10) {
                CaptureFact(icon: monitor.mode == .networkExtension && !monitor.extensionFellBack
                                ? "checkmark.seal" : "exclamationmark.triangle",
                            tint: monitor.mode == .networkExtension && !monitor.extensionFellBack ? .green : .orange,
                            title: captureTitle, detail: captureDetail)
                CaptureFact(icon: inspection.enabled ? "checkmark.seal" : "info.circle",
                            tint: inspection.enabled ? .green : .secondary,
                            title: inspection.enabled ? L("HTTPS inspection is on") : L("HTTPS inspection is off"),
                            detail: inspection.enabled
                                ? L("What an app sent is readable only where the app was routed through the proxy. Anything else is counted and named, but its contents were never offered to Flowlight.")
                                : L("Flowlight sees which connections were made and where to, but not what was inside them. Nothing is decrypted until you turn inspection on."))
                CaptureFact(icon: "questionmark.circle", tint: .secondary,
                            title: L("What no engine can see"),
                            detail: L("Traffic from before capture started, system services that content filters are never shown, apps that pin their certificates, QUIC the proxy is never offered, and an agent's local MCP server talking over a pipe. None of these appear anywhere in Flowlight, so they are absent from these figures too."))
            }
            .padding(12)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var captureTitle: String {
        switch monitor.mode {
        case .networkExtension:
            return monitor.extensionFellBack ? L("Sampling with nettop, not the filter") : L("The filter sees connections as they open")
        case .nettop:
            return L("Sampling with nettop every second")
        }
    }

    private var captureDetail: String {
        switch monitor.mode {
        case .networkExtension where !monitor.extensionFellBack:
            return L("Every eligible TCP and UDP flow is attributed as it opens, including connections too short for a sampler to catch.")
        case .networkExtension:
            return L("The filter isn't answering, so these figures come from the sampler: a connection that opens and closes between two readings is missing entirely, and no percentage below can show it.")
        case .nettop:
            return L("Byte counts are exact, but a connection that opens and closes between two readings is never recorded — a quick DNS lookup, a fast API call, a script that runs curl and exits. Only the filter sees those.")
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptureHeading(L("By app"))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    CoverageRow(coverage: row)
                }
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func load() async {
        let from = Date().addingTimeInterval(-window.interval), to = Date()
        let grain = window.granularity
        let result = try? await monitor.read { db -> ([BreakdownRow], [HTTPExchange]) in
            (try db.breakdown(grain, from: from, to: to),
             try db.exchanges(since: from, limit: 4000))
        }
        guard let (breakdown, exchanges) = result else { return }
        rows = CoverageReport.build(rows: breakdown,
                                    inspected: Set(exchanges.map(\.bundleID).filter { !$0.isEmpty }),
                                    excluded: Set(inspection.neverInspect),
                                    mode: monitor.mode, fellBack: monitor.extensionFellBack,
                                    inspectionOn: inspection.enabled && inspection.running,
                                    isDemo: DemoData.isEnabled)
        loaded = true
    }
}

/// One app: what is seen, what is named, what is readable — and the one sentence that says which of those is
/// missing, rather than three badges someone has to interpret.
private struct CoverageRow: View {
    var coverage: AppCoverage
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: coverage.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(coverage.isComplete ? Color.green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(coverage.appName).font(.body.weight(.medium)).lineLimit(1)
                    Text(ByteFormat.string(coverage.bytes)).font(.caption).foregroundStyle(.secondary)
                }
                Text(gap).font(.caption).foregroundStyle(.secondary).prose()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(coverage.named.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospaced())
                .foregroundStyle(coverage.named > 0.99 ? .secondary : .primary)
                .help(L("Share of this app's bytes whose destination has a hostname rather than a bare address."))
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    /// The sentence. Named gaps first, because an unnamed destination is the one a person can act on.
    private var gap: String {
        var parts: [String] = []
        if coverage.named < 0.99 {
            parts.append(L("%@ of its bytes went to addresses with no hostname",
                           (1 - coverage.named).formatted(.percent.precision(.fractionLength(0)))))
        }
        switch coverage.inspection {
        case .notRouted: parts.append(L("nothing of its traffic reached the proxy, so no contents were read"))
        case .excluded: parts.append(L("it is on the Never decrypted list, so its contents are deliberately not read"))
        case .reading, .off: break
        }
        switch coverage.capture {
        case .sampler, .fellBack: parts.append(L("short connections may be missing entirely"))
        case .filter, .demo: break
        }
        guard !parts.isEmpty else { return L("Seen as it happened, named, and readable.") }
        return parts.joined(separator: " · ")
    }
}
