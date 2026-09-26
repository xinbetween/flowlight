import Charts
import SwiftUI

struct LiveView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var sortOrder = [KeyPathComparator(\LiveTalker.totalRate, order: .reverse)]
    @State private var selection: LiveTalker.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatTile(title: "Download", value: ByteFormat.rate(monitor.currentIn), systemImage: "arrow.down", tint: TrafficColors.inbound)
                StatTile(title: "Upload", value: ByteFormat.rate(monitor.currentOut), systemImage: "arrow.up", tint: TrafficColors.outbound)
                StatTile(title: "Received this session", value: ByteFormat.string(monitor.sessionIn), systemImage: "tray.and.arrow.down", tint: TrafficColors.inbound)
                StatTile(title: "Sent this session", value: ByteFormat.string(monitor.sessionOut), systemImage: "tray.and.arrow.up", tint: TrafficColors.outbound)
            }

            GroupBox {
                Chart(monitor.liveSeries) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Bytes/s", point.bytesIn), series: .value("Direction", "In"))
                        .foregroundStyle(TrafficColors.inbound.opacity(0.35))
                    LineMark(x: .value("Time", point.date), y: .value("Bytes/s", point.bytesIn), series: .value("Direction", "In"))
                        .foregroundStyle(TrafficColors.inbound)
                    AreaMark(x: .value("Time", point.date), y: .value("Bytes/s", -point.bytesOut), series: .value("Direction", "Out"))
                        .foregroundStyle(TrafficColors.outbound.opacity(0.35))
                    LineMark(x: .value("Time", point.date), y: .value("Bytes/s", -point.bytesOut), series: .value("Direction", "Out"))
                        .foregroundStyle(TrafficColors.outbound)
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 0.5))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int64.self) { Text(ByteFormat.rate(Double(abs(v)))) } }
                    }
                }
                .frame(height: 180)
                .padding(.top, 4)
            } label: {
                HStack(spacing: 14) {
                    Text(L("Last 2 minutes"))
                    Spacer()
                    Label(L("Download"), systemImage: "arrow.down").foregroundStyle(TrafficColors.inbound)
                    Label(L("Upload"), systemImage: "arrow.up").foregroundStyle(TrafficColors.outbound)
                }
                .font(.caption)
            }

            GroupBox {
                Table(monitor.talkers.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.name) { t in
                        HStack { AppIconView(path: t.path); Text(t.name) }.help("\(t.bundleID)\nDouble-click to open in Reports")
                    }
                    .width(min: 130)
                    TableColumn("↓ In", value: \.rateIn) { Text("\(ByteFormat.compact($0.rateIn))/s").monospacedDigit().help(ByteFormat.rate($0.rateIn)) }
                        .width(76)
                    TableColumn("↑ Out", value: \.rateOut) { Text("\(ByteFormat.compact($0.rateOut))/s").monospacedDigit().help(ByteFormat.rate($0.rateOut)) }
                        .width(76)
                    TableColumn("Total", value: \.totalRate) { Text("\(ByteFormat.compact($0.totalRate))/s").monospacedDigit().bold().help(ByteFormat.rate($0.totalRate)) }
                        .width(76)
                    TableColumn("Session ↓", value: \.sessionIn) { Text(ByteFormat.string($0.sessionIn)).monospacedDigit() }
                        .width(70)
                    TableColumn("Session ↑", value: \.sessionOut) { Text(ByteFormat.string($0.sessionOut)).monospacedDigit() }
                        .width(70)
                    TableColumn("Busiest destination", value: \.topDestination) { Text($0.topDestination).lineLimit(1).truncationMode(.middle).help($0.topDestination) }
                        .width(min: 150)
                }
                .contextMenu(forSelectionType: LiveTalker.ID.self) { ids in
                    if let id = ids.first {
                        Button(L("Show in Reports")) { openReport(id) }
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

    @ViewBuilder
    private var emptyState: some View {
        if monitor.talkers.isEmpty {
            if monitor.isReceiving {
                ContentUnavailableView("The network is quiet", systemImage: "network",
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
                    Button(L("Open Capture Settings")) { nav.selection = .capture }
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
