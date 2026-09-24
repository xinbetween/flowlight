import Foundation

/// "This agent may not use that tool." The AI half of the rule model, and its own idea rather than a special case
/// of the network one: *which tools may this agent use* is a different question from *which hosts may it reach*,
/// and answering it means reading what the agent says rather than where it connects.
///
/// A guardrail names an agent, a server and a tool — any of which may be left blank to mean *all of them* — and
/// refuses it. There is no allow action: a guardrail is subtractive by nature, applied to a list the agent itself
/// declares, and an "allow" would only ever mean "don't subtract this", which is what leaving it out already says.
struct Guardrail: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    /// The agent's key, empty for every agent.
    var agent = ""
    /// The MCP server the tool belongs to, empty for every server — and for an agent's own built-in tools, which
    /// belong to no server.
    var server = ""
    /// The tool's name, or a glob (`*write*`). Empty means every tool on the named server, which is how a whole
    /// server is refused.
    var tool = ""
    /// A resource URI or glob, for `resources/read`. Empty means this guardrail says nothing about resources.
    var resource = ""
    var origin: Origin = .typed
    var name = ""
    var created = Date()
    var hits = 0
    var lastHit: Date?

    enum Origin: String, Codable, Sendable { case typed, preset, observed }

    /// A guardrail that names nothing at all would refuse every tool of every agent. That is never a click away
    /// by accident, so it counts as unfinished.
    var isComplete: Bool { !tool.isEmpty || !server.isEmpty || !resource.isEmpty }

    var title: String {
        if !name.isEmpty { return name }
        let who = agent.isEmpty ? "Any agent" : agent
        if !resource.isEmpty { return "\(who): no \(resource)" }
        let what = tool.isEmpty ? "everything from \(server)" : (server.isEmpty ? tool : "\(server) › \(tool)")
        return "\(who): no \(what)"
    }

    /// Whether this refuses a named tool. Both halves are matched case-insensitively and by glob, because tool
    /// names are written by hand in one place and generated in another.
    func refuses(agent key: String, server name: String?, tool called: String) -> Bool {
        guard enabled, isComplete else { return false }
        if !agent.isEmpty, !GlobMatch.glob(agent.lowercased(), key.lowercased()), agent.lowercased() != key.lowercased() {
            return false
        }
        if !server.isEmpty {
            guard let name, GlobMatch.glob(server.lowercased(), name.lowercased()) || server.lowercased() == name.lowercased() else {
                return false
            }
        }
        guard !tool.isEmpty else { return !server.isEmpty }   // a whole server
        let wanted = tool.lowercased(), got = called.lowercased()
        return wanted == got || GlobMatch.glob(wanted, got)
    }

    func refuses(agent key: String, resource uri: String) -> Bool {
        guard enabled, !resource.isEmpty else { return false }
        if !agent.isEmpty, agent.lowercased() != key.lowercased() { return false }
        let wanted = resource.lowercased(), got = uri.lowercased()
        return wanted == got || GlobMatch.glob(wanted, got)
    }
}

extension Guardrail {
    /// Guardrails worth having before anything has gone wrong, written as tool-name patterns because that is what
    /// agents actually call things. They are starting points in the editor, never switched on behind anyone's back.
    struct Preset: Identifiable, Sendable {
        var name: String
        var detail: String
        var tools: [String]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "No shell", detail: "The agent keeps its other tools, but can't run commands.",
               tools: ["bash", "shell", "run_command", "execute*", "*terminal*"]),
        Preset(name: "No writes", detail: "It can read and search, but not change anything.",
               tools: ["write*", "edit*", "*_write", "create_*", "delete_*", "update_*", "*patch*", "move_*"]),
        Preset(name: "Read-only", detail: "Everything but reading and searching, refused.",
               tools: ["bash", "shell", "write*", "edit*", "create_*", "delete_*", "update_*", "*_write", "*patch*"]),
    ]

    static func preset(_ preset: Preset, agent: String) -> [Guardrail] {
        preset.tools.map {
            Guardrail(agent: agent, tool: $0, origin: .preset, name: "\(preset.name): \($0)")
        }
    }
}

/// Reading the whole guardrail list as one answer.
enum GuardrailBook {
    /// The guardrail that refuses this tool, or nil.
    static func refusing(_ guardrails: [Guardrail], agent: String, server: String?, tool: String) -> Guardrail? {
        guardrails.first { $0.refuses(agent: agent, server: server, tool: tool) }
    }

    static func refusing(_ guardrails: [Guardrail], agent: String, resource: String) -> Guardrail? {
        guardrails.first { $0.refuses(agent: agent, resource: resource) }
    }

    /// Whether any guardrail could apply to this agent at all. Asked before a request body is parsed, so an agent
    /// nobody has written a guardrail about never pays for the feature.
    static func any(_ guardrails: [Guardrail], agent: String) -> Bool {
        guardrails.contains { $0.enabled && $0.isComplete && ($0.agent.isEmpty || $0.agent.lowercased() == agent.lowercased()) }
    }
}
