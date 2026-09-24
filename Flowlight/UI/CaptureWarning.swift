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
