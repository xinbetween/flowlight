import SwiftUI

/// "Show me what this rule would have done" — the answer, in the sheet where the rule is being written.
///
/// It runs against recorded traffic, so it reports what *did* happen rather than what might. That makes the
/// number trustworthy and also bounds it: a rule tested against a fortnight of history has been tested against a
/// fortnight of history, and the screen says so rather than implying it has seen everything.
struct RuleSimulationView: View {
    let rule: Rule
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var result: RuleSimulation.Result?
    @State private var running = false
    /// How far back to replay. A fortnight is the minute tier's retention, so it is the honest maximum.
    @State private var days = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker(L("Test against"), selection: $days) {
                    Text(L("The last day")).tag(1)
                    Text(L("The last 3 days")).tag(3)
                    Text(L("The last week")).tag(7)
                    Text(L("The last 2 weeks")).tag(14)
                }
                .frame(maxWidth: 220)
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let result {
                summary(result)
                if !result.changes.isEmpty { list(result) }
            } else if !running {
                Text(L("Nothing simulated yet."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: SimKey(rule: rule, days: days)) {
            // A keystroke at a time would re-run this on every letter of a hostname.
            try? await Task.sleep(for: .milliseconds(400))
            await run()
        }
    }

    private struct SimKey: Equatable { var rule: Rule; var days: Int }

    @ViewBuilder private func summary(_ result: RuleSimulation.Result) -> some View {
        if !rule.isComplete {
            Label(L("Name an app or a destination first."), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if result.isEmpty {
            // Two very different facts wear the same empty list, and the difference decides whether the rule is
            // safe or simply untested.
            Label(result.connectionsConsidered == 0
                  ? L("No recorded traffic in this period to test against.")
                  : L("Would have changed nothing. %lld connections in this period, none of them affected.",
                      result.connectionsConsidered),
                  systemImage: result.connectionsConsidered == 0 ? "questionmark.circle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(result.connectionsConsidered == 0 ? Color.secondary : Color.green)
        } else if !result.refusals.isEmpty {
            Label(L("Would have refused %lld of %lld connections, from %lld apps, %@ in all.",
                    result.connectionsRefused, result.connectionsConsidered, result.appsAffected,
                    ByteFormat.string(result.bytesRefused)),
                  systemImage: "hand.raised.fill")
                .font(.callout)
        } else {
            Label(L("Would have allowed %lld connections that are refused today.", result.permits.reduce(0) { $0 + $1.connections }),
                  systemImage: "checkmark.shield")
                .font(.callout).foregroundStyle(.green)
        }
    }

    private func list(_ result: RuleSimulation.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(result.changes.prefix(12)) { change in
                HStack(spacing: 8) {
                    Image(systemName: change.refused ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(change.refused ? .orange : .green)
                        .imageScale(.small)
                    Text(change.appName).frame(minWidth: 120, alignment: .leading)
                    Text(change.destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("%lld×", change.connections)).font(.caption).foregroundStyle(.secondary)
                    Text(ByteFormat.string(change.bytes)).font(.caption).foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                }
                .padding(.vertical, 3)
                Divider()
            }
            if result.changes.count > 12 {
                Text(L("and %lld more", result.changes.count - 12))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            if let earliest = result.earliest {
                Text(L("Tested against traffic back to %@.", earliest.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .frame(maxHeight: 260)
    }

    private func run() async {
        guard rule.isComplete else { result = RuleSimulation.Result(); return }
        running = true
        defer { running = false }
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let existing = monitor.rules.rules
        let candidate = rule
        let flows = (try? await monitor.read { try $0.flowsForSimulation(since: since) }) ?? []
        result = RuleSimulation.run(candidate: candidate, existing: existing, flows: flows)
    }
}
