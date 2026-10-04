import SwiftUI

struct LocalRiskSettingsSection: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @Binding var showClearConfirmation: Bool

    private var enabled: Binding<Bool> {
        // This reflects active analysis, not a saved preference that cannot work on this Mac. The control is then
        // unmistakably off and disabled until Apple Intelligence becomes ready.
        Binding(get: { LocalRiskSettings.enabled }, set: { monitor.setLocalRiskEnabled($0) })
    }

    var body: some View {
        Section(L("Local risk analysis")) {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Analyze potential harm after capture"))
                    Text(L("Uses Apple's on-device model only after an inspected request is recorded. It never blocks, changes, or sends traffic off this Mac."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!LocalRiskSettings.canAnalyze)

            if let explanation = LocalRiskSettings.readiness.explanation {
                Label(explanation, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("Deterministic capture provenance remains available, but contextual local-model assessment needs the on-device model."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Only meaningful decrypted HTTP request candidates with independent evidence are assessed. Requests marked Not assessed are not being called safe."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if LocalRiskSettings.enabled {
                Button(L("Analyze recent inspected requests")) { monitor.analyzeRecentInspectedRequests() }
                    .help(L("Queues at most 100 recent eligible requests; captured traffic stays available immediately."))
            }
            Button(L("Clear analyses…"), role: .destructive) { showClearConfirmation = true }
                .help(L("Delete only retained local risk scores and explanations"))
        }
    }
}
