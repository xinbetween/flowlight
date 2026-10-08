import SwiftUI

/// Mock responses: the list of rules, and the editor behind it.
///
/// Sits with the rest of the inspection setup because that's what it depends on — a rule can only answer a request
/// Flowlight decrypts, and the section says so rather than leaving someone to work it out.
struct MockRulesSection: View {
    @ObservedObject var inspection: InspectionController
    @State private var editing: MockRule?
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Answer a chosen endpoint yourself instead of letting the request reach the server — a 500, a rate limit, a malformed body, or a long wait — and watch what the agent does about it."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L("Only requests Flowlight decrypts can be mocked. Hosts that are tunnelled — the never-decrypted list, apps that pin their certificates, anything not routed through the proxy — are never touched by a rule."),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !inspection.enabled {
                Label(L("HTTPS inspection is off, so nothing is decrypted and no rule can answer anything yet."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.warning).fixedSize(horizontal: false, vertical: true)
            }

            if inspection.mockRules.isEmpty {
                Text(L("No mock rules.")).font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inspection.mockRules.enumerated()), id: \.element.id) { index, rule in
                        row(rule, index: index)
                        if index < inspection.mockRules.count - 1 { Divider() }
                    }
                }
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                Text(L("Rules are tried from the top; the first enabled one that matches answers."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Add Rule…")) {
                    editing = MockRule(host: "", path: "/*", status: 500, body: #"{"error": "mocked by Flowlight"}"#)
                    isNew = true
                }
                Spacer()
                if inspection.activeMockRules > 0 {
                    Button(L("Turn All Off")) {
                        inspection.mockRules = inspection.mockRules.map { var r = $0; r.enabled = false; return r }
                    }
                }
            }
        }
        .sheet(item: $editing) { rule in
            MockRuleEditor(rule: rule, isNew: isNew) { saved in
                if let at = inspection.mockRules.firstIndex(where: { $0.id == saved.id }) {
                    inspection.mockRules[at] = saved
                } else {
                    inspection.mockRules.append(saved)
                }
            }
        }
    }

    private func row(_ rule: MockRule, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                var copy = rule; copy.enabled = on
                inspection.mockRules[index] = copy
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .accessibilityLabel(L("Enable %@", rule.title))
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.title).font(.callout).lineLimit(1)
                Text(summary(rule)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            Button { editing = rule; isNew = false } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).accessibilityLabel(L("Edit %@", rule.title))
            Button(role: .destructive) {
                inspection.mockRules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).accessibilityLabel(L("Remove %@", rule.title))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func summary(_ rule: MockRule) -> String {
        var parts = ["\(rule.method.isEmpty ? "ANY" : rule.method.uppercased()) \(rule.host)\(rule.path)",
                     "→ \(rule.status) \(MockRule.reason(rule.status))"]
        if rule.delay > 0 { parts.append(L("after %@", DelayFormat.seconds(rule.delay))) }
        return parts.joined(separator: " ")
    }
}

/// One rule, edited in a sheet. Captured request information is reference material only; the matcher remains host,
/// path and method, while the response is the durable mock setting.
struct MockRuleEditor: View {
    private enum Tab: Hashable { case request, response }

    @State var rule: MockRule
    var isNew: Bool
    var save: (MockRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .request
    @State private var requestHeaders: [MockHeaderRow]
    @State private var responseHeaders: [MockHeaderRow]
    @State private var requestBody: MockBodyDraft
    private var responseBodyNote: String?
    @State private var statusText = ""
    @State private var delayText = ""

    init(rule: MockRule, isNew: Bool, draft: MockRuleDraft? = nil, save: @escaping (MockRule) -> Void) {
        _rule = State(initialValue: draft?.rule ?? rule)
        self.isNew = isNew
        self.save = save
        _requestHeaders = State(initialValue: (draft?.requestHeaders ?? []).map(MockHeaderRow.init))
        _responseHeaders = State(initialValue: (draft?.rule.headers ?? rule.headers).map(MockHeaderRow.init))
        _requestBody = State(initialValue: draft?.requestBody ?? MockBodyDraft(text: "", encoding: .text, byteCount: 0,
                                                                                unavailableReason: L("No captured request body.")))
        responseBodyNote = draft?.responseBodyNote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("New mock response") : L("Edit mock response")).font(.title3.bold())

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L("Name")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField(L("Optional, e.g. “GitHub is down”"), text: $rule.name)
                }
            }

            Picker("", selection: $tab) {
                Text(L("Request")).tag(Tab.request)
                Text(L("Response")).tag(Tab.response)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                if tab == .request { requestFields } else { responseFields }
            }
            .frame(maxHeight: 410)

            if rule.delay > 0 {
                Label(L("The request waits %@ before it's answered. Clients with their own timeout will give up first, which is usually the point.",
                        DelayFormat.seconds(rule.delay)),
                      systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? L("Add Rule") : L("Save")) { save(cleaned()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.host.trimmingCharacters(in: .whitespaces).isEmpty || !rule.hasValidBody)
            }
        }
        .padding(20)
        .frame(width: 660)
        .onAppear {
            statusText = String(rule.status)
            delayText = rule.delay == 0 ? "" : String(rule.delay)
        }
    }

    private var requestFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L("Host")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(L("api.example.com"), text: $rule.host)
                        Text(L("Exactly that host. Write *.example.com to cover the domain and its subdomains."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(L("Path")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(L("/v1/*"), text: $rule.path)
                        Text(L("A glob: * matches any run of characters. The query string is ignored unless the pattern contains a ?."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(L("Method")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { rule.method.isEmpty ? "ANY" : rule.method.uppercased() },
                                                  set: { rule.method = $0 == "ANY" ? "" : $0 })) {
                        ForEach(MockRule.methods, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }
            Divider()
            Label(L("Captured request details are reference only. They do not change what this mock matches and are not saved with the rule."),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            MockHeaderRows(rows: $requestHeaders, emptyMessage: L("No captured request headers."))
            BodyEditor(title: L("Request payload"), text: $requestBody.text, encoding: $requestBody.encoding,
                       unavailableReason: requestBody.unavailableReason, editable: false)
        }
    }

    private var responseFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L("Status")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("500", text: $statusText).frame(width: 70)
                            .onChange(of: statusText) { _, new in
                                if let code = Int(new.filter(\.isNumber)), (100...599).contains(code) { rule.status = code }
                            }
                        Text(MockRule.reason(rule.status)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("Delay")).foregroundStyle(.secondary)
                        TextField("0", text: $delayText).frame(width: 60)
                            .onChange(of: delayText) { _, new in rule.delay = min(300, max(0, Double(new) ?? 0)) }
                        Text(L("seconds")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MockHeaderRows(rows: $responseHeaders, emptyMessage: L("No response headers yet."))
            BodyEditor(title: L("Response body"), text: $rule.body, encoding: $rule.bodyEncoding,
                       unavailableReason: responseBodyNote, editable: true)
            if !rule.hasValidBody {
                Label(L("Binary mock bodies must contain complete hexadecimal byte pairs."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.warning)
            }
            Label(L("Saving keeps this response as a mock rule until you remove it, even if captured traffic is later cleared."),
                  systemImage: "archivebox")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Trims what a text field can leave behind, so a rule with a stray space still matches the host someone meant.
    private func cleaned() -> MockRule {
        var copy = rule
        copy.name = copy.name.trimmingCharacters(in: .whitespaces)
        copy.host = copy.host.trimmingCharacters(in: .whitespaces).lowercased()
        copy.path = copy.path.trimmingCharacters(in: .whitespaces)
        if copy.path.isEmpty { copy.path = "*" }
        copy.method = copy.method.trimmingCharacters(in: .whitespaces).uppercased()
        copy.headers = responseHeaders.compactMap { row in
            let name = MockRule.headerSafe(row.name)
            guard !name.isEmpty else { return nil }
            return HTTPHeader(name: name, value: MockRule.headerSafe(row.value))
        }
        return copy
    }
}

private struct MockHeaderRow: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""

    init() {}
    init(_ header: HTTPHeader) { name = header.name; value = header.value }
}

private struct MockHeaderRows: View {
    @Binding var rows: [MockHeaderRow]
    var emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L("Headers")).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { rows.append(MockHeaderRow()) } label: { Label(L("Add Header"), systemImage: "plus") }
                    .controlSize(.small)
            }
            if rows.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.tertiary)
            }
            ForEach($rows) { $row in
                HStack(alignment: .top, spacing: 6) {
                    TextField(L("Name"), text: $row.name).frame(width: 150)
                    AdaptiveMockText(text: $row.value).frame(maxWidth: .infinity)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel(L("Remove header"))
                }
            }
            Text(L("Content-Length, Connection and Transfer-Encoding are written by Flowlight."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BodyEditor: View {
    var title: String
    @Binding var text: String
    @Binding var encoding: MockBodyEncoding
    var unavailableReason: String?
    var editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                if encoding == .hex { Label(L("Binary · hexadecimal"), systemImage: "doc.text") .font(.caption).foregroundStyle(.secondary) }
            }
            if let unavailableReason {
                Label(unavailableReason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                AdaptiveMockText(text: $text, forceMultiline: encoding == .hex)
                    .disabled(!editable)
                if encoding == .hex {
                    Text(L("Each pair of hexadecimal characters is one byte. Flowlight writes the original bytes."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AdaptiveMockText: View {
    @Binding var text: String
    var forceMultiline = false
    private var multiline: Bool { forceMultiline || text.count > 80 || text.contains(where: \.isNewline) }

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text)
                    .font(.caption.monospaced()).frame(minHeight: forceMultiline ? 100 : 54, maxHeight: forceMultiline ? 180 : 100)
                    .border(.quaternary)
            } else {
                TextField("", text: $text).font(.caption.monospaced())
            }
        }
    }
}

enum DelayFormat {
    /// "8 s", "0.5 s" — short enough to sit inside a sentence.
    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? L("%lld s", Int(value)) : L("%@ s", String(format: "%.1f", value))
    }
}
