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

/// Stands in for the "block connections" switch when the chosen capture source can't refuse anything. Offering
/// the switch and then not blocking would be a promise Flowlight can't keep, so the reason takes its place.
struct BlockingUnavailableNotice: View {
    @EnvironmentObject var monitor: TrafficMonitor
    /// True when this agent's allowlist is set to block: the rule is saved, it just can't act here.
    var enforcing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(enforcing ? "Blocking is on, but not in effect here" : "Blocking needs the Network Extension",
                  systemImage: "shield.slash")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(reason)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if ExtensionManager.isEntitled, monitor.mode != .networkExtension {
                Button("Use the Network Extension") { monitor.setMode(.networkExtension) }
                    .controlSize(.mini)
            }
        }
    }

    private var reason: String {
        if !ExtensionManager.isEntitled {
            return "This build isn't signed for the Network Extension, so nothing sits in the path of a connection "
                + "to refuse it. Allowlists still raise alerts."
        }
        if monitor.mode != .networkExtension {
            return "The nettop sampler counts traffic after it has left the Mac — it can't refuse a connection. "
                + "Allowlists still raise alerts."
        }
        return "macOS isn't letting Flowlight's filter run, so it can't refuse anything. Allowlists still raise alerts."
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
