import Charts
import SwiftUI

enum LiveChartKeyboardDirection {
    case left, right
}

enum LiveChartSelection {
    static func move(from current: Date?, direction: LiveChartKeyboardDirection, dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        guard let current, let index = dates.firstIndex(of: current) else {
            return direction == .left ? dates.last : dates.first
        }
        switch direction {
        case .left: return dates[max(0, index - 1)]
        case .right: return dates[min(dates.count - 1, index + 1)]
        }
    }

    static func reconcile(_ current: Date?, dates: [Date]) -> Date? {
        guard let current, !dates.contains(current) else { return current }
        return dates.min { abs($0.timeIntervalSince(current)) < abs($1.timeIntervalSince(current)) }
    }

    static func date(hovered: Date?, keyboard: Date?, chartFocused: Bool) -> Date? {
        hovered ?? (chartFocused ? keyboard : nil)
    }
}

struct LiveView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var sortOrder = [KeyPathComparator(\LiveTalker.totalRate, order: .reverse)]
    @State private var selection: LiveTalker.ID?
    @State private var hoveredDate: Date?
    @State private var keyboardDate: Date?
    @FocusState private var chartFocused: Bool

    private var highlightedPoint: SeriesPoint? {
        let date = LiveChartSelection.date(hovered: hoveredDate, keyboard: keyboardDate, chartFocused: chartFocused)
        return monitor.liveSeries.first { $0.date == date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatTile(title: L("Download"), value: ByteFormat.rate(monitor.currentIn), systemImage: "arrow.down", tint: TrafficColors.inbound)
                StatTile(title: L("Upload"), value: ByteFormat.rate(monitor.currentOut), systemImage: "arrow.up", tint: TrafficColors.outbound)
                StatTile(title: L("Received this session"), value: ByteFormat.string(monitor.sessionIn), systemImage: "tray.and.arrow.down", tint: TrafficColors.inbound)
                StatTile(title: L("Sent this session"), value: ByteFormat.string(monitor.sessionOut), systemImage: "tray.and.arrow.up", tint: TrafficColors.outbound)
            }

            liveChart

            GroupBox {
                Table(monitor.talkers.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(L("Application"), value: \.name) { t in
                        HStack { AppIconView(path: t.path); Text(t.name) }.help(L("%@\nDouble-click to open in History", t.bundleID))
                    }
                    .width(min: 130)
                    TableColumn(L("↓ In"), value: \.rateIn) { Text("\(ByteFormat.compact($0.rateIn))/s").monospacedDigit().help(ByteFormat.rate($0.rateIn)) }
                        .width(76)
                    TableColumn(L("↑ Out"), value: \.rateOut) { Text("\(ByteFormat.compact($0.rateOut))/s").monospacedDigit().help(ByteFormat.rate($0.rateOut)) }
                        .width(76)
                    TableColumn(L("Total"), value: \.totalRate) { Text("\(ByteFormat.compact($0.totalRate))/s").monospacedDigit().bold().help(ByteFormat.rate($0.totalRate)) }
                        .width(76)
                    TableColumn(L("Session ↓"), value: \.sessionIn) { Text(ByteFormat.string($0.sessionIn)).monospacedDigit() }
                        .width(70)
                    TableColumn(L("Session ↑"), value: \.sessionOut) { Text(ByteFormat.string($0.sessionOut)).monospacedDigit() }
                        .width(70)
                    TableColumn(L("Busiest destination"), value: \.topDestination) { Text($0.topDestination).lineLimit(1).truncationMode(.middle).help($0.topDestination) }
                        .width(min: 150)
                }
                .contextMenu(forSelectionType: LiveTalker.ID.self) { ids in
                    if let id = ids.first {
                        Button(L("Show in History")) { openReport(id) }
                        InspectMenuItems(app: (id, monitor.talkers.first { $0.bundleID == id }?.name ?? id),
                                         host: monitor.talkers.first { $0.bundleID == id }?.topDestination)
                        FocusMenuItems(app: (id, monitor.talkers.first { $0.bundleID == id }?.name ?? id))
                        Divider()
                        RuleMenuItems(app: (id, monitor.talkers.first { $0.bundleID == id }?.name ?? id),
                                      host: monitor.talkers.first { $0.bundleID == id }?.topDestination)
                        Button(L("Copy Bundle ID")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(id, forType: .string)
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { openReport(id) }
                }
                .overlay { emptyState }
            } label: {
                Text(L("Top talkers · average of the last 5 seconds"))
            }
        }
        .padding()
        .navigationTitle(L("Live"))
    }

    private var liveChart: some View {
        let highlighted = highlightedPoint
        return GroupBox {
            Chart {
                ForEach(monitor.liveSeries) { point in
                    AreaMark(x: .value(L("Time"), point.date), y: .value(L("Bytes/s"), point.bytesIn), series: .value(L("Direction"), L("Download")))
                        .foregroundStyle(TrafficColors.inbound.opacity(0.12))
                    LineMark(x: .value(L("Time"), point.date), y: .value(L("Bytes/s"), point.bytesIn), series: .value(L("Direction"), L("Download")))
                        .foregroundStyle(TrafficColors.inbound)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    AreaMark(x: .value(L("Time"), point.date), y: .value(L("Bytes/s"), -point.bytesOut), series: .value(L("Direction"), L("Upload")))
                        .foregroundStyle(TrafficColors.outbound.opacity(0.12))
                    LineMark(x: .value(L("Time"), point.date), y: .value(L("Bytes/s"), -point.bytesOut), series: .value(L("Direction"), L("Upload")))
                        .foregroundStyle(TrafficColors.outbound)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 3]))
                }
                RuleMark(y: .value(L("Zero"), 0))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                if let highlighted {
                    RuleMark(x: .value(L("Time"), highlighted.date))
                        .foregroundStyle(.secondary.opacity(0.35))
                    PointMark(x: .value(L("Time"), highlighted.date), y: .value(L("Bytes/s"), highlighted.bytesIn))
                        .symbol(.circle).symbolSize(50).foregroundStyle(TrafficColors.inbound)
                    PointMark(x: .value(L("Time"), highlighted.date), y: .value(L("Bytes/s"), -highlighted.bytesOut))
                        .symbol(.diamond).symbolSize(55).foregroundStyle(TrafficColors.outbound)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int64.self) { Text(ByteFormat.rate(Double(abs(v)))) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    hoveredDate = livePoint(at: location, proxy: proxy, geometry: geometry)?.date
                                case .ended:
                                    hoveredDate = nil
                                }
                            }
                        if let highlighted,
                           let plot = proxy.plotFrame,
                           let position = proxy.position(forX: highlighted.date) {
                            liveTooltip(highlighted)
                                .offset(x: ReportChartHoverLayout.cardX(
                                    lineX: geometry[plot].origin.x + position,
                                    chartWidth: geometry.size.width,
                                    cardWidth: 230
                                ), y: 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($chartFocused)
            .onMoveCommand { direction in
                let move: LiveChartKeyboardDirection
                switch direction {
                case .left: move = .left
                case .right: move = .right
                default: return
                }
                hoveredDate = nil
                keyboardDate = LiveChartSelection.move(
                    from: keyboardDate,
                    direction: move,
                    dates: monitor.liveSeries.map(\.date)
                )
            }
            .onChange(of: monitor.liveSeries.map(\.date)) { _, dates in
                keyboardDate = LiveChartSelection.reconcile(keyboardDate, dates: dates)
            }
            .accessibilityLabel(L("Live network traffic"))
            .accessibilityValue(highlighted.map(liveAccessibilityValue) ?? L("No time selected"))
            .accessibilityHint(L("Solid circles are downloads; dashed diamonds are uploads. Use the Left and Right Arrow keys to inspect each second."))
            .accessibilityChildren {
                ForEach(monitor.liveSeries) { point in
                    Text(liveAccessibilityValue(point))
                        .accessibilityLabel(point.date.formatted(date: .omitted, time: .standard))
                        .accessibilityValue(liveAccessibilityValue(point))
                }
            }
            .frame(height: 180)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 14) {
                Text(L("Last 2 minutes"))
                Spacer()
                Label(L("Download · solid"), systemImage: "arrow.down")
                    .foregroundStyle(TrafficColors.inbound)
                Label(L("Upload · dashed"), systemImage: "arrow.up")
                    .foregroundStyle(TrafficColors.outbound)
            }
            .font(.caption)
        }
    }

    private func livePoint(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> SeriesPoint? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard ReportChartHoverLayout.contains(location, in: frame),
              let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return nil }
        return monitor.liveSeries.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func liveAccessibilityValue(_ point: SeriesPoint) -> String {
        "\(point.date.formatted(date: .omitted, time: .standard)), "
            + "\(L("Download")) \(ByteFormat.rate(Double(point.bytesIn))), "
            + "\(L("Upload")) \(ByteFormat.rate(Double(point.bytesOut)))"
    }

    private func liveTooltip(_ point: SeriesPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(point.date.formatted(date: .omitted, time: .standard)).font(.caption.bold())
            Label(ByteFormat.rate(Double(point.bytesIn)), systemImage: "arrow.down.circle.fill")
                .symbolRenderingMode(.hierarchical)
            Label(ByteFormat.rate(Double(point.bytesOut)), systemImage: "arrow.up.diamond.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(8)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var emptyState: some View {
        if monitor.talkers.isEmpty {
            if monitor.isReceiving {
                ContentUnavailableView(L("The network is quiet"), systemImage: "network",
                                       description: Text(L("No app has sent or received data in the last few seconds.")))
            } else {
                ContentUnavailableView {
                    Label(L("Waiting for traffic data"), systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    // The banner explains a source that cannot work here; the status line is for everything else.
                    if monitor.captureWarning != nil {
                        CaptureWarningBanner().frame(maxWidth: 520)
                    } else {
                        Text(monitor.status)
                    }
                } actions: {
                    Button(L("Sources")) { nav.showSources(.collector) }
                }
            }
        }
    }

    private func openReport(_ bundleID: String) {
        nav.showReport(filter: TrafficFilter(bundleID: bundleID), granularity: .minute)
    }
}

extension LiveTalker {
    var totalRate: Double { rateIn + rateOut }
}
