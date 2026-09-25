import Charts
import SwiftUI

/// Ask Flowlight a question about what it has recorded.
///
/// The screen has one job beyond answering: making it obvious what answering cost. Every query the model ran is
/// listed and clickable, so an answer can be checked against the rows behind it, and anything that left the Mac is
/// shown verbatim. A monitor that quietly phoned home to answer questions about phoning home would be worth less
/// than no feature at all.
struct AskView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View {
        AskContent(ask: monitor.ask)
    }
}

private struct AskContent: View {
    @ObservedObject var ask: AskController
    @EnvironmentObject var nav: AppNavigation
    @State private var question = ""
    @State private var showingSettings = false
    @FocusState private var typing: Bool

    /// A comfortable measure for prose. Answers are two or three sentences and the window is often very wide;
    /// text running the full width of a 1700-point window is not readable, it is just long.
    private static let column: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            if ask.turns.isEmpty { empty } else { transcript }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Ask")
        .navigationSubtitle(ask.sendsOffDevice ? "\(ask.provider.title) · leaves this Mac" : "Answered on this Mac")
        .toolbar { toolbar }
        .sheet(isPresented: $showingSettings) { AskSettingsSheet(ask: ask) }
        .onAppear { typing = true }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if !ask.turns.isEmpty {
                Button { ask.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Forget this conversation")
            }
            Button { showingSettings = true } label: {
                Label(ask.provider.title, systemImage: ask.sendsOffDevice ? "cloud" : "desktopcomputer")
            }
            .help(ask.sendsOffDevice
                  ? "Answers are produced by \(ask.provider.title). Your question and the query results leave this Mac."
                  : "Answers are produced on this Mac. Nothing leaves it.")
        }
    }

    // MARK: Nothing asked yet

    private var empty: some View {
        ContentUnavailableView {
            Label("Ask about your traffic", systemImage: "text.bubble")
        } description: {
            Text("Flowlight answers from the history on this Mac. The model never sees it — it can only call a "
                 + "fixed set of queries, and every one it runs is listed under the answer.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The conversation

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(ask.turns) { turn in
                    AskTurnView(turn: turn, thinking: ask.thinking && turn.id == ask.turns.first?.id) { call in
                        guard let filter = call.filter else { return }
                        nav.showReport(filter: filter, end: call.to)
                    } go: { screen in
                        nav.selection = screen
                    }
                    .entrance()
                    if turn.id != ask.turns.last?.id { Divider() }
                }
            }
            .frame(maxWidth: Self.column, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    // MARK: Asking

    private var composer: some View {
        VStack(spacing: 10) {
            // Suggestions sit with the field rather than in the empty state: this is where someone is looking
            // when they don't know what to type, and they survive the first question instead of vanishing.
            if ask.turns.isEmpty && ask.blockedReason == nil {
                // A dozen chips is wider than any window, so they scroll. No scrollbar: it would be the only
                // one on the screen and it draws more attention than the thing it scrolls.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            SuggestionChip(text: suggestion) { askNow(suggestion) }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 30)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Ask about this Mac's network activity", text: $question)
                        .textFieldStyle(.plain)
                        .focused($typing)
                        .onSubmit { askNow(question) }
                        .disabled(ask.thinking || ask.blockedReason != nil)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                if ask.thinking {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Ask") { askNow(question) }
                        .buttonStyle(.borderedProminent)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || ask.blockedReason != nil)
                }
            }

            if let reason = ask.blockedReason {
                HStack(spacing: 6) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Choose a provider…") { showingSettings = true }
                        .buttonStyle(.link).font(.caption)
                    Spacer(minLength: 0)
                }
            } else if ask.sendsOffDevice {
                // Said before the question is asked, not after it has gone.
                Label("Your question and the query results go to \(ask.provider.title). Every request is shown under the answer.",
                      systemImage: "cloud")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: Self.column)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Two kinds of question, because the panel now answers two kinds: what happened, and how the app works.
    /// Shown as chips beside the field, which is where someone looks when they don't know what to type.
    static let suggestions = [
        "Summarise the last hour",
        "Which app sent the most yesterday?",
        "Chart my traffic over the last day",
        "Anything new this week?",
        "Which agents have been busy?",
        "What did my AI agents reach besides their providers?",
        "Any alerts worth my attention?",
        "How do I turn on HTTPS inspection?",
        "How do I block an app from reaching a domain?",
        "Why am I not seeing any traffic?",
        "What is Flowlight set up to do right now?",
        "How do I stop an agent using its shell tool?",
    ]

    private func askNow(_ text: String) {
        ask.ask(text)
        question = ""
        typing = true
    }
}

private struct AskTurnView: View {
    let turn: AskTurn
    let thinking: Bool
    let open: (AskRecordedCall) -> Void
    let go: (SidebarItem) -> Void
    @State private var showingSent = false
    @State private var showingCalls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.question)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if turn.answer.isEmpty && thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                }
            } else {
                Text(turn.answer)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // At most one chart per answer. Several would turn a two-sentence reply into a dashboard, and the
            // question asked for an answer.
            if let charted = turn.calls.first(where: { $0.chart != nil }), let chart = charted.chart {
                AskChartView(chart: chart).entrance()
            }
            if let screen = turn.calls.compactMap(\.screen).first {
                // An answer about the app should end somewhere you can act on it — but the app moves when you
                // click, not when the model decides to.
                Button("Open \(screen.title)") { go(screen) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if !turn.calls.isEmpty { evidence }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.appear, value: turn.answer)
        .motion(Motion.appear, value: turn.calls.count)
    }

    /// The queries behind the answer, in a panel of their own.
    ///
    /// They used to be loose rows of monospace under the prose, which read as more answer. They are not the
    /// answer — they are what it rests on — so they get a container that says so, and a chevron on the ones that
    /// can take you to the rows themselves.
    private var evidence: some View {
        DisclosureGroup(isExpanded: $showingCalls) {
            queryRows.padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(evidenceSummary)
                if turn.calls.contains(where: \.failed) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One line rather than a list, because what the model looked at is reassurance, not the answer. It is there
    /// to be opened when someone doubts the number — and folded away the rest of the time.
    private var evidenceSummary: String {
        let n = turn.calls.count
        let names = Set(turn.calls.map(\.call.query.rawValue)).sorted().joined(separator: ", ")
        return "\(n) quer\(n == 1 ? "y" : "ies") · \(names)"
    }

    private var queryRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(turn.calls.enumerated()), id: \.element.id) { index, call in
                Button { open(call) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: call.failed ? "exclamationmark.circle" : "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(call.failed ? Color.orange : .secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.call.sentence).font(.caption.monospaced())
                            Text(call.summary)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if call.filter != nil {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(call.filter == nil)
                .help(call.filter == nil ? call.summary : "Open these rows in Reports")
                if index < turn.calls.count - 1 { Divider() }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.6)))
    }

    @ViewBuilder
    private var footer: some View {
        if turn.sent.isEmpty {
            Label("Answered on this Mac · \(turn.provider)", systemImage: "lock")
                .font(.caption).foregroundStyle(.tertiary)
        } else {
            DisclosureGroup(isExpanded: $showingSent) {
                VStack(spacing: 6) {
                    ForEach(Array(turn.sent.enumerated()), id: \.offset) { _, body in
                        ScrollView(.horizontal) {
                            Text(body).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxHeight: 220)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("\(turn.sent.count) \(turn.sent.count == 1 ? "request" : "requests") left this Mac · \(turn.provider)",
                      systemImage: "arrow.up.forward.square")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Choosing who answers, and what that means.
private struct AskSettingsSheet: View {
    @ObservedObject var ask: AskController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Who answers").font(.headline)
            Text("The two that send nothing come first. That isn't an accident: a tool whose promise is no account "
                 + "and no cloud shouldn't need either to answer a question about itself.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4).padding(.bottom, 12)

            Form {
                Picker("Provider", selection: Binding(get: { ask.provider }, set: { ask.provider = $0; key = ask.apiKey })) {
                    ForEach(AskProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if let reason = OnDeviceAsk.readiness.explanation, ask.provider == .onDevice {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                if ask.provider != .onDevice {
                    TextField("Endpoint", text: Binding(get: { ask.endpoint }, set: { ask.endpoint = $0 }))
                    TextField("Model", text: Binding(get: { ask.model }, set: { ask.model = $0 }))
                }
                if ask.provider.needsKey {
                    SecureField("API key", text: $key)
                        .onSubmit { ask.apiKey = key }
                    Text("Kept in your login Keychain, not in Flowlight's preferences — a plist is readable by "
                         + "anything running as you, which is the sort of thing this app exists to point at.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Label(ask.sendsOffDevice
                          ? "Your question and the results of the queries it runs will be sent to \(ask.provider.title). Your history is not sent, and every request is shown in full under the answer."
                          : "Nothing leaves this Mac. The question, the queries and the answer all stay here.",
                          systemImage: ask.sendsOffDevice ? "cloud" : "lock")
                        .font(.caption)
                        .foregroundStyle(ask.sendsOffDevice ? .orange : .secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { ask.apiKey = key; dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { key = ask.apiKey }
    }
}

/// A chart under an answer.
///
/// Drawn from the same rows the query returned, so the picture and the sentence cannot disagree. Deliberately
/// plain: no legend where one series needs no naming, no gridlines fighting the bars, and bytes formatted as
/// bytes rather than as a number with six zeroes on it.
private struct AskChartView: View {
    let chart: AskChart

    private func format(_ value: Double) -> String {
        chart.unit == .bytes ? ByteFormat.string(Int64(value)) : Int(value).formatted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chart.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
                .frame(height: chart.kind == .pie ? 180 : 160)
                .padding(.trailing, 4)
                .motion(Motion.value, value: chart.points.count)
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.6)))
    }

    @ViewBuilder
    private var content: some View {
        switch chart.kind {
        case .line: line
        case .bar: bar
        case .pie: pie
        case .none: EmptyView()
        }
    }

    private var line: some View {
        Chart {
            ForEach(chart.points) { point in
                if let date = point.date {
                    AreaMark(x: .value("Time", date), y: .value(chart.primaryName, point.value),
                             series: .value("Direction", chart.primaryName))
                        .foregroundStyle(TrafficColors.outbound.opacity(0.25))
                    LineMark(x: .value("Time", date), y: .value(chart.primaryName, point.value),
                             series: .value("Direction", chart.primaryName))
                        .foregroundStyle(TrafficColors.outbound)
                    if let received = point.secondary {
                        LineMark(x: .value("Time", date), y: .value(chart.secondaryName, received),
                                 series: .value("Direction", chart.secondaryName))
                            .foregroundStyle(TrafficColors.inbound)
                    }
                }
            }
        }
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let bytes = value.as(Double.self) { Text(format(bytes)) } }
        } }
        .chartLegend(.hidden)
    }

    private var bar: some View {
        Chart(chart.points) { point in
            BarMark(x: .value("Amount", point.value + (point.secondary ?? 0)),
                    y: .value("Name", point.label))
                .foregroundStyle(TrafficColors.outbound)
                .cornerRadius(3)
        }
        .chartXAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let bytes = value.as(Double.self) { Text(format(bytes)) } }
        } }
        .chartYAxis { AxisMarks(preset: .aligned, position: .leading) }
    }

    private var pie: some View {
        Chart(chart.points) { point in
            SectorMark(angle: .value("Amount", point.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                .foregroundStyle(by: .value("Name", point.label))
                .cornerRadius(3)
        }
        .chartLegend(position: .trailing, alignment: .center)
    }
}

/// A suggested question. It answers the pointer, because a thing you can click should look like one before you
/// click it — and it scales rather than resizing, so the chips beside it never shuffle along.
private struct SuggestionChip: View {
    let text: String
    let ask: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(text, action: ask)
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.quaternary.opacity(hovering ? 0.85 : 0.5), in: Capsule())
            .scaleEffect(hovering ? 1.03 : 1)
            .onHover { hovering = $0 }
            .motion(Motion.control, value: hovering)
            .help("Ask this")
    }
}
