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

    var body: some View {
        Group {
            if ask.turns.isEmpty { empty } else { transcript }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Ask")
        // Who answers is the one fact worth seeing before the question is typed, not after.
        .navigationSubtitle(ask.sendsOffDevice ? "\(ask.provider.title) · leaves this Mac" : "Answered on this Mac")
        .toolbar { toolbar }
        .sheet(isPresented: $showingSettings) { AskSettingsSheet(ask: ask) }
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

    private var empty: some View {
        ContentUnavailableView {
            Label("Ask about what Flowlight recorded", systemImage: "text.bubble")
        } description: {
            Text("\"What did Claude Code upload yesterday?\" · \"Which app started talking to somewhere new this week?\" "
                 + "· \"Summarise the last hour.\"\n\n"
                 + "The model never gets your history. It gets a list of read-only queries it may call; Flowlight runs "
                 + "them here and hands back totals and names. Every query it ran is listed under the answer, and you "
                 + "can click one to see the rows behind it.")
        } actions: {
            if let reason = ask.blockedReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
                Button("Choose a provider…") { showingSettings = true }
            } else {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { askNow(suggestion) }
                }
            }
        }
    }

    static let suggestions = ["Summarise the last hour",
                              "Which app sent the most yesterday?",
                              "Anything new this week?"]

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(ask.turns) { turn in
                    AskTurnView(turn: turn, thinking: ask.thinking && turn.id == ask.turns.first?.id) { call in
                        guard let filter = call.filter else { return }
                        nav.showReport(filter: filter, end: call.to)
                    }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this Mac's network activity", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { askNow(question) }
                .disabled(ask.thinking || ask.blockedReason != nil)
            if ask.thinking {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask") { askNow(question) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || ask.blockedReason != nil)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) {
            if ask.sendsOffDevice {
                Label("Answers come from \(ask.provider.title). Your question and the query results leave this Mac — and show up in Live like any other app's traffic.",
                      systemImage: "cloud")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(.bar)
                    .offset(y: -22)
            }
        }
    }

    private func askNow(_ text: String) {
        ask.ask(text)
        question = ""
    }
}

private struct AskTurnView: View {
    let turn: AskTurn
    let thinking: Bool
    let open: (AskRecordedCall) -> Void
    @State private var showingSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question).font(.headline)
            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else if turn.answer.isEmpty && thinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(turn.answer).font(.body).textSelection(.enabled)
            }

            if !turn.calls.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What it looked at").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(turn.calls) { call in
                        Button { open(call) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: call.failed ? "exclamationmark.circle" : "magnifyingglass")
                                    .foregroundStyle(call.failed ? Color.orange : .secondary)
                                Text(call.call.sentence).font(.caption.monospaced())
                                Text(call.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(call.filter == nil)
                        .help(call.filter == nil ? call.summary : "Open these rows in Reports")
                    }
                }
            }

            if !turn.sent.isEmpty {
                DisclosureGroup(isExpanded: $showingSent) {
                    ForEach(Array(turn.sent.enumerated()), id: \.offset) { _, body in
                        Text(body)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                } label: {
                    Label("\(turn.sent.count) \(turn.sent.count == 1 ? "request" : "requests") left this Mac · \(turn.provider)",
                          systemImage: "arrow.up.forward.square")
                        .font(.caption)
                }
            } else {
                Text("Answered on this Mac · \(turn.provider)").font(.caption).foregroundStyle(.tertiary)
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
