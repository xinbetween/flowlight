import SwiftUI

/// Scripts that change a real upstream reply after the origin answered it. They intentionally live beside mocks and
/// outbound rewrites: all three require decrypted HTTP, but their effects are different enough to be visible apart.
struct ResponseTransformRulesSection: View {
    @ObservedObject var inspection: InspectionController
    @State private var editing: ResponseTransformRule?
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Let the request reach its server, then change an eligible JSON or text response before the app receives it."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L("Only complete, fixed-length, uncompressed HTTP/1.1 responses Flowlight decrypts can be changed. Streaming, chunked and compressed replies pass through unchanged."),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !inspection.enabled {
                Label(L("HTTPS inspection is off, so no response can be read or changed yet."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.warning)
            }
            if inspection.responseTransformRules.isEmpty {
                Text(L("No response rules.")).font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inspection.responseTransformRules.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                                var copy = rule; copy.enabled = enabled
                                inspection.responseTransformRules[index] = copy
                            }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.title).lineLimit(1)
                                Text("\(rule.method.isEmpty ? "ANY" : rule.method) \(rule.host)\(rule.path)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .opacity(rule.enabled ? 1 : 0.5)
                            Spacer()
                            Button { editing = rule; isNew = false } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).accessibilityLabel(L("Edit %@", rule.title))
                            Button(role: .destructive) { inspection.responseTransformRules.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless).accessibilityLabel(L("Remove %@", rule.title))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        if index < inspection.responseTransformRules.count - 1 { Divider() }
                    }
                }
                .padding(.vertical, 2).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button(L("Add Rule…")) { editing = ResponseTransformRule(host: "", path: "/*", script: ResponseTransformRule.template(for: .json)); isNew = true }
                Spacer()
                if inspection.activeResponseTransformRules > 0 {
                    Button(L("Turn All Off")) { inspection.responseTransformRules = inspection.responseTransformRules.map { var rule = $0; rule.enabled = false; return rule } }
                }
            }
        }
        .sheet(item: $editing) { rule in
            ResponseTransformRuleEditor(rule: rule, isNew: isNew) { saved in
                if let index = inspection.responseTransformRules.firstIndex(where: { $0.id == saved.id }) {
                    inspection.responseTransformRules[index] = saved
                } else {
                    inspection.responseTransformRules.append(saved)
                }
            }
        }
    }
}

/// The captured context is visible but not copied into the persistent rule: it is an aid for authoring a transform,
/// not an additional route by which retained traffic can escape its inspection budget.
struct ResponseTransformRuleEditor: View {
    @State var rule: ResponseTransformRule
    var isNew: Bool
    var draft: ResponseTransformDraft?
    var save: (ResponseTransformRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("New response transform") : L("Edit response transform")).font(.title3.bold())
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text(L("Name")).gridColumnAlignment(.trailing).foregroundStyle(.secondary); TextField(L("Transform response"), text: $rule.name) }
                GridRow { Text(L("Host")).gridColumnAlignment(.trailing).foregroundStyle(.secondary); TextField(L("api.example.com"), text: $rule.host) }
                GridRow { Text(L("Path")).gridColumnAlignment(.trailing).foregroundStyle(.secondary); TextField(L("/v1/*"), text: $rule.path) }
                GridRow {
                    Text(L("Method")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { rule.method.isEmpty ? "ANY" : rule.method.uppercased() }, set: { rule.method = $0 == "ANY" ? "" : $0 })) {
                        ForEach(ResponseTransformRule.methods, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }
            }
            if let draft {
                GroupBox(L("Captured request context")) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(draft.method) \(draft.url)").font(.caption.monospaced()).textSelection(.enabled)
                        Text(draft.status.map { L("Upstream status: %lld", $0) } ?? L("No captured upstream status."))
                            .font(.caption).foregroundStyle(.secondary)
                        if !draft.requestHeaders.isEmpty {
                            Text(draft.requestHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled).lineLimit(5).foregroundStyle(.secondary)
                        }
                        if let unavailable = draft.unavailableReason {
                            Label(unavailable, systemImage: "info.circle").font(.caption).foregroundStyle(FL.warning)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(L("JavaScript")).font(.caption.bold()).foregroundStyle(.secondary)
            TextEditor(text: $rule.script).font(.caption.monospaced()).frame(height: 250).border(.quaternary)
            Text(L("Define synchronous modifyResponse(args). responseJSON is available for JSON; responseText is available for UTF-8 text. Credential headers are never supplied."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? L("Add Rule") : L("Save")) { save(cleaned()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft?.unavailableReason != nil || rule.host.trimmingCharacters(in: .whitespaces).isEmpty || rule.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 640)
    }

    private func cleaned() -> ResponseTransformRule {
        var copy = rule
        copy.name = copy.name.trimmingCharacters(in: .whitespaces)
        copy.host = copy.host.trimmingCharacters(in: .whitespaces).lowercased()
        copy.path = copy.path.trimmingCharacters(in: .whitespaces)
        if copy.path.isEmpty { copy.path = "*" }
        copy.method = copy.method.trimmingCharacters(in: .whitespaces).uppercased()
        return copy
    }
}
