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

struct ReportsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var focus: FocusStore
    @AppStorage("reports.granularity") private var granularity: Granularity = .minute
    @AppStorage(AnomalySettings.Keys.sigma) private var sigma = 3.0
    @State private var endDate = Date()
    @State private var followNow = true
    @State private var filter = TrafficFilter.none
    @State private var query = ""
    @State private var series: [SeriesPoint] = []
    @State private var nodes: [TrafficNode] = []
    @State private var displayed: [TrafficNode] = []
    @State private var flagged: Set<Date> = []
    @State private var sortOrder = [KeyPathComparator(\TrafficNode.total, order: .reverse)]
    @State private var selection: TrafficNode.ID?
    @State private var loading = false
    @State private var hovered: SeriesPoint?
    /// Top apps per bucket, fetched on hover and cached until the next reload.
    @State private var contributors: [Date: BucketContributors] = [:]
    /// How many children each parent row shows (grown by "Show more"); "__root__" is the app list.
    @State private var childLimits: [String: Int] = [:]
    @State private var breakdownTruncated = false
    @State private var history: [Scope] = []
    @AppStorage("reports.lowerMode") private var lowerMode: LowerMode = .breakdown
    @AppStorage("reports.grouping") private var grouping: BreakdownGrouping = .app
    /// Raw breakdown rows; the tree is rebuilt from these when the grouping changes (no re-query).
    @State private var breakdownRows: [BreakdownRow] = []
    @AppStorage("reports.insightMetric") private var metric: InsightMetric = .total
    @State private var insights = InsightsSnapshot.empty
    @State private var registries: [InsightDimension: ColorRegistry] = [:]
    /// Apps whose destinations stand out from the rest of this report. Rebuilt from the same breakdown rows.
    @State private var behaviour: [AppBehaviour] = []

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

    /// A snapshot of what is on screen, for the drill-down back stack.
    private struct Scope { var granularity: Granularity; var endDate: Date; var followNow: Bool }

    private var startDate: Date { endDate.addingTimeInterval(-granularity.defaultWindow) }
    /// From the series, not the table rows, so shares stay right even if the table is capped.
    private var grandTotal: Int64 { max(1, series.reduce(0) { $0 + $1.total }) }

    var body: some View {
        Group {
            if lowerMode == .charts {
                // Charts stack taller than the window, so the whole report scrolls.
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
            } else if lowerMode == .behaviour {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        lowerModeBar
                        BehaviourPanel(findings: behaviour, period: granularity.periodName) { finding in
                            filter = TrafficFilter(bundleID: finding.bundleID)
                            lowerMode = .breakdown
                        }
                    }
                    .padding()
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    lowerModeBar
                    table
                }
                .padding()
            }
        }
        .navigationTitle(L("Reports"))
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
        .task(id: ReloadKey(granularity: granularity, end: followNow ? nil : endDate, filter: scoped, version: monitor.dataVersion,
                            mode: lowerMode, metric: metric)) {
            await reload()
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
        .task(id: hovered?.date) { await loadContributors(for: hovered) }
    }

    /// What the screen actually queries: the filter chosen here, narrowed by Focus when it's on.
    private var scoped: TrafficFilter {
        var f = filter
        f.focus = focus.scope
        return f
    }

    private struct ReloadKey: Equatable {
        var granularity: Granularity; var end: Date?; var filter: TrafficFilter; var version: Int
        var mode: LowerMode; var metric: InsightMetric
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        controls
        if !filter.isEmpty { filterChips }
        coverageNotice
        summary
        chart
    }

    private var coverageNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(L("Hostname coverage, last hour: %@ of bytes",
                   monitor.coverage.named.formatted(.percent.precision(.fractionLength(0)))))
            Text("·")
            Text(L("including network owners: %@",
                   monitor.coverage.owned.formatted(.percent.precision(.fractionLength(0)))))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(L("Coverage is for all traffic in the last hour, not the selected report window. IPs without names may belong to shared hosting or CDNs."))
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
            nodes = TrafficNode.tree(from: breakdownRows, grouping: grouping, base: filter)
        }
    }

    private var emptyCharts: some View {
        ContentUnavailableView(L("No traffic in this window"), systemImage: "chart.pie",
                               description: Text(L("Choose a longer window or clear filters.")))
            .frame(minHeight: 200)
    }

    /// What the charts are scoped to, for their titles ("Destinations · claude").
    private var scopeName: String? {
        [filter.bundleID.map(appName(for:)), filter.domainSuffix, filter.owner, filter.domain.flatMap { $0.isEmpty ? nil : $0 },
         filter.remoteIP, filter.appProtocol, filter.channel.map(\.localizedTitle)].compactMap { $0 }.first
    }

    private func narrow(to entity: InsightEntity) {
        guard let next = entity.narrowing(filter) else { return }
        filter = next
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if !history.isEmpty {
                Button { goBack() } label: { Label(L("Back"), systemImage: "arrow.uturn.backward") }
                    .help(L("Return to the previous zoom level"))
            }
            Picker(L("Granularity"), selection: Binding(get: { granularity }, set: { history.removeAll(); granularity = $0 })) {
                ForEach(Granularity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            Spacer()

            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help(L("Earlier (⌘[)")).accessibilityLabel(L("Earlier"))
                .keyboardShortcut("[", modifiers: .command)
            Text(rangeLabel)
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help("\(startDate.formatted(date: .complete, time: .shortened)) – \(endDate.formatted(date: .complete, time: .shortened))")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help(L("Later (⌘])")).accessibilityLabel(L("Later"))
                .keyboardShortcut("]", modifiers: .command)
                .disabled(followNow)
            Button(L("Now")) { followNow = true; endDate = Date() }.disabled(followNow)
        }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            Text(L("Showing only:")).font(.caption).foregroundStyle(.secondary)
            if let app = filter.bundleID { chip(L("App: %@", appName(for: app))) { filter.bundleID = nil } }
            if let owner = filter.owner { chip(L("Owner: %@", owner)) { filter.owner = nil; filter.domain = nil; filter.remoteIP = nil } }
            else if let domain = filter.domain { chip(L("Domain: %@", domain.isEmpty ? L("(none)") : domain)) { filter.domain = nil; filter.remoteIP = nil } }
            if let suffix = filter.domainSuffix { chip(L("Domain: *.%@", suffix)) { filter.domainSuffix = nil; filter.remoteIP = nil } }
            if let ip = filter.remoteIP { chip(L("IP: %@", ip)) { filter.remoteIP = nil } }
            if let proto = filter.appProtocol { chip(L("Protocol: %@", proto)) { filter.appProtocol = nil } }
            if let channel = filter.channel { chip(L("Way out: %@", channel.localizedTitle)) { filter.channel = nil } }
            Button(L("Clear")) { filter = .none }.buttonStyle(.link).font(.caption)
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
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
        GroupBox {
            Chart {
                ForEach(series) { point in
                    BarMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent),
                            y: .value(L("Bytes"), point.bytesIn))
                        .foregroundStyle(by: .value(L("Direction"), L("Received")))
                        .opacity(hovered == nil || hovered?.date == point.date ? 1 : 0.55)
                    BarMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent),
                            y: .value(L("Bytes"), point.bytesOut))
                        .foregroundStyle(by: .value(L("Direction"), L("Sent")))
                        .opacity(hovered == nil || hovered?.date == point.date ? 1 : 0.55)
                }
                ForEach(series.filter { flagged.contains($0.date) }) { point in
                    PointMark(x: .value(L("Time"), point.date, unit: granularity.calendarComponent), y: .value(L("Bytes"), point.total))
                        .symbol(.triangle)
                        .symbolSize(30)
                        .foregroundStyle(TrafficColors.anomaly)
                        .offset(y: -8)
                }
                if let hovered {
                    RuleMark(x: .value(L("Time"), hovered.date, unit: granularity.calendarComponent))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(for: hovered)
                        }
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
                            case .active(let location): hovered = point(at: location, proxy: proxy, geo: geo)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            if let point = point(at: location, proxy: proxy, geo: geo) { drill(into: point) }
                        }
                }
            }
            .frame(height: 220)
            .overlay { if loading && series.isEmpty { ProgressView() } }
        } label: {
            HStack {
                Text(filter.isEmpty ? L("All traffic") : L("Filtered traffic"))
                Spacer()
                if granularity.finer != nil {
                    Text(L("Click a bar to zoom in")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
        let (g, f) = (granularity, filter)
        if let apps = try? await monitor.read({ try $0.contributors(g, from: point.date, to: end, filter: f) }),
           g == granularity, f == filter {
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
                    Button(L("Show Only %@", node.appName ?? bundleID)) { var f = filter; f.bundleID = bundleID; filter = f }
                }
                Divider()
                InspectMenuItems(app: node.kind == .app ? (node.bundleID ?? "", node.title) : nil,
                                 host: node.kind == .domain || node.kind == .ip ? node.title : nil)
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
        .onChange(of: childLimits) { recompute() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if breakdownTruncated {
                Label(L("Showing the %@ largest app × destination × IP combinations. Totals and shares include all traffic; filter or shorten the window for full detail.",
                        TrafficDatabase.breakdownLimit.formatted()),
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
        history.removeAll()
        filter = request.filter
        if let g = request.granularity { granularity = g }
        if let end = request.end, end < Date() { endDate = end; followNow = false } else { followNow = true; endDate = Date() }
        nav.reportRequest = nil
    }

    private func shift(_ direction: Double) {
        let base = followNow ? Date() : endDate
        let next = base.addingTimeInterval(direction * granularity.defaultWindow)
        if next >= Date() { followNow = true; endDate = Date() } else { followNow = false; endDate = next }
    }

    private func drill(into point: SeriesPoint) {
        guard let finer = granularity.finer else { return }
        history.append(Scope(granularity: granularity, endDate: endDate, followNow: followNow))
        let bucketEnd = Calendar.current.date(byAdding: granularity.calendarComponent, value: 1, to: point.date) ?? point.date
        // Show the finer window ending at the bucket's end (or its own natural span, whichever is shorter).
        let end = min(bucketEnd, point.date.addingTimeInterval(finer.defaultWindow))
        granularity = finer
        if end >= Date() { followNow = true; endDate = Date() } else { followNow = false; endDate = end }
        hovered = nil
    }

    private func goBack() {
        guard let scope = history.popLast() else { return }
        granularity = scope.granularity
        endDate = scope.endDate
        followNow = scope.followNow
    }

    private func applyFilter(_ node: TrafficNode) {
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
        childLimits = TrafficNode.showingMore(childLimits, after: node.id)
        selection = nil
    }

    private func recompute() {
        let sorted = TrafficNode.filter(nodes, query: query).sorted(using: sortOrder).map { $0.sorted(using: sortOrder) }
        displayed = TrafficNode.capped(sorted, parentID: TrafficNode.rootID, parent: nil, limits: childLimits, levels: grouping.levels)
    }

    private func reload() async {
        if followNow { endDate = Date() }
        loading = true
        defer { loading = false }
        let (g, from, to, f, m) = (granularity, startDate, endDate, scoped, metric)
        let wantsCharts = lowerMode == .charts
        do {
            let wantsBehaviour = lowerMode == .behaviour
            let result = try await monitor.read { db -> ([SeriesPoint], [BreakdownRow], InsightsSnapshot?, [BreakdownRow]) in
                let series = try db.series(g, from: from, to: to, filter: f)
                let breakdown = try db.breakdown(g, from: from, to: to, filter: f)
                let behaviourRows = wantsBehaviour ? try db.appDestinationRows(g, from: from, to: to, filter: f) : []
                guard wantsCharts else { return (series, breakdown, nil, behaviourRows) }
                let snapshot = try InsightsBuilder.load(db: db, dimensions: InsightDimension.available(for: f), series: series,
                                                        metric: m, granularity: g, from: from, to: to, filter: f)
                return (series, breakdown, snapshot, behaviourRows)
            }
            guard g == granularity, f == scoped, m == metric else { return } // a newer request superseded this one
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
            breakdownTruncated = result.1.count >= TrafficDatabase.breakdownLimit
            breakdownRows = result.1
            // Not result.1: those rows stop at breakdownLimit, and an app past the cap would silently never be
            // considered. This asks for every app's destinations on their own, which is a much smaller result.
            behaviour = DestinationProfile.analyse(result.3)
            nodes = TrafficNode.tree(from: result.1, grouping: grouping, base: f)
            if hovered != nil { hovered = series.first { $0.date == hovered?.date } }
        } catch {
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
