import Darwin
import Foundation

/// One endpoint an agent is configured to use as a proxy or LLM gateway. This is configuration evidence only:
/// it carries no counters and does not claim a request actually traversed the endpoint.
struct AgentGatewayConfig: Equatable, Sendable, Codable {
    struct Endpoint: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
        var scheme: String
        var host: String
        var port: UInt16

        var description: String {
            let displayHost = host.contains(":") ? "[\(host)]" : host
            return "\(scheme)://\(displayHost):\(port)"
        }
        var isLocal: Bool {
            guard host != "localhost" else { return true }
            guard let address = HostCanonicalizer.address(host) else { return false }
            return address == "127.0.0.1" || address == "::1"
        }
    }

    var agent: String
    var endpoint: Endpoint
    var source: String
    var sourceKey: String
}

enum AgentGatewayConfigReader {
    enum JSONKey: Sendable {
        case literal(String)
        case nested([String])

        var label: String {
            switch self {
            case .literal(let key): return key
            case .nested(let path): return path.joined(separator: ".")
            }
        }
    }

    private struct JSONRecipe {
        var agent: String
        var path: String
        var keys: [JSONKey]
    }

    private static let jsonRecipes: [JSONRecipe] = [
        JSONRecipe(agent: "claude", path: ".claude/settings.json", keys: [
            .nested(["env", "ANTHROPIC_BASE_URL"]),
            .nested(["env", "HTTP_PROXY"]),
            .nested(["env", "HTTPS_PROXY"]),
        ]),
        JSONRecipe(agent: "claude", path: ".claude/settings.local.json", keys: [
            .nested(["env", "ANTHROPIC_BASE_URL"]),
            .nested(["env", "HTTP_PROXY"]),
            .nested(["env", "HTTPS_PROXY"]),
        ]),
        JSONRecipe(agent: "cursor", path: "Library/Application Support/Cursor/User/settings.json",
                   keys: [.literal("http.proxy")]),
        JSONRecipe(agent: "windsurf", path: "Library/Application Support/Windsurf/User/settings.json",
                   keys: [.literal("http.proxy")]),
        JSONRecipe(agent: "zed", path: ".config/zed/settings.json", keys: [.literal("proxy")]),
        JSONRecipe(agent: "gemini", path: ".gemini/settings.json", keys: [
            .nested(["general", "proxy"]),
            .nested(["env", "GOOGLE_GEMINI_BASE_URL"]),
            .nested(["env", "GOOGLE_VERTEX_BASE_URL"]),
            .nested(["env", "HTTP_PROXY"]),
            .nested(["env", "HTTPS_PROXY"]),
        ]),
    ]

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     fm: FileManager = .default) -> [AgentGatewayConfig] {
        var gateways = jsonRecipes.flatMap { recipe -> [AgentGatewayConfig] in
            let url = home.appendingPathComponent(recipe.path)
            guard let data = fm.contents(atPath: url.path) else { return [] }
            return parseJSON(data, agent: recipe.agent, source: source(url, home: home), keys: recipe.keys)
        }
        let codex = home.appendingPathComponent(".codex/config.toml")
        if let data = fm.contents(atPath: codex.path) {
            gateways += parseCodexTOML(String(decoding: data, as: UTF8.self), source: source(codex, home: home))
        }
        return deduplicate(gateways)
    }

    static func parseJSON(_ data: Data, agent: String, source: String,
                          keys: [JSONKey]) -> [AgentGatewayConfig] {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
        else { return [] }
        return keys.compactMap { key in
            let raw: String?
            switch key {
            case .literal(let name): raw = root[name] as? String
            case .nested(let path): raw = nested(path, in: root) as? String
            }
            guard let raw, let endpoint = endpoint(raw) else { return nil }
            return AgentGatewayConfig(agent: agent, endpoint: endpoint, source: source, sourceKey: key.label)
        }
    }

    static func parseCodexTOML(_ text: String, source: String) -> [AgentGatewayConfig] {
        var section = ""
        var selectedProvider: String?
        var values: [(section: String, key: String, value: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = ""
                guard let close = tomlTableClose(in: line) else { continue }
                let suffix = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else { continue }
                section = tomlSection(
                    String(line[line.index(after: line.startIndex)..<close])
                )
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = tomlValue(String(line[line.index(after: equals)...]))
            if section.isEmpty, key == "model_provider" { selectedProvider = value }
            if key == "openai_base_url" || key == "base_url" || key == "http_proxy" || key == "https_proxy" {
                values.append((section, key, value))
            }
        }
        return values.compactMap { entry in
            if entry.section.hasPrefix("model_providers.") {
                guard let selectedProvider,
                      entry.section == "model_providers.\(selectedProvider)" else { return nil }
            }
            guard let endpoint = endpoint(entry.value) else { return nil }
            let qualified = entry.section.isEmpty ? entry.key : "\(entry.section).\(entry.key)"
            return AgentGatewayConfig(agent: "codex", endpoint: endpoint, source: source, sourceKey: qualified)
        }
    }

    private static func tomlTableClose(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices.dropFirst() {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : quote ?? character
                continue
            }
            if character == "]", quote == nil { return index }
        }
        return nil
    }

    private static func tomlSection(_ raw: String) -> String {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in raw.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : quote ?? character
                continue
            }
            if character == ".", quote == nil {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.joined(separator: ".")
    }

    private static func tomlValue(_ raw: String) -> String {
        var quote: Character?
        var escaped = false
        for index in raw.indices {
            let character = raw[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : quote ?? character
                continue
            }
            if character == "#", quote == nil {
                return raw[..<index].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func endpoint(_ raw: String) -> AgentGatewayConfig.Endpoint? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host?.lowercased(), !rawHost.isEmpty else { return nil }
        let unbracketed = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let host = HostCanonicalizer.address(unbracketed) ?? unbracketed
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard let port = UInt16(exactly: port) else { return nil }
        // Deliberately discard credentials, path, query, and fragment before anything is persisted or displayed.
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return AgentGatewayConfig.Endpoint(scheme: scheme, host: host, port: port)
    }

    private static func nested(_ path: [String], in root: [String: Any]) -> Any? {
        var value: Any = root
        for component in path {
            guard let object = value as? [String: Any], let next = object[component] else { return nil }
            value = next
        }
        return value
    }

    private static func source(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = home.standardizedFileURL.path
        return path == root ? "~" : path.hasPrefix(root + "/") ? "~/" + path.dropFirst(root.count + 1) : path
    }

    private static func deduplicate(_ values: [AgentGatewayConfig]) -> [AgentGatewayConfig] {
        var effective: [String: AgentGatewayConfig] = [:]
        for value in values { effective["\(value.agent)|\(value.sourceKey)"] = value }
        return effective.values.sorted { ($0.agent, $0.source, $0.sourceKey) < ($1.agent, $1.source, $1.sourceKey) }
    }
}

struct AgentGatewayIdentity: Equatable, Sendable {
    var bundleID: String
    var name: String
    var path: String
}

/// Resolves a configured localhost endpoint to the process that actually owns the listening socket. A configured URL
/// still remains configuration evidence; this only supplies the truthful application identity for its endpoint.
enum LocalGatewayResolver {
    static func resolve(_ endpoint: AgentGatewayConfig.Endpoint) -> AgentGatewayIdentity? {
        guard endpoint.isLocal, let pid = listenerPID(endpoint: endpoint) else { return nil }
        let info = ProcessLookup().info(pid: pid)
        guard !info.bundleID.isEmpty else { return nil }
        return AgentGatewayIdentity(bundleID: info.bundleID, name: info.name, path: info.path)
    }

    static func listenerPID(endpoint: AgentGatewayConfig.Endpoint) -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let matches = pids.prefix(Int(max(0, filled))).filter {
            $0 > 1 && listens(pid: $0, endpoint: endpoint)
        }
        // `localhost` can resolve to either address family. If different processes own IPv4 and IPv6 listeners,
        // process enumeration order is not truthful routing evidence, so keep the configured endpoint synthetic.
        return matches.count == 1 ? matches[0] : nil
    }

    private static func listens(pid: Int32, endpoint: AgentGatewayConfig.Endpoint) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let socket = tcp.tcpsi_ini
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport))
            if tcp.tcpsi_state == TSI_S_LISTEN,
               localPort == endpoint.port,
               address(localAddress(socket), accepts: endpoint.host) { return true }
        }
        return false
    }

    static func address(_ listener: String?, accepts configured: String) -> Bool {
        guard let listener else { return false }
        let configuredAddress = HostCanonicalizer.address(configured)
        if listener == "0.0.0.0" {
            return configured == "localhost" || configuredAddress?.contains(":") == false
        }
        if listener == "::" {
            return configured == "localhost" || configuredAddress?.contains(":") == true
        }
        if configured == "localhost" {
            return listener == "127.0.0.1" || listener == "::1"
        }
        return listener == configuredAddress
    }

    private static func localAddress(_ socket: in_sockinfo) -> String? {
        var address = socket.insi_laddr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
            return withUnsafePointer(to: &address.ina_46.i46a_addr4) { pointer in
                inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count)).map { _ in String(cString: buffer) }
            }
        }
        if socket.insi_vflag & UInt8(INI_IPV6) != 0 {
            return withUnsafePointer(to: &address.ina_6) { pointer in
                inet_ntop(AF_INET6, pointer, &buffer, socklen_t(buffer.count)).map { _ in String(cString: buffer) }
            }
        }
        return nil
    }
}
