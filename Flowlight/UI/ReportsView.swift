import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Buckets that sit far above the rest of the visible series.
enum SeriesAnomalies {
    static func flagged(_ series: [SeriesPoint], sigma: Double) -> Set<Date> {
        let active = series.filter { $0.total > 0 }
        guard active.count >= 8 else { return [] }
        let values = active.map { Double($0.total) }
        let mean = values.reduce(0, +) / Double(values.count)
        let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        guard sd > 0 else { return [] }
        return Set(active.filter { (Double($0.total) - mean) / sd >= sigma }.map(\.date))
    }
}

enum HistoryRangePreset: String, CaseIterable, Identifiable {
    case fifteenMinutes, oneHour, sixHours, oneDay, oneWeek, oneMonth, sixMonths, oneYear, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: return L("15 min")
        case .oneHour: return L("1h")
        case .sixHours: return L("6h")
        case .oneDay: return L("1d")
        case .oneWeek: return L("1w")
        case .oneMonth: return L("1 mo")
        case .sixMonths: return L("6 mo")
        case .oneYear: return L("1y")
        case .all: return L("All")
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3_600
        case .sixHours: return 6 * 3_600
        case .oneDay: return 86_400
        case .oneWeek: return 7 * 86_400
        case .oneMonth: return 30 * 86_400
        case .sixMonths: return 183 * 86_400
        case .oneYear: return 365 * 86_400
        case .all: return nil
        }
    }

    func window(endingAt end: Date, available: ClosedRange<Date>) -> HistoryWindow {
        let requestedStart = duration.map { end.addingTimeInterval(-$0) } ?? available.lowerBound
        return HistoryWindow(
            start: max(available.lowerBound, requestedStart),
            end: min(available.upperBound, end),
            followNow: true
        ).clamped(to: available)
    }
}

struct HistoryWindow: Equatable {
    var start: Date
    var end: Date
    var followNow: Bool

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    var granularity: Granularity {
        switch duration {
        case ..<(12 * 3_600): return .minute
        case ..<(14 * 86_400): return .hour
        case ..<(400 * 86_400): return .day
        case ..<(3 * 365 * 86_400): return .week
        default: return .month
        }
    }

    func clamped(to available: ClosedRange<Date>) -> HistoryWindow {
        let availableDuration = available.upperBound.timeIntervalSince(available.lowerBound)
        let width = min(max(60, duration), max(60, availableDuration))
        var nextEnd = min(max(end, available.lowerBound), available.upperBound)
        var nextStart = nextEnd.addingTimeInterval(-width)
        if nextStart < available.lowerBound {
            nextStart = available.lowerBound
            nextEnd = min(available.upperBound, nextStart.addingTimeInterval(width))
        }
        return HistoryWindow(start: nextStart, end: nextEnd,
                             followNow: followNow && nextEnd >= available.upperBound)
    }

    func panned(by offset: TimeInterval, within available: ClosedRange<Date>) -> HistoryWindow {
        HistoryWindow(start: start.addingTimeInterval(offset),
                      end: end.addingTimeInterval(offset),
                      followNow: false).clamped(to: available)
    }

    func returningToNow(within available: ClosedRange<Date>) -> HistoryWindow {
        HistoryWindow(start: available.upperBound.addingTimeInterval(-duration),
                      end: available.upperBound,
                      followNow: true).clamped(to: available)
    }

    func resized(start requestedStart: Date, end requestedEnd: Date,
                 within available: ClosedRange<Date>, minimumDuration: TimeInterval) -> HistoryWindow {
        let lower = min(max(requestedStart, available.lowerBound), available.upperBound)
        let upper = min(max(requestedEnd, available.lowerBound), available.upperBound)
        let orderedStart = min(lower, upper)
        let orderedEnd = max(lower, upper)
        let width = max(minimumDuration, orderedEnd.timeIntervalSince(orderedStart))
        return HistoryWindow(start: orderedStart,
                             end: orderedStart.addingTimeInterval(width),
                             followNow: false).clamped(to: available)
    }
}

enum HistoryNavigatorDomain {
    static func range(available: ClosedRange<Date>, selection: HistoryWindow) -> ClosedRange<Date> {
        let total = max(60, available.upperBound.timeIntervalSince(available.lowerBound))
        let desired = min(total, max(6 * 3_600, max(60, selection.duration) * 24))
        guard desired < total * 0.9 else { return available }

        if selection.followNow {
            return max(available.lowerBound, available.upperBound.addingTimeInterval(-desired))...available.upperBound
        }

        let midpoint = selection.start.addingTimeInterval(selection.duration / 2)
        var lower = midpoint.addingTimeInterval(-desired / 2)
        var upper = lower.addingTimeInterval(desired)
        if lower < available.lowerBound {
            lower = available.lowerBound
            upper = lower.addingTimeInterval(desired)
        }
        if upper > available.upperBound {
            upper = available.upperBound
            lower = upper.addingTimeInterval(-desired)
        }
        return lower...upper
    }
}

enum ReportChartHoverLayout {
    static func cardX(lineX: CGFloat, chartWidth: CGFloat,
                      cardWidth: CGFloat = 260, gap: CGFloat = 8) -> CGFloat {
        let proposed = lineX + gap + cardWidth <= chartWidth
            ? lineX + gap
            : lineX - gap - cardWidth
        return min(max(0, proposed), max(0, chartWidth - cardWidth))
    }
}

enum ReportChartKeyboardDirection {
    case left, right
}

enum ReportChartKeyboardSelection {
    static func move(from current: Date?, direction: ReportChartKeyboardDirection, dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        guard let current, let index = dates.firstIndex(of: current) else { return dates[0] }
        switch direction {
        case .left: return dates[max(0, index - 1)]
        case .right: return dates[min(dates.count - 1, index + 1)]
        }
    }
}

struct ReportNavigationState: Equatable {
    var granularity: Granularity
    var startDate: Date? = nil
    var endDate: Date
    var followNow: Bool
    var filter: TrafficFilter
    var preset: HistoryRangePreset? = nil
}

struct ReportNavigationHistory: Equatable {
    private var states: [ReportNavigationState] = []

    var isEmpty: Bool { states.isEmpty }

    mutating func push(_ state: ReportNavigationState) {
        guard states.last != state else { return }
        states.append(state)
    }

    mutating func pop() -> ReportNavigationState? { states.popLast() }
    mutating func clear() { states.removeAll() }
}

struct ReportsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var focus: FocusStore
    @AppStorage("reports.granularity") private var granularity: Granularity = .minute
    @AppStorage(AnomalySettings.Keys.sigma) private var sigma = 3.0
    @State private var startDate = Date().addingTimeInterval(-6 * 3_600)
    @State private var endDate = Date()
    @State private var followNow = true
    @State private var selectedPreset: HistoryRangePreset? = .sixHours
    @State private var availableRange = Date().addingTimeInterval(-5 * 365 * 86_400)...Date()
    @State private var overview: [SeriesPoint] = []
    @State private var navigatorDetail: [SeriesPoint] = []
    @State private var filter = TrafficFilter.none
    @State private var query = ""
    @State private var series: [SeriesPoint] = []
    @State private var nodes: [TrafficNode] = []
    @State private var displayed: [TrafficNode] = []
    @State private var flagged: Set<Date> = []
    @State private var sortOrder = [KeyPathComparator(\TrafficNode.total, order: .reverse)]
    @State private var selection: TrafficNode.ID?
    @State private var loading = false
    @State private var reloadID = UUID()
    @State private var hovered: SeriesPoint?
    @State private var hoverLineX: CGFloat?
    @State private var tooltipHovered = false
    @State private var hoverDismissID = UUID()
    @State private var keyboardBucketDate: Date?
    @FocusState private var chartFocused: Bool
    /// Top apps per bucket, fetched on hover or keyboard selection and cached until the next reload.
    @State private var contributors: [Date: BucketContributors] = [:]
    /// How many children each parent row shows (grown by "Show more"); "__root__" is the app list.
    @State private var childLimits: [String: Int] = [:]
    @State private var breakdownTruncated = false
    @State private var history = ReportNavigationHistory()
    @AppStorage("reports.lowerMode") private var lowerMode: LowerMode = .breakdown
    @AppStorage("reports.grouping") private var grouping: BreakdownGrouping = .app
    /// Raw breakdown rows; the tree is rebuilt from these when the grouping changes (no re-query).
    @State private var breakdownRows: [BreakdownRow] = []
    @State private var breakdownAppTotals: [BreakdownRow] = []
    @AppStorage("reports.insightMetric") private var metric: InsightMetric = .total
    @State private var insights = InsightsSnapshot.empty
    @State private var registries: [InsightDimension: ColorRegistry] = [:]
    /// Apps whose destinations stand out from the rest of this report. Rebuilt from the same breakdown rows.
    @State private var behaviour: [AppBehaviour] = []
    @State private var localRiskCounts = RiskAssessmentCounts()

    enum LowerMode: String, CaseIterable, Identifiable {
        case breakdown, charts, behaviour
        var id: String { rawValue }
        var title: String {
            switch self {
            case .breakdown: return L("Breakdown")
            case .charts: return L("Charts")
            case .behaviour: return L("Worth a look")
            }
        }
    }

    private var window: HistoryWindow {
        HistoryWindow(start: startDate, end: endDate, followNow: followNow)
    }

    /// From the series, not the table rows, so shares stay right even if the table is capped.
    private var grandTotal: Int64 { max(1, series.reduce(0) { $0 + $1.total }) }
    private var highlightedPoint: SeriesPoint? {
        if chartFocused, let keyboardBucketDate {
            return series.first { $0.date == keyboardBucketDate }
        }
        return hovered
    }

    var body: some View {
        GeometryReader { _ in
            switch lowerMode {
            case .charts: chartsContent
            case .behaviour: behaviourContent
            case .breakdown: breakdownContent
            }
        }
        // The Local Risk card made the old intrinsic report taller than the split view. Give every mode the real
        // detail viewport so the table takes the remaining height instead of pushing the report header under the bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(L("History"))
        .searchable(text: $query, placement: .toolbar, prompt: L("App, domain, IP, port"))
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker(L("Way out"), selection: $filter.channel) {
                        Text(L("Every way out")).tag(NetworkChannel?.none)
                        Divider()
                        ForEach(NetworkChannel.allCases, id: \.self) { channel in
                            Text(channel.localizedTitle).tag(NetworkChannel?.some(channel))
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Label(L("Way out"), systemImage: filter.channel?.icon ?? "point.3.filled.connected.trianglepath.dotted") }
                .help(L("Narrow to one way out of the Mac: the network, the peer-to-peer radio, this Mac, or a tunnel"))
            }
            ToolbarItem {
                Menu {
                    Button(L("Time series (CSV)…")) { export(csv: CSVExport.series(series, granularity: granularity), name: "flowlight-series") }
                    Button(L("Breakdown (CSV)…")) { export(csv: CSVExport.breakdown(breakdownRows, query: query), name: "flowlight-breakdown") }
                } label: { Label(L("Export"), systemImage: "square.and.arrow.up") }
                .help(L("Export the current report as CSV"))
            }
        }
        .task(id: ReloadKey(granularity: granularity,
                            duration: endDate.timeIntervalSince(startDate),
                            end: followNow ? nil : endDate, filter: scoped,
                            version: monitor.dataVersion,
                            localRiskVersion: monitor.localRiskVersion,
                            mode: lowerMode, metric: metric)) {
            await reload()
        }
        .task(id: NavigatorKey(filter: scoped, version: monitor.dataVersion)) {
            await reloadNavigator()
        }
        .task(id: NavigatorDetailKey(filter: scoped, version: monitor.dataVersion,
                                     start: startDate, end: endDate,
                                     availableStart: availableRange.lowerBound,
                                     availableEnd: availableRange.upperBound)) {
            await reloadNavigatorDetail()
        }
        .task(id: granularity) {
            // Second-level data changes every second; other tiers refresh after each rollup.
            guard granularity == .second else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if followNow && !Task.isCancelled { await reload() }
            }
        }
        .onChange(of: nodes) { recompute() }
        .onChange(of: sortOrder) { recompute() }
        .onChange(of: query) { recompute() }
        .onChange(of: sigma) { flagged = SeriesAnomalies.flagged(series, sigma: sigma) }
        .onChange(of: nav.reportRequest, initial: true) { apply(nav.reportRequest) }
        .onChange(of: ReportNavigationState(granularity: granularity, startDate: startDate,
                                            endDate: endDate, followNow: followNow,
                                            filter: filter, preset: selectedPreset), initial: true) { _, scope in
            nav.updateCurrentReportScope(filter: scope.filter, granularity: scope.granularity,
                                         startDate: scope.startDate ?? startDate, endDate: scope.endDate,
                                         followNow: scope.followNow, preset: scope.preset)
        }
        .task(id: highlightedPoint?.date) { await loadContributors(for: highlightedPoint) }
    }

    /// What the screen actually queries: the filter chosen here, narrowed by Focus when it's on.
    private var scoped: TrafficFilter { Self.effectiveFilter(filter, focus: focus.scope) }

    static func effectiveFilter(_ filter: TrafficFilter, focus: FocusScope) -> TrafficFilter {
        var scoped = filter
        scoped.focus = focus
        return scoped
    }

    private struct NavigatorKey: Equatable {
        var filter: TrafficFilter
        var version: Int
    }

    private struct NavigatorDetailKey: Equatable {
        var filter: TrafficFilter
        var version: Int
        var start: Date
        var end: Date
        var availableStart: Date
        var availableEnd: Date
    }

    private struct ReloadKey: Equatable {
        var granularity: Granularity; var duration: TimeInterval; var end: Date?
        var filter: TrafficFilter; var version: Int; var localRiskVersion: Int
        var mode: LowerMode; var metric: InsightMetric
    }

    // MARK: Sections

    /// Charts and behaviour scroll as a single report; the breakdown keeps its controls above a table that fills
    /// only the remaining viewport. Keeping the three modes concrete also avoids a giant conditional SwiftUI type.
    private var chartsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                lowerModeBar
                InsightsPanel(snapshot: insights, registries: registries, metric: metric, granularity: granularity,
                              scopeName: scopeName, onSelect: narrow)
                    .overlay { if insights.dimensions.isEmpty && !loading { emptyCharts } }
            }
            .padding()
        }
    }

    private var behaviourContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                lowerModeBar
                BehaviourPanel(findings: behaviour, period: granularity.periodName) { finding in
                    pushHistory()
                    filter = TrafficFilter(bundleID: finding.bundleID)
                    lowerMode = .breakdown
                }
            }
            .padding()
        }
    }

    private var breakdownContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .layoutPriority(1)
            lowerModeBar
                .layoutPriority(1)
            table
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var header: some View {
        controls
        if !filter.isEmpty { filterChips }
        coverageNotice
        localRiskSummary
        summary
        chart
    }

    private var coverageNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            if monitor.coverage.hasTraffic {
                Text(L("Hostname coverage, last hour: %@ of bytes",
                       monitor.coverage.named.formatted(.percent.precision(.fractionLength(0)))))
                Text("·")
                Text(L("including network owners: %@",
                       monitor.coverage.owned.formatted(.percent.precision(.fractionLength(0)))))
            } else {
                Text(L("Nothing recorded in the last hour"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(L("Coverage is for all traffic in the last hour, not the selected report window. IPs without names may belong to shared hosting or CDNs."))
    }

    @ViewBuilder
    private var localRiskSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(FL.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Potential harm")).font(.callout.bold())
                if LocalRiskSettings.isActive {
                    if localRiskCounts.totalPotentialHarm > 0 {
                        Text(L("%lld medium or high local assessment%@ in this window.", localRiskCounts.totalPotentialHarm,
                               localRiskCounts.totalPotentialHarm == 1 ? "" : "s"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("No medium or high local assessments in this window. Requests without an assessment are not being called safe."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if localRiskCounts.unassessed > 0 {
                        Text(L("%lld eligible request%@ did not receive a contextual verdict.", localRiskCounts.unassessed,
                               localRiskCounts.unassessed == 1 ? "" : "s"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("Local risk analysis is off. Retained local findings are hidden until you turn it back on."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { LocalRiskSettings.isActive }, set: { monitor.setLocalRiskEnabled($0) })) {
                Text(L("Local risk analysis"))
            }
            .toggleStyle(.switch)
            .disabled(!LocalRiskSettings.canAnalyze)
            #if !APP_STORE
            if LocalRiskSettings.isActive && localRiskCounts.totalPotentialHarm > 0
                && InspectNavigationScope.canInspect(filter, requireDestination: false) {
                Button(L("Show in Inspect")) {
                    InspectNavigationScope.showInspect(nav, filter: filter, requireDestination: false,
                                                       potentialHarmOnly: true)
                }
            }
            #endif
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .help(LocalRiskSettings.readiness.explanation ?? L("On-device-only, advisory scoring after capture. It does not block or change traffic."))
    }

    private var lowerModeBar: some View {
        HStack {
            Picker(L("View"), selection: $lowerMode) {
                ForEach(LowerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            if lowerMode == .charts {
                Spacer()
                Text(L("Measure")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Measure"), selection: $metric) {
                    ForEach(InsightMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            } else {
                Spacer()
                Text(L("Group by")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Group by"), selection: $grouping) {
                    ForEach(BreakdownGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                .help(L("App › Domain › IP, Destination › App › IP, or IP › App"))
            }
        }
        .onChange(of: grouping) {
            childLimits = [:]
            selection = nil
            nodes = TrafficNode.tree(
                from: breakdownRows,
                appTotals: grouping == .app ? breakdownAppTotals : [],
                grouping: grouping,
                base: scoped
            )
        }
    }

    private var emptyCharts: some View {
        ContentUnavailableView(L("No traffic in this window"), systemImage: "chart.pie",
                               description: Text(L("Choose a longer window or clear filters.")))
            .frame(minHeight: 200)
    }

    /// What the charts are scoped to, for their titles ("Destinations · claude").
    private var scopeName: String? {
        let applications = filter.bundleIDs.isEmpty
            ? filter.bundleID.map(appName(for:))
            : filter.bundleIDs.map(appName(for:)).joined(separator: ", ")
        return [applications, filter.agentParent.map(appName(for:)), filter.mcpServer,
                filter.domainSuffix, filter.owner, filter.domain.flatMap { $0.isEmpty ? nil : $0 },
                filter.remoteIP, filter.appProtocol, filter.channel.map(\.localizedTitle)].compactMap { $0 }.first
    }

    private func narrow(to entity: InsightEntity) {
        guard let next = entity.narrowing(filter), next != filter else { return }
        pushHistory()
        filter = next
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if !history.isEmpty {
                Button { goBack() } label: { Label(L("Back"), systemImage: "arrow.uturn.backward") }
                    .help(L("Return to the previous history scope"))
            }
            Text(L("Range"))
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(HistoryRangePreset.allCases) { preset in
                Button(preset.title) { apply(preset) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedPreset == preset ? FL.accent : nil)
                    .accessibilityValue(selectedPreset == preset ? L("Selected") : "")
            }

            Spacer(minLength: 12)

            Text(rangeLabel)
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help("\(startDate.formatted(date: .complete, time: .shortened)) – \(endDate.formatted(date: .complete, time: .shortened))")
            if !followNow {
                Button(L("Now")) { returnToNow() }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            Text(L("Showing only:")).font(.caption).foregroundStyle(.secondary)
            if let app = filter.bundleID {
                chip(L("App: %@", appName(for: app))) {
                    filter.bundleID = nil
                    filter.includeAttributedChildren = false
                }
            }
            if !filter.bundleIDs.isEmpty {
                chip("\(L("Apps")): \(filter.bundleIDs.map(appName(for:)).joined(separator: ", "))") {
                    filter.bundleIDs = []
                    filter.includeAttributedChildren = false
                }
            }
            if filter.includeAttributedChildren {
                chip(L("Tools & MCP servers")) { filter.includeAttributedChildren = false }
            }
            if let parent = filter.agentParent {
                chip("\(L("Agent")): \(appName(for: parent))") { filter.agentParent = nil }
            }
            if let mcp = filter.mcpServer {
                chip("\(L("MCP server")): \(mcp)") { filter.mcpServer = nil }
            }
            if let owner = filter.owner { chip(L("Owner: %@", owner)) { filter.owner = nil; filter.domain = nil; filter.remoteIP = nil } }
            else if let domain = filter.domain { chip(L("Domain: %@", domain.isEmpty ? L("(none)") : domain)) { filter.domain = nil; filter.remoteIP = nil } }
            if let suffix = filter.domainSuffix { chip(L("Domain: *.%@", suffix)) { filter.domainSuffix = nil; filter.remoteIP = nil } }
            if let ip = filter.remoteIP { chip(L("IP: %@", ip)) { filter.remoteIP = nil } }
            if let proto = filter.appProtocol { chip(L("Protocol: %@", proto)) { filter.appProtocol = nil } }
            if let channel = filter.channel { chip(L("Way out: %@", channel.localizedTitle)) { filter.channel = nil } }
            Button(L("Clear")) {
                guard !filter.isEmpty else { return }
                pushHistory()
                filter = .none
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button {
                pushHistory()
                remove()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).accessibilityLabel(L("Remove filter %@", text))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(FL.accent.opacity(0.15), in: Capsule())
    }

    private var summary: some View {
        let totalIn = series.reduce(0) { $0 + $1.bytesIn }
        let totalOut = series.reduce(0) { $0 + $1.bytesOut }
        let flows = series.reduce(0) { $0 + $1.flows }
        let peak = series.max { $0.total < $1.total }
        return HStack(spacing: 12) {
            StatTile(title: L("Received"), value: ByteFormat.string(totalIn), systemImage: "arrow.down", tint: TrafficColors.inbound)
            StatTile(title: L("Sent"), value: ByteFormat.string(totalOut), systemImage: "arrow.up", tint: TrafficColors.outbound)
            StatTile(title: L("Flows"), value: flows.formatted(), systemImage: "point.3.connected.trianglepath.dotted")
            StatTile(title: peakTitle, value: peak.map { ByteFormat.string($0.total) } ?? "–", systemImage: "chart.line.uptrend.xyaxis")
            StatTile(title: L("Abnormal buckets"), value: "\(flagged.count)", systemImage: "exclamationmark.triangle",
                     tint: flagged.isEmpty ? .secondary : TrafficColors.anomaly)
                .help(L("Buckets at least %@σ above the mean of this window", sigma.formatted()))
        }
    }

    /// "Peak minute" and its siblings. A key each rather than "Peak %@" of a lowercased period name: the period
    /// word is part of the phrase, and not every language lets it be lowercased on its own.
    private var peakTitle: String {
        switch granularity {
        case .second: return L("Peak second")
        case .minute: return L("Peak minute")
        case .hour: return L("Peak hour")
        case .day: return L("Peak day")
        case .week: return L("Peak week")
        case .month: return L("Peak month")
        case .year: return L("Peak year")
        }
    }

    private var chart: some View {
        let highlighted = highlightedPoint
        return GroupBox {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Chart {
                ForEach(series) { point in
                    BarMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent),
                            y: .value(L("Bytes"), point.bytesIn))
                        .foregroundStyle(by: .value(L("Direction"), L("Received")))
                        .opacity(highlighted == nil || highlighted?.date == point.date ? 1 : 0.55)
                    BarMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent),
                            y: .value(L("Bytes"), point.bytesOut))
                        .foregroundStyle(by: .value(L("Direction"), L("Sent")))
                        .opacity(highlighted == nil || highlighted?.date == point.date ? 1 : 0.55)
                }
                ForEach(series.filter { flagged.contains($0.date) }) { point in
                    PointMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent), y: .value(L("Bytes"), point.total))
                        .symbol(.triangle)
                        .symbolSize(30)
                        .foregroundStyle(TrafficColors.anomaly)
                        .offset(y: -8)
                }
                if let highlighted {
                    RuleMark(x: .value(L("Time"), highlighted.date, unit: granularity.calendarComponent))
                        .foregroundStyle(.secondary.opacity(0.25))
                }
            }
            .chartForegroundStyleScale([L("Received"): TrafficColors.inbound, L("Sent"): TrafficColors.outbound])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int64.self) { Text(ByteFormat.string(v)) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoverDismissID = UUID()
                                tooltipHovered = false
                                hovered = point(at: location, proxy: proxy, geo: geo)
                                hoverLineX = hovered.flatMap { lineX(for: $0, proxy: proxy, geo: geo) }
                                    ?? location.x
                            case .ended:
                                scheduleHoverDismissal()
                            }
                        }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($chartFocused)
            .onChange(of: chartFocused) { _, focused in
                guard focused else { return }
                keyboardBucketDate = ReportChartKeyboardSelection.move(
                    from: keyboardBucketDate,
                    direction: .right,
                    dates: series.map(\.date)
                )
            }
            .onChange(of: series.map(\.date)) { _, dates in
                guard chartFocused, !dates.contains(keyboardBucketDate ?? .distantPast) else { return }
                keyboardBucketDate = ReportChartKeyboardSelection.move(from: nil, direction: .right, dates: dates)
            }
            .onMoveCommand { direction in
                let keyboardDirection: ReportChartKeyboardDirection
                switch direction {
                case .left: keyboardDirection = .left
                case .right: keyboardDirection = .right
                default: return
                }
                hovered = nil
                hoverLineX = nil
                keyboardBucketDate = ReportChartKeyboardSelection.move(
                    from: keyboardBucketDate,
                    direction: keyboardDirection,
                    dates: series.map(\.date)
                )
            }
            .onKeyPress(keys: [.return, .space]) { _ in
                guard let highlighted, granularity.finer != nil else { return .ignored }
                drill(into: highlighted)
                return .handled
            }
            .accessibilityLabel(L("Traffic"))
            .accessibilityValue(highlighted.map(chartAccessibilityValue) ?? "")
            .accessibilityHint(granularity.finer == nil
                               ? L("Use the Left and Right Arrow keys to inspect time buckets.")
                               : L("Use the Left and Right Arrow keys to inspect time buckets, then press Return to zoom in."))
                    .frame(height: 300)
                    .overlay { if loading && series.isEmpty { ProgressView() } }
                    if let highlighted {
                        GeometryReader { geometry in
                            tooltip(for: highlighted)
                                .offset(x: ReportChartHoverLayout.cardX(
                                    lineX: hoverLineX ?? 0,
                                    chartWidth: geometry.size.width
                                ), y: 8)
                                .onHover { inside in
                                    tooltipHovered = inside
                                    if inside {
                                        hoverDismissID = UUID()
                                    } else {
                                        scheduleHoverDismissal()
                                    }
                                }
                        }
                    }
                }
                .frame(height: 300)
                HistoryNavigator(points: overview, contextPoints: navigatorDetail,
                                 available: availableRange, selection: window, onCommit: apply)
                    .frame(height: 72)
            }
        } label: {
            HStack {
                Text(filter.isEmpty ? L("All traffic") : L("Filtered traffic"))
                Spacer()
            }
        }
    }

    private func chartAccessibilityValue(for point: SeriesPoint) -> String {
        "\(label(for: point.date)), \(L("Received")) \(ByteFormat.string(point.bytesIn)), "
            + "\(L("Sent")) \(ByteFormat.string(point.bytesOut)), "
            + L("%@ new flows", point.flows.formatted())
    }

    private func tooltip(for point: SeriesPoint) -> some View {
        let bucket = contributors[point.date]
        let apps = bucket?.top
        let isAbnormal = flagged.contains(point.date)
        return VStack(alignment: .leading, spacing: 3) {
            Text(label(for: point.date)).font(.caption.bold())
            Text("↓ \(ByteFormat.string(point.bytesIn))   ↑ \(ByteFormat.string(point.bytesOut))").font(.caption.monospacedDigit())
            Text(point.flows == 1 ? L("1 new flow") : L("%@ new flows", point.flows.formatted()))
                .font(.caption2).foregroundStyle(.secondary)
            if isAbnormal {
                Label(abnormalSummary(apps, point: point), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.bold()).foregroundStyle(TrafficColors.anomaly)
            }
            if let apps, !apps.isEmpty, point.total > 0 {
                Divider().padding(.vertical, 2)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            contributorRow(app, share: Double(app.counters.total) / Double(point.total),
                                           emphasized: isAbnormal && index == 0)
                        }
                        if let bucket, bucket.remainingApps > 0 {
                            let count = bucket.remainingApps.formatted()
                            let share = ShareFormat.string(Double(bucket.remaining.total) / Double(point.total))
                            Text(bucket.remainingApps == 1 ? L("+ %@ more app · %@", count, share)
                                                           : L("+ %@ more apps · %@", count, share))
                                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 26)
                        }
                    }
                }
                .frame(height: min(220, max(52, CGFloat(apps.count) * 52)))
                .scrollIndicators(.visible)
            } else if point.total > 0 {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func contributorRow(_ app: BucketContributor, share: Double, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            AppIconView(path: app.appPath, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.appName.isEmpty ? app.bundleID : app.appName).font(.caption.bold()).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit().bold())
                        .foregroundStyle(emphasized ? TrafficColors.anomaly : .primary)
                }
                Text("↓ \(ByteFormat.string(app.counters.bytesIn))  ↑ \(ByteFormat.string(app.counters.bytesOut))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if !app.topDestination.isEmpty {
                    Text("→ \(app.topDestination)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(4)
        .background(emphasized ? TrafficColors.anomaly.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    /// "Abnormal volume · claude 98%" once contributors are known.
    private func abnormalSummary(_ apps: [BucketContributor]?, point: SeriesPoint) -> String {
        guard let top = apps?.first, point.total > 0 else { return L("Abnormal volume") }
        let share = Double(top.counters.total) / Double(point.total)
        let name = top.appName.isEmpty ? top.bundleID : top.appName
        return L("Abnormal volume · %@ %@", name, share.formatted(.percent.precision(.fractionLength(0))))
    }

    private func loadContributors(for point: SeriesPoint?) async {
        guard let point, point.total > 0, contributors[point.date] == nil else { return }
        try? await Task.sleep(for: .milliseconds(60)) // skip buckets the pointer only passes over
        guard !Task.isCancelled else { return }
        let end = Calendar.current.date(byAdding: granularity.calendarComponent, value: 1, to: point.date) ?? point.date
        let (g, f) = (granularity, scoped)
        if let apps = try? await monitor.read({
            try $0.contributors(g, from: point.date, to: end, filter: f, limit: 50)
        }),
           g == granularity, f == scoped {
            contributors[point.date] = apps
        }
    }

    /// The name column for a real row: icon, title, and the hostname beside an IP when there's room for it.
    @ViewBuilder private func nameCell(_ node: TrafficNode) -> some View {
        HStack(spacing: 6) {
            switch node.kind {
            case .app: AppIconView(path: node.appPath)
            case .domain: Image(systemName: "globe").foregroundStyle(.secondary)
            case .owner: Image(systemName: "building.2").foregroundStyle(.secondary)
            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            case .ip: Image(systemName: "number").foregroundStyle(.secondary)
            case .more: EmptyView()
            }
            let title = Text(node.title).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(node.kind == .owner ? Color.secondary : Color.primary)
            if node.detail.isEmpty {
                title
            } else {
                // Hostname beside an IP only when it fits; otherwise it's in the tooltip.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        title.fixedSize()
                        Text(node.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    title
                }
            }
        }
        .help(help(for: node))
    }

    private var table: some View {
        Table(displayed, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(grouping.columnTitle, value: \.title) { node in
                if node.kind == .more {
                    // It is written as a link and coloured as one, so it takes a single click. Leaving it to the
                    // table's double-click made a row that says "Show 25 more" look broken to anyone who clicked it
                    // once and watched nothing happen.
                    Button { showMore(node) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis.circle")
                            Text(node.title).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.link)
                    .help(help(for: node))
                } else {
                    nameCell(node)
                }
            }
            .width(min: 140)
            TableColumn(L("Share"), value: \.total) { node in
                ShareBar(fraction: Double(node.total) / Double(grandTotal))
            }
            .width(80)
            TableColumn(L("↓ Received"), value: \.bytesIn) { Text(ByteFormat.string($0.bytesIn)).monospacedDigit() }
                .width(72)
            TableColumn(L("↑ Sent"), value: \.bytesOut) { Text(ByteFormat.string($0.bytesOut)).monospacedDigit() }
                .width(72)
            TableColumn(L("Total"), value: \.total) { Text(ByteFormat.string($0.total)).monospacedDigit().bold() }
                .width(72)
            TableColumn(L("Flows"), value: \.flows) { Text($0.flows.formatted()).monospacedDigit() }
                .width(48)
            TableColumn(L("Protocol · Port"), value: \.protocols) { node in
                let text = [node.protocols, node.ports].filter { !$0.isEmpty }.joined(separator: " · ")
                Text(text).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).help(text)
            }
            .width(min: 80)
        }
        .contextMenu(forSelectionType: TrafficNode.ID.self) { ids in
            if let id = ids.first, let node = find(id), node.kind != .more {
                Button(L("Show Only This")) { applyFilter(node) }
                if node.kind != .app, let bundleID = node.bundleID {
                    Button(L("Show Only %@", node.appName ?? bundleID)) {
                        var next = filter
                        next.narrowToApp(bundleID)
                        guard next != filter else { return }
                        pushHistory()
                        filter = next
                    }
                }
                Divider()
                InspectMenuItems(filter: node.filter,
                                 app: node.bundleID.map { ($0, node.appName ?? node.title) })
                FocusMenuItems(app: node.kind == .app ? (node.bundleID ?? "", node.title) : nil,
                               host: node.kind == .domain ? node.title : node.kind == .ip ? node.title : nil)
                RuleMenuItems(app: node.kind == .app ? (node.bundleID ?? "", node.title) : nil,
                              host: node.kind == .domain ? node.title : node.kind == .ip ? node.title : nil)
                Divider()
                Button(node.kind == .app ? L("Copy Name") : node.kind == .ip ? L("Copy IP Address") : L("Copy Destination")) { copy(node.title) }
                if node.kind == .app, let bundleID = node.bundleID { Button(L("Copy Bundle ID")) { copy(bundleID) } }
                if node.kind == .ip, !node.detail.isEmpty { Button(L("Copy Hostname")) { copy(node.detail) } }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let node = find(id) else { return }
            if node.moreCount > 0 { showMore(node) } else { applyFilter(node) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if breakdownTruncated {
                Label(grouping == .app
                      ? L("Showing the %@ largest app × destination × IP combinations. Application totals and shares include all traffic; filter or shorten the window for full relationship detail.", TrafficDatabase.breakdownLimit.formatted())
                      : L("Showing the %@ largest app × destination × IP combinations. Destination and IP groupings use this bounded detail; switch to App for complete application totals, or filter or shorten the window.", TrafficDatabase.breakdownLimit.formatted()),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.bar)
            }
        }
        .overlay {
            if displayed.isEmpty && !loading {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView(L("No traffic in this window"), systemImage: "chart.bar",
                                           description: Text(granularity == .second ? L("Per-second data is kept for a few hours.") :
                                                             L("Rollups run once a minute, so new data appears shortly.")))
                }
            }
        }
    }

    // MARK: Actions

    private func apply(_ request: ReportRequest?) {
        guard let request else { return }
        history.clear()
        filter = request.filter
        if let g = request.granularity { granularity = g }
        let requestedEnd = request.end.map { min($0, Date()) } ?? Date()
        let requestedDuration = request.duration ?? granularity.defaultWindow
        endDate = requestedEnd
        startDate = request.start ?? requestedEnd.addingTimeInterval(-requestedDuration)
        followNow = request.end == nil
        selectedPreset = request.preset
        nav.reportRequest = nil
    }

    private func returnToNow() {
        pushHistory()
        let preset = selectedPreset
        apply(window.returningToNow(within: availableRange))
        selectedPreset = preset
    }

    private func apply(_ preset: HistoryRangePreset) {
        pushHistory()
        let next = preset.window(endingAt: Date(), available: availableRange)
        selectedPreset = preset
        startDate = next.start
        endDate = next.end
        followNow = next.followNow
        granularity = next.granularity
        hovered = nil
    }

    private func apply(_ next: HistoryWindow) {
        let clamped = next.clamped(to: availableRange)
        selectedPreset = nil
        startDate = clamped.start
        endDate = clamped.end
        followNow = clamped.followNow
        granularity = clamped.granularity
        hovered = nil
    }

    private func drill(into point: SeriesPoint) {
        guard point.total > 0, let finer = granularity.finer else { return }
        pushHistory()
        let bucketEnd = Calendar.current.date(byAdding: granularity.calendarComponent, value: 1, to: point.date) ?? point.date
        // Show the finer window ending at the bucket's end (or its own natural span, whichever is shorter).
        let end = min(bucketEnd, point.date.addingTimeInterval(finer.defaultWindow))
        granularity = finer
        endDate = min(end, Date())
        startDate = max(point.date, endDate.addingTimeInterval(-finer.defaultWindow))
        followNow = endDate >= Date()
        selectedPreset = nil
        hovered = nil
    }

    private func pushHistory() {
        history.push(ReportNavigationState(
            granularity: granularity,
            startDate: startDate,
            endDate: endDate,
            followNow: followNow,
            filter: filter,
            preset: selectedPreset
        ))
    }

    private func goBack() {
        guard let scope = history.pop() else { return }
        granularity = scope.granularity
        startDate = scope.startDate ?? scope.endDate.addingTimeInterval(-scope.granularity.defaultWindow)
        endDate = scope.endDate
        followNow = scope.followNow
        filter = scope.filter
        selectedPreset = scope.preset
    }

    private func applyFilter(_ node: TrafficNode) {
        guard node.filter != filter else { return }
        pushHistory()
        filter = node.filter
    }

    private func help(for node: TrafficNode) -> String {
        switch node.kind {
        case .app: return [node.bundleID, node.appPath].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .owner: return L("No hostname was seen for this traffic. %@ operates these addresses.", node.title)
        case .more: return L("Show the next %lld rows", TrafficNode.pageSize)
        default: return node.detail.isEmpty ? node.title : "\(node.title) · \(node.detail)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func appName(for bundleID: String) -> String {
        breakdownRows.first { $0.bundleID == bundleID && !$0.appName.isEmpty }?.appName ?? bundleID
    }

    private func find(_ id: String, in list: [TrafficNode]? = nil) -> TrafficNode? {
        for node in list ?? displayed {
            if node.id == id { return node }
            if let hit = find(id, in: node.children ?? []) { return hit }
        }
        return nil
    }

    private func point(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> SeriesPoint? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        guard let date: Date = proxy.value(atX: location.x - origin.x) else { return nil }
        return series.last { $0.date <= date } ?? series.first
    }

    private func lineX(for point: SeriesPoint, proxy: ChartProxy, geo: GeometryProxy) -> CGFloat? {
        guard let plot = proxy.plotFrame,
              let x = proxy.position(forX: point.date) else { return nil }
        return geo[plot].origin.x + x
    }

    private func scheduleHoverDismissal() {
        let requestID = UUID()
        hoverDismissID = requestID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard hoverDismissID == requestID, !tooltipHovered else { return }
            hovered = nil
            hoverLineX = nil
        }
    }

    /// Compact window label: times only when the window is within today, dates for longer spans.
    private var rangeLabel: String {
        let cal = Calendar.current
        let end = followNow ? L("now") : endDate.formatted(date: cal.isDateInToday(endDate) ? .omitted : .abbreviated,
                                                        time: granularity <= .hour ? .shortened : .omitted)
        switch granularity {
        case .second, .minute, .hour:
            let sameDay = cal.isDate(startDate, inSameDayAs: endDate)
            let start = startDate.formatted(date: sameDay && cal.isDateInToday(startDate) ? .omitted : .abbreviated, time: .shortened)
            return "\(start) – \(end)"
        case .day, .week:
            return "\(startDate.formatted(.dateTime.month(.abbreviated).day())) – \(followNow ? L("today") : endDate.formatted(.dateTime.month(.abbreviated).day()))"
        case .month, .year:
            return "\(startDate.formatted(.dateTime.month(.abbreviated).year())) – \(followNow ? L("now") : endDate.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    private func label(for date: Date) -> String {
        switch granularity {
        case .second: return date.formatted(date: .omitted, time: .standard)
        case .minute, .hour: return date.formatted(date: .abbreviated, time: .shortened)
        case .day: return date.formatted(.dateTime.weekday(.abbreviated).month().day().year())
        case .week: return L("Week of %@", date.formatted(date: .abbreviated, time: .omitted))
        case .month: return date.formatted(.dateTime.month(.wide).year())
        case .year: return date.formatted(.dateTime.year())
        }
    }

    /// When history is shorter than the window (e.g. a fresh install in the hour view), start the
    /// chart near the first bucket with data instead of showing a mostly empty plot.
    static func trimLeadingEmpty(_ series: [SeriesPoint], minimumBuckets: Int = 12) -> [SeriesPoint] {
        guard let first = series.firstIndex(where: { $0.total > 0 || $0.flows > 0 }) else { return series }
        let start = max(0, min(first - 1, series.count - minimumBuckets))
        return Array(series[start...])
    }

    private func showMore(_ node: TrafficNode) {
        let page = TrafficTreePaging.showMore(
            nodes,
            query: query,
            comparators: sortOrder,
            limits: childLimits,
            after: node.id,
            levels: grouping.levels
        )
        childLimits = page.limits
        displayed = page.displayed
        selection = nil
    }

    private func recompute() {
        displayed = TrafficTreePaging.project(
            nodes,
            query: query,
            comparators: sortOrder,
            limits: childLimits,
            levels: grouping.levels
        ).displayed
    }

    private func reloadNavigator() async {
        let activeFilter = scoped
        do {
            let loaded = try await monitor.read { db -> (ClosedRange<Date>, [SeriesPoint]) in
                try db.readSnapshot {
                    let now = Date()
                    let retained = try db.trafficDateBounds()
                        ?? now.addingTimeInterval(-6 * 3_600)...now
                    let bounds = retained.lowerBound...max(retained.upperBound, now)
                    let resolution = HistoryWindow(
                        start: bounds.lowerBound,
                        end: bounds.upperBound,
                        followNow: true
                    ).granularity
                    return (bounds, try db.series(resolution, from: bounds.lowerBound,
                                                  to: bounds.upperBound, filter: activeFilter))
                }
            }
            guard !Task.isCancelled else { return }
            availableRange = loaded.0
            overview = loaded.1
            let next = window.clamped(to: loaded.0)
            startDate = next.start
            endDate = next.end
            followNow = next.followNow
        } catch {
            guard !Task.isCancelled else { return }
            monitor.lastError = L("History overview failed: %@", error.localizedDescription)
        }
    }

    private func reloadNavigatorDetail() async {
        let bounds = availableRange
        let selected = window.clamped(to: bounds)
        let domain = HistoryNavigatorDomain.range(available: bounds, selection: selected)
        guard domain != bounds else {
            navigatorDetail = []
            return
        }

        let activeFilter = scoped
        let resolution = HistoryWindow(start: domain.lowerBound, end: domain.upperBound,
                                       followNow: selected.followNow).granularity
        do {
            let loaded = try await monitor.read { db in
                try db.readSnapshot {
                    try db.series(resolution, from: domain.lowerBound,
                                  to: domain.upperBound, filter: activeFilter)
                }
            }
            guard !Task.isCancelled,
                  activeFilter == scoped,
                  domain == HistoryNavigatorDomain.range(
                    available: availableRange,
                    selection: window.clamped(to: availableRange)
                  ) else { return }
            navigatorDetail = loaded
        } catch {
            guard !Task.isCancelled else { return }
            monitor.lastError = L("History overview failed: %@", error.localizedDescription)
        }
    }

    private func reload() async {
        if followNow {
            let width = max(60, endDate.timeIntervalSince(startDate))
            endDate = Date()
            startDate = endDate.addingTimeInterval(-width)
        }
        let requestID = UUID()
        reloadID = requestID
        loading = true
        defer {
            if reloadID == requestID { loading = false }
        }
        let (g, from, to, f, m, requestedMode) = (granularity, startDate, endDate, scoped, metric, lowerMode)
        let wantsCharts = requestedMode == .charts
        do {
            let wantsBehaviour = requestedMode == .behaviour
            let result = try await monitor.read { db -> ([SeriesPoint], ReportsBreakdown, InsightsSnapshot?, [BreakdownRow], RiskAssessmentCounts) in
                try db.readSnapshot {
                    let series = try db.series(g, from: from, to: to, filter: f)
                    let breakdown = try db.reportsBreakdown(g, from: from, to: to, filter: f)
                    let behaviourRows = wantsBehaviour
                        ? try db.appDestinationRows(g, from: from, to: to, filter: f)
                        : []
                    let risk = try db.localRiskCounts(since: from, to: to, filter: f)
                    guard wantsCharts else { return (series, breakdown, nil, behaviourRows, risk) }
                    let snapshot = try InsightsBuilder.load(
                        db: db,
                        dimensions: InsightDimension.available(for: f),
                        series: series,
                        metric: m,
                        granularity: g,
                        from: from,
                        to: to,
                        filter: f
                    )
                    return (series, breakdown, snapshot, behaviourRows, risk)
                }
            }
            guard !Task.isCancelled, reloadID == requestID,
                  g == granularity, from == startDate, to == endDate,
                  f == scoped, m == metric, requestedMode == lowerMode
            else { return } // a newer request superseded this one
            if let snapshot = result.2 {
                for insight in snapshot.dimensions {
                    registries[insight.dimension, default: ColorRegistry()]
                        .assign(visible: insight.slices.filter { $0.entity.kind != .other }.map(\.entity.key))
                }
                insights = snapshot
            }
            series = Self.trimLeadingEmpty(result.0)
            flagged = SeriesAnomalies.flagged(result.0, sigma: sigma)
            contributors = [:]
            breakdownTruncated = result.1.isTruncated
            breakdownRows = result.1.rows
            breakdownAppTotals = result.1.appTotals
            // This projection preserves attribution and route evidence that Reports does not need.
            behaviour = DestinationProfile.analyse(result.3)
            localRiskCounts = result.4
            nodes = TrafficNode.tree(
                from: result.1.rows,
                appTotals: grouping == .app ? result.1.appTotals : [],
                grouping: grouping,
                base: f
            )
            if hovered != nil { hovered = series.first { $0.date == hovered?.date } }
        } catch {
            guard !Task.isCancelled, reloadID == requestID,
                  g == granularity, from == startDate, to == endDate,
                  f == scoped, m == metric, requestedMode == lowerMode
            else { return }
            monitor.lastError = L("Query failed: %@", "\(error)")
        }
    }

    private func export(csv: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(name)-\(granularity.rawValue).csv"
        if panel.runModal() == .OK, let url = panel.url {
            do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { monitor.lastError = L("Export failed: %@", error.localizedDescription) }
        }
    }
}

private struct HistoryNavigator: View {
    enum DragMode { case start, pan, end }

    var points: [SeriesPoint]
    var contextPoints: [SeriesPoint]
    var available: ClosedRange<Date>
    var selection: HistoryWindow
    var onCommit: (HistoryWindow) -> Void

    @State private var draft: HistoryWindow?
    @State private var dragMode: DragMode?
    @State private var dragOrigin: HistoryWindow?
    @State private var showsFullHistory = false

    private var visible: HistoryWindow { draft ?? selection }
    private var nearbyDomain: ClosedRange<Date> {
        HistoryNavigatorDomain.range(available: available, selection: dragOrigin ?? visible)
    }
    private var usesNearbyDomain: Bool { nearbyDomain != available }
    private var domain: ClosedRange<Date> { showsFullHistory ? available : nearbyDomain }
    private var domainDuration: TimeInterval {
        max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
    }
    private var plottedPoints: [SeriesPoint] {
        let source = showsFullHistory || contextPoints.isEmpty ? points : contextPoints
        return source.filter { domain.contains($0.date) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(showsFullHistory || !usesNearbyDomain ? L("Full history") : L("Nearby context"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if usesNearbyDomain {
                    Button(showsFullHistory ? L("Nearby") : L("All history")) {
                        showsFullHistory.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 2)

            GeometryReader { geometry in
                Canvas { context, size in
                    drawOverview(context: &context, size: size)
                    drawSelection(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    let step = max(60, visible.duration * 0.1)
                    switch direction {
                    case .left: onCommit(visible.panned(by: -step, within: available))
                    case .right: onCommit(visible.panned(by: step, within: available))
                    default: break
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("History range navigator"))
                .accessibilityValue("\(visible.start.formatted(date: .abbreviated, time: .shortened)) – \(visible.end.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityHint(L("Drag the selection to move through history, drag either edge to resize it, or use the Left and Right Arrow keys."))
                .accessibilityAdjustableAction { direction in
                    let step = max(60, visible.duration * 0.1)
                    switch direction {
                    case .increment: onCommit(visible.panned(by: step, within: available))
                    case .decrement: onCommit(visible.panned(by: -step, within: available))
                    @unknown default: break
                    }
                }
            }
        }
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        let offset = date.timeIntervalSince(domain.lowerBound)
        return width * CGFloat(min(1, max(0, offset / domainDuration)))
    }

    private func drawOverview(context: inout GraphicsContext, size: CGSize) {
        let surface = Path(CGRect(origin: .zero, size: size))
        context.fill(surface, with: .color(FL.surface2))
        guard !plottedPoints.isEmpty,
              let peak = plottedPoints.map(\.total).max(), peak > 0 else { return }
        var path = Path()
        for (index, point) in plottedPoints.enumerated() {
            let px = x(for: point.date, width: size.width)
            let ratio = CGFloat(Double(point.total) / Double(peak))
            let py = size.height - 6 - ratio * max(1, size.height - 12)
            if index == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        context.stroke(path, with: .color(FL.accent.opacity(0.7)), lineWidth: 1.5)
    }

    private func brushBounds(width: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let actualStart = x(for: visible.start, width: width)
        let actualEnd = x(for: visible.end, width: width)
        let minimumWidth = min(32, width)
        guard actualEnd - actualStart < minimumWidth else { return (actualStart, actualEnd) }

        let proposedStart = (actualStart + actualEnd - minimumWidth) / 2
        let start = min(max(0, proposedStart), max(0, width - minimumWidth))
        return (start, start + minimumWidth)
    }

    private func drawSelection(context: inout GraphicsContext, size: CGSize) {
        let (startX, endX) = brushBounds(width: size.width)
        let rect = CGRect(x: startX, y: 1, width: endX - startX, height: max(2, size.height - 2))
        context.fill(Path(rect), with: .color(FL.accent.opacity(0.14)))
        context.stroke(Path(rect), with: .color(FL.accent.opacity(0.8)), lineWidth: 1)
        for handleX in [startX, endX] {
            let handle = CGRect(x: handleX - 2, y: size.height / 2 - 10, width: 4, height: 20)
            context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(FL.accent))
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    let (startX, endX) = brushBounds(width: width)
                    dragMode = abs(value.startLocation.x - startX) <= 14 ? .start
                        : abs(value.startLocation.x - endX) <= 14 ? .end : .pan
                    dragOrigin = visible
                }
                guard let dragMode, let origin = dragOrigin else { return }
                let delta = domainDuration * Double(value.translation.width / max(1, width))
                switch dragMode {
                case .start:
                    draft = origin.resized(start: origin.start.addingTimeInterval(delta), end: origin.end,
                                           within: available, minimumDuration: 60)
                case .end:
                    draft = origin.resized(start: origin.start, end: origin.end.addingTimeInterval(delta),
                                           within: available, minimumDuration: 60)
                case .pan:
                    draft = origin.panned(by: delta, within: available)
                }
            }
            .onEnded { _ in
                if let draft { onCommit(draft) }
                self.draft = nil
                dragOrigin = nil
                dragMode = nil
            }
    }
}

struct ShareBar: View {
    var fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(FL.accent.opacity(0.8)).frame(width: max(2, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 5)
            Text(fraction >= 0.001 ? fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) : "<0.1%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(L("%lld percent of traffic", Int((fraction * 100).rounded())))
    }
}

extension Granularity: Comparable {
    static func < (a: Granularity, b: Granularity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// The next finer granularity for drill-down (week drills into days).
    var finer: Granularity? {
        switch self {
        case .second: return nil
        case .minute: return .second
        case .hour: return .minute
        case .day: return .hour
        case .week, .month: return .day
        case .year: return .month
        }
    }
}
