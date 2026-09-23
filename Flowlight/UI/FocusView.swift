import SwiftUI

/// The Focus control in the sidebar footer: what's being watched, and a switch.
struct FocusBar: View {
    @EnvironmentObject var focus: FocusStore
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: focus.isActive ? "scope" : "circle.dashed")
                    .foregroundStyle(focus.isActive ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.isActive ? "Focus on" : "Focus off").font(.caption.bold())
                    Text(focus.isActive ? focus.summary : "Pick what to watch")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .help(focus.isActive ? "Showing only \(focus.summary) — click to change" : "Show only the apps and destinations you choose")
        .accessibilityLabel(focus.isActive ? "Focus on: \(focus.summary)" : "Focus off")
        .popover(isPresented: $editing, arrowEdge: .trailing) { FocusEditor() }
    }
}

/// Picks what Focus watches. Apps come from what's actually been talking; destinations are typed.
struct FocusEditor: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var focus: FocusStore
    @State private var typed = ""
    @State private var candidates: [FocusTarget] = []
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Focus", isOn: $focus.isOn)
                    .toggleStyle(.switch)
                    .disabled(focus.targets.isEmpty)
                Spacer()
                if !focus.targets.isEmpty {
                    Button("Clear") { focus.clear() }.buttonStyle(.link)
                }
            }
            Text("While Focus is on, every screen shows only what's listed here. Nothing stops being recorded — turn Focus off and the rest is still there.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if focus.targets.isEmpty {
                Text("Nothing chosen yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowChips(targets: focus.targets) { focus.remove($0) }
            }

            Divider()

            Text("Add a destination").font(.caption.bold())
            HStack {
                TextField("api.example.com", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                Text("Enter a hostname, a domain or an IP address. Ranges like 10.0.0.0/8 aren't supported here.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if !candidates.isEmpty {
                Text("Recently active apps").font(.caption.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates) { target in
                            Toggle(isOn: Binding(get: { focus.contains(target) },
                                                 set: { _ in focus.toggle(target) })) {
                                Text(target.label).lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(16)
        .frame(width: 330)
        .task { await loadCandidates() }
    }

    private func addTyped() {
        guard let target = FocusTarget.host(typed) else { invalid = true; return }
        focus.add(target)
        typed = ""
        invalid = false
    }

    /// The apps worth offering are the ones that have sent or received something lately.
    private func loadCandidates() async {
        let from = Date().addingTimeInterval(-24 * 3600), to = Date()
        let rows = (try? await monitor.read { try $0.breakdown(.hour, from: from, to: to) }) ?? []
        var seen: [String: (name: String, bytes: Int64)] = [:]
        for row in rows where !row.bundleID.isEmpty {
            let name = row.appName.isEmpty ? row.bundleID : row.appName
            seen[row.bundleID, default: (name, 0)].bytes += row.counters.total
        }
        candidates = seen.sorted { $0.value.bytes > $1.value.bytes }
            .prefix(40)
            .compactMap { FocusTarget.app($0.key, name: $0.value.name) }
    }
}

/// Removable chips that wrap onto as many rows as they need.
private struct FlowChips: View {
    var targets: [FocusTarget]
    var remove: (FocusTarget) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(targets) { target in
                HStack(spacing: 4) {
                    Image(systemName: target.kind == .app ? "app.badge" : "globe").font(.caption2)
                    Text(target.label).font(.caption).lineLimit(1)
                    Button { remove(target) } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(target.label) from Focus")
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Left-to-right wrapping for a row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// "Focus on this app" / "Focus on this destination", for the row menus in Live, Reports and AI Agents.
struct FocusMenuItems: View {
    @EnvironmentObject var focus: FocusStore
    var app: (bundleID: String, name: String)?
    var host: String?

    var body: some View {
        if let app, let target = FocusTarget.app(app.bundleID, name: app.name) {
            Button(focus.contains(target) ? "Remove \(target.label) from Focus" : "Focus on \(target.label)") {
                focus.toggle(target)
            }
        }
        if let host, let target = FocusTarget.host(host) {
            Button(focus.contains(target) ? "Remove \(target.label) from Focus" : "Focus on \(target.label)") {
                focus.toggle(target)
            }
        }
    }
}
