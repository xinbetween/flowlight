import AppKit
import SwiftUI

/// A request or response body: a collapsible tree for JSON and event streams, or raw text.
struct BodyView: View {
    let data: Data
    var truncated = false
    @State private var content: BodyContent = .empty
    @AppStorage("inspect.bodyMode") private var mode = "tree"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isStructured {
                    Picker("View", selection: $mode) {
                        Text("Tree").tag("tree")
                        Text("Raw").tag("raw")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120).controlSize(.small)
                }
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .controlSize(.small)
                    .help("Copy the body (pretty-printed when it's JSON)")
            }
            switch content {
            case .json(let value) where mode == "tree":
                LazyVStack(alignment: .leading, spacing: 0) {
                    JSONNodeView(key: nil, value: value, depth: 0)
                }
            case .events(let events) where mode == "tree":
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                        JSONNodeView(key: "\(index + 1)" + (event.event.map { " · \($0)" } ?? ""), value: event.value, depth: 1,
                                     keyStyle: .event)
                    }
                }
            case .binary(let count):
                Text("\(count) bytes of binary data").font(.caption).foregroundStyle(.secondary)
            case .empty:
                EmptyView()
            default:
                Text(rawText).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if truncated {
                Label("Only the first 2 MB were kept.", systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: data) {
            let data = data
            content = await Task.detached(priority: .userInitiated) { BodyContent.classify(data) }.value
        }
    }

    private var isStructured: Bool {
        switch content { case .json, .events: return true; default: return false }
    }

    private var summary: String {
        switch content {
        case .json(let v): return v.isContainer ? "JSON · \(v.count) \(v.count == 1 ? "item" : "items") · \(ByteFormat.string(Int64(data.count)))" : "JSON"
        case .events(let e): return "Event stream · \(e.count) events · \(ByteFormat.string(Int64(data.count)))"
        case .text: return "Text · \(ByteFormat.string(Int64(data.count)))"
        case .binary: return "Binary"
        case .empty: return "No body"
        }
    }

    private var rawText: String {
        let limit = 300_000
        let text: String
        switch content {
        case .json(let v): text = v.pretty()
        case .events(let events): text = events.map { ($0.event.map { "event: \($0)\n" } ?? "") + $0.value.pretty() }.joined(separator: "\n\n")
        case .text(let t): text = t
        default: text = ""
        }
        return text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)" : text
    }

    private func copy() {
        let text: String
        switch content {
        case .json(let v): text = v.pretty()
        case .events: text = rawText
        default: text = String(decoding: data, as: UTF8.self)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One node of a JSON tree. Containers expand on click; the first two levels start open.
struct JSONNodeView: View {
    enum KeyStyle { case key, index, event }

    let key: String?
    let value: JSONValue
    let depth: Int
    var keyStyle: KeyStyle = .key
    @State private var expanded: Bool
    @State private var shown = 200
    @State private var fullString = false

    init(key: String?, value: JSONValue, depth: Int, keyStyle: KeyStyle = .key) {
        self.key = key
        self.value = value
        self.depth = depth
        self.keyStyle = keyStyle
        _expanded = State(initialValue: depth < 2 && value.count <= 50 && keyStyle != .event)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded, value.isContainer {
                let children = childList
                ForEach(children.prefix(shown), id: \.offset) { child in
                    JSONNodeView(key: child.key, value: child.value, depth: depth + 1,
                                 keyStyle: isArray ? .index : .key)
                }
                if children.count > shown {
                    Button("Show \(min(200, children.count - shown)) more of \(children.count - shown)") { shown += 200 }
                        .buttonStyle(.link).font(.caption)
                        .padding(.leading, CGFloat(depth + 1) * 14 + 16)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private var isArray: Bool { if case .array = value { return true } else { return false } }

    private var childList: [(offset: Int, key: String, value: JSONValue)] {
        switch value {
        case .object(let pairs): return pairs.enumerated().map { ($0.offset, $0.element.key, $0.element.value) }
        case .array(let items): return items.enumerated().map { ($0.offset, "\($0.offset)", $0.element) }
        default: return []
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Group {
                if value.isContainer {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            if let key {
                (Text(keyStyle == .key ? key : keyStyle == .index ? "[\(key)]" : key)
                    .foregroundStyle(keyStyle == .key ? Color.accentColor : .secondary)
                    .fontWeight(keyStyle == .event ? .semibold : .regular)
                 + Text(":").foregroundStyle(.tertiary))
            }
            valueText
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if value.isContainer { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } }
            else if case .string = value { fullString.toggle() }
        }
        .contextMenu {
            Button("Copy Value") { copy(value.isContainer ? value.pretty() : plain) }
            if let key { Button("Copy Key") { copy(key) } }
        }
    }

    @ViewBuilder private var valueText: some View {
        switch value {
        case .object, .array:
            Text(expanded ? bracketCount : preview).foregroundStyle(.secondary).lineLimit(1)
        case .string(let s):
            Text(JSONValue.quote(s)).foregroundStyle(Color(nsColor: .systemGreen))
                .lineLimit(fullString ? nil : 4).textSelection(.enabled)
                .help(s.count > 300 && !fullString ? "Click to show the whole string" : "")
        case .number(let n):
            Text(n).foregroundStyle(Color(nsColor: .systemBlue)).textSelection(.enabled)
        case .bool(let b):
            Text(b ? "true" : "false").foregroundStyle(Color(nsColor: .systemPurple))
        case .null:
            Text("null").foregroundStyle(.tertiary)
        }
    }

    private var plain: String {
        if case .string(let s) = value { return s }
        return value.pretty()
    }

    private var bracketCount: String {
        isArray ? "[\(value.count)]" : "{\(value.count)}"
    }

    /// A one-line preview of a collapsed container: its first few keys and short values.
    private var preview: String {
        switch value {
        case .object(let pairs):
            let parts = pairs.prefix(4).map { pair -> String in
                switch pair.value {
                case .string(let s): return "\(pair.key): \(JSONValue.quote(String(s.prefix(40))))"
                case .number(let n): return "\(pair.key): \(n)"
                case .bool(let b): return "\(pair.key): \(b)"
                case .null: return "\(pair.key): null"
                case .array(let a): return "\(pair.key): [\(a.count)]"
                case .object(let o): return "\(pair.key): {\(o.count)}"
                }
            }
            return "{ " + parts.joined(separator: ", ") + (pairs.count > 4 ? ", …" : "") + " }"
        case .array(let items):
            return "[\(items.count) \(items.count == 1 ? "item" : "items")]"
        default:
            return ""
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
