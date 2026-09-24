import SwiftUI

/// Shown when the chosen capture source can't work on this Mac. It always offers the way out, because the only
/// fix is switching source and the explanation alone leaves people stuck.
struct CaptureWarningBanner: View {
    @EnvironmentObject var monitor: TrafficMonitor
    var showSwitch = true

    var body: some View {
        if let warning = monitor.captureWarning {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text("The Network Extension can't capture on this Mac").font(.callout.bold())
                    Text(warning)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showSwitch, monitor.mode == .networkExtension {
                        Button("Use the nettop sampler") { monitor.setMode(.nettop) }
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}

/// The other content filters installed on this Mac. macOS runs one at a time, so these are the reason Flowlight's
/// own filter may never be asked to do anything — naming them turns a puzzling silence into something actionable.
struct OtherFiltersNotice: View {
    @EnvironmentObject var monitor: TrafficMonitor
    var filters: [InstalledSystemExtension]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Another content filter is active on this Mac", systemImage: "shield.lefthalf.filled")
                .font(.callout.bold())
            VStack(alignment: .leading, spacing: 3) {
                ForEach(filters) { filter in
                    HStack(spacing: 6) {
                        Text(filter.name).font(.callout)
                        Text(filter.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Text("""
            macOS runs one content filter at a time. While \(filters.count == 1 ? "this one is" : "these are") active, \
            Flowlight's filter can install and connect but will never be handed any traffic — the Network Extension \
            source will stay empty. The nettop sampler doesn't use a filter and works alongside \
            \(filters.count == 1 ? "it" : "them").
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if monitor.mode == .networkExtension {
                Button("Use the nettop sampler") { monitor.setMode(.nettop) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
    }
}
