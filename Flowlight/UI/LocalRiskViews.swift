import SwiftUI

struct RiskBadge: View {
    var assessment: RiskAssessment?

    var body: some View {
        if let assessment, assessment.state == .scored, let severity = assessment.severity {
            Label(severity.title, systemImage: severity.symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2.bold())
                .foregroundStyle(color(for: severity))
                .help(assessment.summary ?? severity.title)
        } else if assessment != nil {
            Text(L("Not assessed"))
                .font(.caption2).foregroundStyle(.secondary)
                .help(L("No contextual local-model verdict was produced. This does not mean the request is safe."))
        } else {
            Text(L("Not assessed"))
                .font(.caption2).foregroundStyle(.tertiary)
                .help(L("No contextual local-model verdict was produced. This does not mean the request is safe."))
        }
    }

    private func color(for severity: RiskSeverity) -> Color {
        switch severity {
        case .none: return .secondary
        case .low: return FL.warning
        case .medium: return .orange
        case .high: return FL.critical
        }
    }
}

struct PotentialHarmCard: View {
    var assessment: RiskAssessment?

    var body: some View {
        GroupBox(L("Potential harm")) {
            if let assessment, assessment.state == .scored, let severity = assessment.severity {
                VStack(alignment: .leading, spacing: 6) {
                    Label(severity.title, systemImage: severity.symbol)
                        .font(.callout.bold())
                        .foregroundStyle(color(for: severity))
                    if let confidence = assessment.confidence {
                        Text(L("Confidence: %@", confidence.formatted(.percent.precision(.fractionLength(0)))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = assessment.summary, !summary.isEmpty {
                        Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(assessment.evidence.filter { assessment.modelEvidenceIDs.isEmpty || assessment.modelEvidenceIDs.contains($0.id) }) { evidence in
                        Label(evidence.detail, systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    advisory
                }
            } else if assessment != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Not assessed")).font(.callout.bold())
                    Text(L("No contextual local-model verdict was produced for this request. That is not a statement that it is safe."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    advisory
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Not assessed")).font(.callout.bold())
                    Text(L("This request did not produce a local assessment. That is not a statement that it is safe."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    advisory
                }
            }
        }
    }

    private var advisory: some View {
        Text(L("Analysis is local and advisory; this request was not blocked or changed."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func color(for severity: RiskSeverity) -> Color {
        switch severity {
        case .none: return .secondary
        case .low: return FL.warning
        case .medium: return .orange
        case .high: return FL.critical
        }
    }
}
