import SwiftUI

/// Apps whose destinations don't look like the rest of this report, each with the numbers behind the claim and a
/// way straight to the rows. The framing is deliberately "unusual here", not "suspicious": the data supports the
/// first and not the second, and this app is trusted to be careful about the difference.
struct BehaviourPanel: View {
    var findings: [AppBehaviour]
    var period: String
    /// Narrow the report to one app.
    var onSelect: (AppBehaviour) -> Void

    var body: some View {
        if findings.isEmpty {
            ContentUnavailableView {
                Label("Nothing stands out", systemImage: "checkmark.shield")
            } description: {
                Text("No app's destinations look unusual next to the others in \(period). "
                     + "This compares apps with each other, so it says nothing about traffic every app on this Mac shares.")
                .frame(maxWidth: 460)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Compared with the other apps in \(period). Unusual isn't the same as wrong — "
                     + "a backup tool talks to a lot of places for good reasons.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(findings) { finding in
                    Button { onSelect(finding) } label: { row(finding) }
                        .buttonStyle(.plain)
                        .help("Show only \(finding.appName) in this report")
                }
            }
        }
    }

    private func row(_ finding: AppBehaviour) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconView(path: finding.appPath)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.appName).font(.callout.bold())
                    Text(finding.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                ForEach(finding.signals) { signal in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(signal.kind)).font(.caption2).foregroundStyle(.orange)
                            .frame(width: 12)
                        Text(signal.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ \(ByteFormat.string(finding.bytesOut))").font(.caption).monospacedDigit()
                Text("↓ \(ByteFormat.string(finding.bytesIn))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func icon(_ kind: BehaviourSignal.Kind) -> String {
        switch kind {
        case .manyDestinations: return "point.3.connected.trianglepath.dotted"
        case .hostless: return "questionmark.circle"
        case .generatedNames: return "textformat.abc.dottedunderline"
        case .mostlyUploading: return "arrow.up.circle"
        case .sensitiveProtocol: return "exclamationmark.shield"
        }
    }
}
