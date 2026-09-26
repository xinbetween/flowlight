import SwiftUI

// The shapes the Capture panel is drawn from. They live beside the warnings rather than in Components because
// the warnings are the reason the vocabulary exists: a card for something you can act on, a glyph for the state
// it is in, and a tinted strip for the one thing that is wrong.

extension View {
    /// A card. Everything on Capture sits in one, so nothing on the screen floats.
    func captureCard() -> some View {
        padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The heading above a group of cards: quiet enough to skip past, loud enough to navigate by.
struct CaptureHeading: View {
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }
}

/// The state mark a row is read by — what the eye lands on before any of the words.
struct CaptureGlyph: View {
    var symbol: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Something wrong, or a limit worth knowing, inset inside the card it belongs to. Tinted rather than framed:
/// a border around every caveat turns a panel into a warning label and nothing stands out any more.
struct CaptureNote: View {
    var text: String
    var icon = "exclamationmark.triangle.fill"
    var tint = Color.orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// One fact about a capture source: the claim in a line, the reasoning under it. These are what the explanations
/// collapse into — a paragraph nobody reads becomes a heading somebody can scan.
struct CaptureFact: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Shown when the chosen capture source can't work on this Mac. It always offers the way out, because the only
/// fix is switching source and the explanation alone leaves people stuck.
struct CaptureWarningBanner: View {
    @EnvironmentObject var monitor: TrafficMonitor
    var showSwitch = true

    var body: some View {
        if let warning = monitor.captureWarning {
            HStack(alignment: .top, spacing: 12) {
                CaptureGlyph(symbol: "exclamationmark.triangle.fill", tint: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("The Network Extension can't capture on this Mac"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(warning)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showSwitch, monitor.mode == .networkExtension {
                        Button(L("Use the nettop Sampler")) { monitor.setMode(.nettop) }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.slash").font(.caption).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(enforcing ? "Blocking is on, but not in effect here" : "Blocking needs the Network Extension")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(reason)
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if ExtensionManager.isEntitled, monitor.mode != .networkExtension {
                    Button(L("Use the Network Extension")) { monitor.setMode(.networkExtension) }
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
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
        HStack(alignment: .top, spacing: 12) {
            CaptureGlyph(symbol: "shield.lefthalf.filled", tint: .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(filters.count == 1 ? "Another content filter is active on this Mac"
                                        : "\(filters.count) other content filters are active on this Mac")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filters) { filter in
                        HStack(spacing: 6) {
                            Text(filter.name).font(.caption)
                            Text("·").font(.caption).foregroundStyle(.quaternary)
                            Text(filter.bundleID)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if monitor.mode == .networkExtension {
                    Button(L("Use the nettop Sampler")) { monitor.setMode(.nettop) }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
