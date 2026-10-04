import SwiftUI

/// Modify requests: rules that edit an outgoing request's headers or body (JSON or form) before it's forwarded. Sits with the
/// rest of inspection setup — a rule can only change a request Flowlight decrypts.
struct RewriteRulesSection: View {
    @ObservedObject var inspection: InspectionController
    @State private var editing: RewriteRule?
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Change a request on its way out — add or replace a header, pin a field in the JSON or form body, or strip one — and let it continue to the server. Like a mock, but it edits the request instead of answering it."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L("Only requests Flowlight decrypts can be rewritten, and only buffered ones — bodies up to a few megabytes. Tunnelled, pinned, chunked or streamed uploads pass through untouched."),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !inspection.enabled {
                Label(L("HTTPS inspection is off, so nothing is decrypted and no rule can change anything yet."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.warning).fixedSize(horizontal: false, vertical: true)
            }

            if inspection.rewriteRules.isEmpty {
                Text(L("No request rules.")).font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inspection.rewriteRules.enumerated()), id: \.element.id) { index, rule in
                        row(rule, index: index)
                        if index < inspection.rewriteRules.count - 1 { Divider() }
                    }
                }
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                Text(L("Every matching rule is applied, in order."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Add Rule…")) {
                    editing = RewriteRule(host: "", path: "/*")
                    isNew = true
                }
                Spacer()
                if inspection.activeRewriteRules > 0 {
                    Button(L("Turn All Off")) {
                        inspection.rewriteRules = inspection.rewriteRules.map { var r = $0; r.enabled = false; return r }
                    }
                }
            }
        }
        .sheet(item: $editing) { rule in
            RewriteRuleEditor(rule: rule, isNew: isNew) { saved in
                if let at = inspection.rewriteRules.firstIndex(where: { $0.id == saved.id }) {
                    inspection.rewriteRules[at] = saved
                } else {
                    inspection.rewriteRules.append(saved)
                }
            }
        }
    }

    private func row(_ rule: RewriteRule, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                var copy = rule; copy.enabled = on
                inspection.rewriteRules[index] = copy
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
                inspection.rewriteRules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).accessibilityLabel(L("Remove %@", rule.title))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func summary(_ rule: RewriteRule) -> String {
        let scope = "\(rule.method.isEmpty ? "ANY" : rule.method.uppercased()) \(rule.host)\(rule.path)"
        let edits = rule.headers.count + rule.body.count
        return "\(scope) · \(L("%lld edit(s)", edits))"
    }
}

/// One rewrite rule, edited in a sheet: where it matches, and the header and body edits it makes.
struct RewriteRuleEditor: View {
    @State var rule: RewriteRule
    var isNew: Bool
    var save: (RewriteRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("New request rule") : L("Edit request rule")).font(.title3.bold())

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L("Name")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField(L("Optional, e.g. “Force temperature”"), text: $rule.name)
                }
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
                    TextField(L("/v1/*"), text: $rule.path)
                }
                GridRow {
                    Text(L("Method")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { rule.method.isEmpty ? "ANY" : rule.method.uppercased() },
                                                  set: { rule.method = $0 == "ANY" ? "" : $0 })) {
                        ForEach(RewriteRule.methods, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }

            Divider()

            // Header edits
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Headers")).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach($rule.headers) { $edit in
                    HStack(spacing: 6) {
                        Picker("", selection: $edit.op) {
                            Text(L("Set")).tag(HeaderEdit.Op.set)
                            Text(L("Add")).tag(HeaderEdit.Op.add)
                            Text(L("Remove")).tag(HeaderEdit.Op.remove)
                        }.labelsHidden().frame(width: 92)
                        TextField(L("Header name"), text: $edit.name).frame(width: 150)
                        TextField(L("Value"), text: $edit.value).disabled(edit.op == .remove)
                            .opacity(edit.op == .remove ? 0.4 : 1)
                        Button(role: .destructive) { rule.headers.removeAll { $0.id == edit.id } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
                Button(L("Add header edit")) { rule.headers.append(HeaderEdit()) }.controlSize(.small)
            }

            // Body edits
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Request body")).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach($rule.body) { $edit in
                    HStack(spacing: 6) {
                        Picker("", selection: $edit.op) {
                            Text(L("Set")).tag(BodyEdit.Op.set)
                            Text(L("Remove")).tag(BodyEdit.Op.remove)
                        }.labelsHidden().frame(width: 92)
                        TextField(L("key.path"), text: $edit.path).font(.caption.monospaced()).frame(width: 150)
                        TextField(L("value (JSON or text)"), text: $edit.value).font(.caption.monospaced())
                            .disabled(edit.op == .remove).opacity(edit.op == .remove ? 0.4 : 1)
                        Button(role: .destructive) { rule.body.removeAll { $0.id == edit.id } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
                Button(L("Add body edit")) { rule.body.append(BodyEdit()) }.controlSize(.small)
                Text(L("For a JSON body, a dotted path into the object (metadata.user); a value that is valid JSON (0.7, true, {\"a\":1}) is used as-is, anything else is a string. For a form body (application/x-www-form-urlencoded), the field name, taken whole, set to the text as typed. Only requests with one of those two bodies are changed."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? L("Add Rule") : L("Save")) { save(cleaned()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func cleaned() -> RewriteRule {
        var copy = rule
        copy.name = copy.name.trimmingCharacters(in: .whitespaces)
        copy.host = copy.host.trimmingCharacters(in: .whitespaces).lowercased()
        copy.path = copy.path.trimmingCharacters(in: .whitespaces)
        if copy.path.isEmpty { copy.path = "*" }
        copy.method = copy.method.trimmingCharacters(in: .whitespaces).uppercased()
        // Drop blank edits a half-filled row would leave behind.
        copy.headers = copy.headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        copy.body = copy.body.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty }
        return copy
    }
}
