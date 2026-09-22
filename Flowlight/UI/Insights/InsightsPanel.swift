import Charts
import SwiftUI

/// Share and trend charts for the current report scope. Every chart narrows the report on click.
struct InsightsPanel: View {
    var snapshot: InsightsSnapshot
    var registries: [InsightDimension: ColorRegistry]
    var metric: InsightMetric
    var granularity: Granularity
    var scopeName: String?
    var onSelect: (InsightEntity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(snapshot.dimensions.prefix(3)) { insight in
                    DonutCard(insight: insight, registry: registries[insight.dimension] ?? ColorRegistry(),
                              metric: metric, title: shareTitle(insight.dimension), onSelect: onSelect)
                }
                if snapshot.dimensions.count < 3 {
                    DirectionCard(total: snapshot.total)
                }
            }
            // A trend of a single entity repeats the main chart; only compare two or more.
            ForEach(snapshot.dimensions.filter { $0.leaderTrends.count >= 2 }.prefix(2)) { insight in
                TrendCard(insight: insight, registry: registries[insight.dimension] ?? ColorRegistry(),
                          metric: metric, granularity: granularity, title: trendTitle(insight.dimension), onSelect: onSelect)
            }
        }
    }

    private func shareTitle(_ d: InsightDimension) -> String {
        scopeName.map { "\(d.title) · \($0)" } ?? d.title
    }

    private func trendTitle(_ d: InsightDimension) -> String {
        let base = "Top \(d.title.lowercased()) over time"
        return scopeName.map { "\(base) · \($0)" } ?? base
    }
}

// MARK: - Donut

struct DonutCard: View {
    var insight: DimensionInsight
    var registry: ColorRegistry
    var metric: InsightMetric
    var title: String
    var onSelect: (InsightEntity) -> Void

    @State private var angle: Int64?
    @State private var hoveredKey: String?
    @State private var showAll = false

    private var slices: [InsightSlice] { insight.slices }

    /// The slice under the pointer, from either the donut or the legend.
    private var focused: InsightSlice? {
        if let hoveredKey { return slices.first { $0.entity.key == hoveredKey } }
        guard let angle else { return nil }
        var running: Int64 = 0
        for slice in slices {
            running += metric.value(slice.counters)
            if angle <= running { return slice }
        }
        return nil
    }

    var body: some View {
        GroupBox {
            if slices.count < 2 {
                singleEntity
            } else {
                VStack(spacing: 10) {
                    donut
                    legend
                }
            }
        } label: {
            Text(title).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value(metric.title, metric.value(slice.counters)),
                       innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(registry.color(for: slice.entity))
                .opacity(focused == nil || focused?.id == slice.id ? 1 : 0.35)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $angle)
        .frame(height: 150)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame {
                    let rect = geo[frame]
                    centerLabel.position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .onTapGesture {
            guard let focused else { return }
            if focused.entity.kind == .other { showAll = true } else { onSelect(focused.entity) }
        }
        .popover(isPresented: $showAll, arrowEdge: .trailing) {
            EntityListView(insight: insight, metric: metric) { entity in
                showAll = false
                onSelect(entity)
            }
        }
        .accessibilityLabel("\(title) share chart")
    }

    private var centerLabel: some View {
        VStack(spacing: 1) {
            if let focused {
                Text(ShareFormat.string(focused.share)).font(.title3.monospacedDigit().bold())
                Text(focused.entity.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 80)
            } else {
                Text(ByteFormat.string(metric.value(insight.total))).font(.callout.monospacedDigit().bold())
                Text(metric.title.lowercased()).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Ranked list doubling as the legend and the exact-numbers table.
    private var legend: some View {
        VStack(spacing: 2) {
            ForEach(slices) { slice in
                Button { if slice.entity.kind == .other { showAll = true } else { onSelect(slice.entity) } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(registry.color(for: slice.entity)).frame(width: 8, height: 8)
                        EntityGlyph(entity: slice.entity)
                        Text(slice.entity.kind == .other ? "\(insight.hiddenCount.formatted()) more…" : slice.entity.label)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(slice.entity.kind == .other ? Color.accentColor : .primary)
                        Spacer(minLength: 4)
                        Text(ByteFormat.string(metric.value(slice.counters))).monospacedDigit().foregroundStyle(.secondary)
                        Text(ShareFormat.string(slice.share))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(hoveredKey == slice.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredKey = $0 ? slice.id : (hoveredKey == slice.id ? nil : hoveredKey) }
                .help(slice.entity.kind == .other
                      ? "Everything outside the top \(InsightsBuilder.maxSlices). Click to see all \(insight.entityCount.formatted())."
                      : "Show only \(slice.entity.label)")
            }
        }
    }

    /// A one-segment donut says nothing; show the fact instead.
    private var singleEntity: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let only = slices.first {
                Text("All traffic").font(.caption).foregroundStyle(.secondary)
                Text(only.entity.label).font(.headline).lineLimit(1)
                Text(ByteFormat.string(metric.value(only.counters))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("No \(metric.title.lowercased()) traffic").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }
}

// MARK: - Trend

struct TrendCard: View {
    var insight: DimensionInsight
    var registry: ColorRegistry
    var metric: InsightMetric
    var granularity: Granularity
    var title: String
    var onSelect: (InsightEntity) -> Void

    @State private var hoverDate: Date?

    var body: some View {
        GroupBox {
            if insight.trends.isEmpty {
                Text("No traffic in this window").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    legend
                    chart
                }
            }
        } label: {
            Text(title)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(insight.trends) { trend in
                Button { if trend.entity.kind != .other { onSelect(trend.entity) } } label: {
                    HStack(spacing: 5) {
                        if trend.entity.kind == .other {
                            HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(InsightPalette.other).frame(width: 3, height: 2) } }
                                .frame(width: 12)
                        } else {
                            RoundedRectangle(cornerRadius: 1).fill(registry.color(for: trend.entity)).frame(width: 12, height: 3)
                        }
                        EntityGlyph(entity: trend.entity)
                        Text(trend.entity.kind == .other ? "Other (\((insight.entityCount - InsightsBuilder.maxTrends).formatted()))" : trend.entity.label)
                            .font(.caption).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(trend.entity.kind == .other ? "Everything outside the top \(InsightsBuilder.maxTrends)" : "Show only \(trend.entity.label)")
            }
            Spacer()
        }
    }

    private var chart: some View {
        Chart {
            ForEach(insight.trends) { trend in
                ForEach(trend.points) { point in
                    LineMark(x: .value("Time", point.date), y: .value(metric.title, metric.value(counters(point))),
                             series: .value("Series", trend.entity.key))
                        .foregroundStyle(registry.color(for: trend.entity))
                        .lineStyle(trend.entity.kind == .other
                                   ? StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
                                   : StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                // Direct label at the end of each line (text in ink, identity carried by the swatch),
                // skipped where it would collide with a higher-ranked label.
                if let last = trend.points.last, labeledKeys.contains(trend.entity.key) {
                    PointMark(x: .value("Time", last.date), y: .value(metric.title, metric.value(counters(last))))
                        .symbolSize(30)
                        .foregroundStyle(registry.color(for: trend.entity))
                        .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                            Text(trend.entity.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                        }
                }
            }
            if let hoverDate {
                RuleMark(x: .value("Time", hoverDate))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(at: hoverDate)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Int64.self) { Text(ByteFormat.string(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartPlotStyle { $0.padding(.trailing, 70) } // room for the direct labels
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { hoverDate = nil; return }
                        hoverDate = nearestBucket(to: date)
                    }
            }
        }
        .frame(height: 190)
    }

    private func tooltip(at date: Date) -> some View {
        let rows = insight.trends.compactMap { trend -> (InsightEntity, Int64)? in
            guard let point = trend.points.first(where: { $0.date == date }), metric.value(counters(point)) > 0 else { return nil }
            return (trend.entity, metric.value(counters(point)))
        }.sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: granularity >= .day ? .abbreviated : .omitted,
                                time: granularity >= .day ? .omitted : (granularity == .second ? .standard : .shortened)))
                .font(.caption.bold())
            if rows.isEmpty { Text("No \(metric.title.lowercased()) traffic").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows, id: \.0.key) { entity, value in
                HStack(spacing: 6) {
                    Circle().fill(registry.color(for: entity)).frame(width: 7, height: 7)
                    Text(entity.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(value)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var yMax: Int64 {
        let peak = insight.trends.flatMap(\.points).map { metric.value(counters($0)) }.max() ?? 0
        return max(1, Int64(Double(peak) * 1.08))
    }

    /// End-of-line labels that stay at least ~12% of the plot height apart, favoring the leaders.
    private var labeledKeys: Set<String> {
        var placed: [Double] = []
        var keys: Set<String> = []
        let height = Double(yMax)
        for trend in insight.trends {
            guard let last = trend.points.last else { continue }
            let y = Double(metric.value(counters(last))) / height
            if placed.allSatisfy({ abs($0 - y) > 0.12 }) {
                placed.append(y)
                keys.insert(trend.entity.key)
            }
        }
        return keys
    }

    private func nearestBucket(to date: Date) -> Date? {
        insight.trends.first?.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
    }

    private func counters(_ p: SeriesPoint) -> FlowCounters { FlowCounters(bytesIn: p.bytesIn, bytesOut: p.bytesOut, flows: 0) }
}

// MARK: - Direction

/// Received vs sent as a split bar with numbers: a two-slice pie would hide the magnitude.
struct DirectionCard: View {
    var total: FlowCounters

    var body: some View {
        GroupBox {
            let sum = Double(max(1, total.total))
            let inShare = Double(total.bytesIn) / sum
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4).fill(TrafficColors.inbound)
                            .frame(width: max(total.bytesIn > 0 ? 4 : 0, (geo.size.width - 2) * inShare))
                        RoundedRectangle(cornerRadius: 4).fill(TrafficColors.outbound)
                    }
                }
                .frame(height: 14)
                row("Received", total.bytesIn, inShare, TrafficColors.inbound)
                row("Sent", total.bytesOut, 1 - inShare, TrafficColors.outbound)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } label: {
            Text("Received vs sent")
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ bytes: Int64, _ share: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
            Text(ShareFormat.string(share)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .font(.caption)
    }
}

enum ShareFormat {
    static func string(_ share: Double) -> String {
        if share > 0 && share < 0.001 { return "<0.1%" }
        return share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }
}

/// Small marker that tells entity kinds apart: app icons, and a building for network owners
/// (traffic whose hostname is unknown, attributed to whoever operates the IP).
struct EntityGlyph: View {
    var entity: InsightEntity

    var body: some View {
        switch entity.kind {
        case .app:
            if let path = entity.iconPath { AppIconView(path: path, size: 14) }
        case .owner:
            Image(systemName: "building.2").font(.caption2).foregroundStyle(.secondary)
                .help("Network owner: no hostname was seen for this traffic")
        case .unknownDestination:
            Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Every entity of a dimension, searchable, for when the top 5 aren't enough.
struct EntityListView: View {
    var insight: DimensionInsight
    var metric: InsightMetric
    var onSelect: (InsightEntity) -> Void
    @State private var query = ""

    private var rows: [InsightSlice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? insight.ranked : insight.ranked.filter { $0.entity.label.localizedCaseInsensitiveContains(q) || $0.entity.key.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All \(insight.dimension.title.lowercased())").font(.headline)
                Text("\(insight.entityCount.formatted())").foregroundStyle(.secondary)
                Spacer()
            }
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder)
            List(rows) { slice in
                Button { onSelect(slice.entity) } label: {
                    HStack(spacing: 6) {
                        EntityGlyph(entity: slice.entity)
                        Text(slice.entity.label).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        ShareBar(fraction: slice.share).frame(width: 90)
                        Text(ByteFormat.string(metric.value(slice.counters))).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show only \(slice.entity.label)")
            }
            .listStyle(.inset)
            .frame(height: 320)
            if insight.entityCount > insight.ranked.count {
                Text("Showing the largest \(insight.ranked.count.formatted()). Filter the report to see the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 420)
    }
}
