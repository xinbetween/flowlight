import Foundation

/// The domains an agent's MCP servers involve, gathered from every place Flowlight already knows one.
///
/// An MCP server reaches the network in more than one way, and each way is learned somewhere different: a
/// remote server has a URL in a config file, a server the agent actually called has an endpoint the proxy saw,
/// a connector the provider runs has a URL declared in the request body, and a local server started on this Mac
/// has no URL at all but still makes its own calls, which arrive as ordinary attributed traffic.
///
/// Listing them together is the point. "Declared in a config file" and "actually contacted" are different
/// facts, and a domain carrying both is a stronger statement than either alone — while a domain that is only
/// configured has never been reached, and a domain that is only observed was never declared anywhere you could
/// have read it.
enum MCPDomains {

    /// Where the knowledge came from. A domain can have several.
    enum Source: String, CaseIterable, Comparable, Sendable {
        /// A URL in an MCP configuration file on this Mac.
        case configured
        /// The proxy watched this Mac speak JSON-RPC to it.
        case observed
        /// The agent declared it to the model provider, which connects to it itself.
        case declared
        /// A local MCP server process made this connection.
        case contacted

        var label: String {
            switch self {
            case .configured: return L("in a config file")
            case .observed: return L("called from this Mac")
            case .declared: return L("declared to the provider")
            case .contacted: return L("contacted by the server")
            }
        }

        static func < (a: Source, b: Source) -> Bool {
            (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { host }
        var host: String
        /// The MCP servers this host belongs to, for the row's subtitle.
        var servers: [String]
        var sources: Set<Source>
        /// Bytes seen, when any of this host's traffic reached the Mac. Nil for a host only ever declared.
        var counters: FlowCounters?

        /// Whether refusing this host on this Mac would do anything.
        ///
        /// A connector the provider runs is reached by the provider, not by you: the request that triggers it
        /// leaves for the model's API and the MCP call happens on the far side. A local rule cannot touch it,
        /// and offering a button that silently does nothing would be worse than saying so.
        var blockable: Bool { sources != [.declared] }

        var sortedSources: [Source] { sources.sorted() }
    }

    /// Everything known about one agent's MCP servers, newest knowledge merged into oldest.
    ///
    /// - Parameters:
    ///   - seen: servers the proxy watched, which carry an endpoint and a kind.
    ///   - configured: servers declared in config files but not seen in this window.
    ///   - destinations: the agent's destinations, whose `via` names the tool or MCP server that used them.
    static func collect(seen: [MCPServerSummary],
                        configured: [MCPServerConfig],
                        destinations: [AgentDestination]) -> [Entry] {
        var byHost: [String: Entry] = [:]

        func add(_ host: String?, server: String, source: Source, counters: FlowCounters? = nil) {
            guard let host = normalise(host), !host.isEmpty else { return }
            var entry = byHost[host] ?? Entry(host: host, servers: [], sources: [], counters: nil)
            entry.sources.insert(source)
            if !entry.servers.contains(server) { entry.servers.append(server) }
            if let counters {
                var total = entry.counters ?? FlowCounters()
                total += counters
                entry.counters = total
            }
            byHost[host] = entry
        }

        for server in seen {
            // A provider-run connector and a server this Mac calls both carry an endpoint; only the kind says
            // which, and only one of them is reachable by a rule here.
            add(server.endpoint, server: server.name, source: server.kind == .provider ? .declared : .observed)
        }
        for server in configured {
            add(server.url?.host, server: server.name, source: .configured)
        }
        // A local MCP server has no endpoint of its own, but the calls it makes are attributed to it.
        let names = Set(seen.map(\.name) + configured.map(\.name))
        for destination in destinations {
            for via in destination.via where names.contains(via) {
                add(destination.label, server: via, source: .contacted, counters: destination.counters)
            }
        }

        // Most traffic first, then the ones only ever declared, then alphabetically — the rows worth acting on
        // are the ones something actually went to.
        return byHost.values.sorted {
            let a = $0.counters?.total ?? 0, b = $1.counters?.total ?? 0
            if a != b { return a > b }
            if $0.blockable != $1.blockable { return $0.blockable }
            return $0.host < $1.host
        }
    }

    /// A hostname from a URL, an endpoint string ("api.example/mcp"), or a destination label.
    ///
    /// Endpoints arrive as host plus path because that is what identifies an MCP server, but a rule names a
    /// host: blocking `api.example/mcp` would match nothing, since the flow layer never sees a path.
    static func normalise(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        // Strip a port, but not from a bare IPv6 literal, where the colons are the address.
        if !text.contains("["), text.filter({ $0 == ":" }).count == 1,
           let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        return text.isEmpty ? nil : text
    }
}
