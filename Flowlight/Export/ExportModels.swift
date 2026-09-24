import Foundation

/// Which wire format an export speaks.
enum ExportMode: String, CaseIterable, Identifiable, Sendable {
    /// OTLP over HTTP with a JSON body — the protobuf's canonical JSON mapping, which every OpenTelemetry
    /// collector accepts on `/v1/metrics` and `/v1/logs`.
    case otlp
    /// One JSON object per line, posted in a single request. Most generic SIEM and log HTTP inputs want exactly
    /// that and nothing more, and for them an OTLP envelope is a translation layer they'd have to write.
    case ndjson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .otlp: return "OpenTelemetry (OTLP/HTTP, JSON)"
        case .ndjson: return "Newline-delimited JSON"
        }
    }

    var contentType: String {
        switch self {
        case .otlp: return "application/json"
        case .ndjson: return "application/x-ndjson"
        }
    }
}

/// Every key an export can carry, and the sentence Settings shows beside it.
///
/// The payload builders take their keys from here and nowhere else, and `ExportTests` walks generated JSON to
/// prove nothing outside this list ever appears. That is what makes "you can predict what your SIEM will see" a
/// property of the code rather than a promise in a README: adding a field to an export means adding a case here,
/// which means it shows up in the Settings tab in the same commit.
enum ExportField: String, CaseIterable, Identifiable, Sendable {
    // Resource-level: sent once per request, not once per record.
    case serviceName = "service.name"
    case serviceVersion = "service.version"
    case hostName = "host.name"
    // Per record. OpenTelemetry's own names where the semantic conventions have one, `flowlight.*` where they
    // don't — inventing a plausible-looking standard key for something the spec has no opinion on is how a
    // collector ends up with two meanings for one attribute.
    case appBundleID = "app.bundle_id"
    case appName = "app.name"
    case serverAddress = "server.address"
    case serverPort = "server.port"
    case peerAddress = "network.peer.address"
    case protocolName = "network.protocol.name"
    case ioDirection = "network.io.direction"
    case destinationOwner = "flowlight.destination.owner"
    case destinationASN = "flowlight.destination.asn"
    case agentID = "flowlight.agent.id"
    case agentName = "flowlight.agent.name"
    case mcpServer = "flowlight.mcp.server"
    case channel = "flowlight.network.channel"
    case eventName = "event.name"
    case alertKind = "flowlight.alert.kind"
    case alertID = "flowlight.alert.id"
    // Newline-delimited JSON has no envelope to put timing, counters and text in, so they become plain keys.
    // OTLP carries the same numbers in its data points and log records instead.
    case time
    case type
    case intervalSeconds = "interval_seconds"
    case bytesReceived = "bytes_received"
    case bytesSent = "bytes_sent"
    case flows
    case severity
    case message

    var id: String { rawValue }

    /// The keys that ride along as OTLP attributes. The rest are envelope fields of one format or the other.
    static let attributeFields: [ExportField] = [
        .serviceName, .serviceVersion, .hostName, .appBundleID, .appName, .serverAddress, .serverPort,
        .peerAddress, .protocolName, .ioDirection, .destinationOwner, .destinationASN, .agentID, .agentName,
        .mcpServer, .channel, .eventName, .alertKind, .alertID,
    ]

    /// What a reader of the Settings tab needs to decide whether they're happy for this to leave the Mac.
    var what: String {
        switch self {
        case .serviceName: return "The name you give this Flowlight in your collector."
        case .serviceVersion: return "Flowlight's version."
        case .hostName: return "This Mac's local host name. Turn it off and nothing names the machine."
        case .appBundleID: return "The app's bundle identifier, e.g. com.apple.Safari."
        case .appName: return "The app's name, e.g. Safari."
        case .serverAddress: return "The hostname the app connected to, when one is known."
        case .serverPort: return "The port, when the rollup covers exactly one."
        case .peerAddress: return "The destination IP address."
        case .protocolName: return "The protocol Flowlight classified, e.g. https, ssh — when the rollup covers exactly one."
        case .ioDirection: return "receive or transmit, on each byte count."
        case .destinationOwner: return "Who owns the IP (e.g. Cloudflare, Inc.), for destinations with no hostname."
        case .destinationASN: return "That owner's autonomous system number."
        case .agentID: return "The AI agent this process works for, when it's one of its tools."
        case .agentName: return "That agent's name, e.g. Claude Code."
        case .mcpServer: return "The MCP server this process is, when Flowlight recognised it."
        case .channel: return "Which way the bytes left: the network, peer-to-peer Wi-Fi, this Mac, or a tunnel."
        case .eventName: return "flowlight.alert, so alerts can be told apart from everything else."
        case .alertKind: return "Which rule fired, e.g. Possible data exfiltration by agent."
        case .alertID: return "The alert's row id in Flowlight's local database, so a duplicate can be spotted."
        case .time: return "When the record covers, in ISO 8601."
        case .type: return "rollup, alert or test."
        case .intervalSeconds: return "How many seconds of traffic a rollup adds up."
        case .bytesReceived: return "Bytes in over that interval."
        case .bytesSent: return "Bytes out over that interval."
        case .flows: return "How many connections over that interval."
        case .severity: return "info, warning or critical, for an alert."
        case .message: return "The alert's sentence, exactly as Flowlight's Alerts screen shows it."
        }
    }
}

/// What identifies this Flowlight to a collector. Deliberately three strings: there is no machine id, no user
/// name, no serial and no installation UUID here, and adding one would be a change to `ExportField` first.
struct ExportResource: Sendable, Equatable {
    var serviceName = "flowlight"
    var serviceVersion = ""
    /// Empty when the user turned the host name off.
    var hostName = ""
}

/// One per-app × destination rollup, reduced to what an export carries.
///
/// Every field here already exists in Reports. Nothing in this type comes from HTTPS inspection: there is no
/// header, body, tool call or decrypted anything to put in one, which is what makes "metadata and alerts only"
/// a fact about the types rather than a rule someone has to remember.
struct ExportRollup: Sendable, Equatable {
    var start: Date
    var end: Date
    var bundleID: String
    var appName: String
    var domain: String
    var remoteIP: String
    /// Only set when the rollup covers exactly one port; a comma-separated list under `server.port` would be a
    /// lie to whatever queries it.
    var port: UInt16?
    /// Likewise: one protocol or none.
    var appProtocol: String
    var owner: String
    var asn: Int
    var agentID: String
    var agentName: String
    var mcpServer: String
    /// Which way the bytes left the Mac. Defaulted so a caller that doesn't care — every test, and every reader
    /// that predates channels — still builds one.
    var channel: NetworkChannel = .ip
    var bytesIn: Int64
    var bytesOut: Int64
    var flows: Int64

    /// Seconds of traffic the rollup adds up, at least one.
    var intervalSeconds: Int { max(1, Int(end.timeIntervalSince(start).rounded())) }
}

/// One alert, reduced the same way. `detail` is the sentence Flowlight's Alerts screen shows, which is built
/// from flow metadata (app, destination, port, byte counts) and never from anything inspection recorded.
struct ExportAlert: Sendable, Equatable {
    var id: Int64
    var time: Date
    var kind: String
    var bundleID: String
    var appName: String
    var detail: String
    /// 1 info, 2 warning, 3 critical — Flowlight's own scale, mapped to OpenTelemetry's on the way out.
    var severity: Int
}

enum ExportEndpoint {
    /// The endpoint as a URL, or nil when it isn't one worth sending to. http and https only, and a host is
    /// required: a half-typed endpoint must never turn into a request.
    static func base(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Where one OTLP signal goes. The convention is a base endpoint with the signal path appended
    /// (`http://127.0.0.1:4318` → `/v1/logs`). A URL that already names a signal is taken as given, so someone
    /// whose collector sits behind a gateway path can point straight at it without Flowlight doubling the suffix.
    static func signal(_ path: String, base: URL) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var current = parts.path
        if current.hasSuffix("/v1/logs") || current.hasSuffix("/v1/metrics") { return base }
        while current.hasSuffix("/") { current.removeLast() }
        parts.path = current + path
        return parts.url ?? base
    }

    static let logsPath = "/v1/logs"
    static let metricsPath = "/v1/metrics"
}

/// Everything the exporter reads before it decides to send anything, in one value.
///
/// It is a struct rather than a pile of `UserDefaults` lookups so that "is this thing allowed to send?" is one
/// testable expression, and so a send can't observe a setting changing halfway through.
struct ExportConfiguration: Equatable, Sendable {
    var enabled = false
    var mode: ExportMode = .otlp
    var endpoint = ""
    var interval: TimeInterval = 60
    var includeRollups = true
    var includeAlerts = true
    var serviceName = "flowlight"
    var includeHostName = true
    var maxBufferedRecords = 10_000
    var batchSize = 500

    var endpointURL: URL? { ExportEndpoint.base(endpoint) }

    /// Off until it is switched on, pointed somewhere real, and asked for at least one kind of record. Three
    /// separate conditions because the switch is the only one a user thinks about, and the other two are how a
    /// half-configured export stays silent instead of erroring in the background.
    var isReady: Bool { enabled && endpointURL != nil && (includeRollups || includeAlerts) }

    enum Keys {
        static let enabled = "export.enabled"
        static let mode = "export.mode"
        static let endpoint = "export.endpoint"
        static let intervalSeconds = "export.intervalSeconds"
        static let includeRollups = "export.includeRollups"
        static let includeAlerts = "export.includeAlerts"
        static let serviceName = "export.serviceName"
        static let includeHostName = "export.includeHostName"
        /// How far the rollup export has got, in unix seconds. Set to "now" when export is switched on, so
        /// turning it on never ships the history that was recorded before the decision was made.
        static let watermark = "export.rollupWatermark"
    }

    /// Note what is *not* here: `enabled` is deliberately unregistered, so it is false whether or not this ever
    /// runs, and stays false after a defaults domain is wiped.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.mode: ExportMode.otlp.rawValue, Keys.endpoint: "", Keys.intervalSeconds: 60.0,
            Keys.includeRollups: true, Keys.includeAlerts: true, Keys.serviceName: "flowlight",
            Keys.includeHostName: true,
        ])
    }

    static func load(_ defaults: UserDefaults = .standard) -> ExportConfiguration {
        var config = ExportConfiguration()
        config.enabled = defaults.bool(forKey: Keys.enabled)
        config.mode = ExportMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .otlp
        config.endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        let seconds = defaults.double(forKey: Keys.intervalSeconds)
        config.interval = seconds > 0 ? min(max(seconds, 10), 3600) : 60
        // A defaults domain that has never seen this feature answers `false` to everything, which would leave
        // `isReady` false anyway — but only because nothing is included, which reads as a bug rather than a
        // choice. Registered defaults make both true, and `enabled` is what keeps it off.
        config.includeRollups = defaults.object(forKey: Keys.includeRollups) as? Bool ?? true
        config.includeAlerts = defaults.object(forKey: Keys.includeAlerts) as? Bool ?? true
        let name = (defaults.string(forKey: Keys.serviceName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        config.serviceName = name.isEmpty ? "flowlight" : name
        config.includeHostName = defaults.object(forKey: Keys.includeHostName) as? Bool ?? true
        return config
    }
}

extension ExportRollup {
    /// One breakdown row over one window.
    ///
    /// `ports` and `protocols` arrive as `GROUP_CONCAT` lists because a row can cover several of each; a single
    /// value becomes an attribute and anything else is left out, since a collector that filters on
    /// `server.port = 443` should never match a row that was partly port 8443.
    init(_ row: BreakdownRow, from: Date, to: Date) {
        start = from
        end = to
        bundleID = row.bundleID
        appName = row.appName
        domain = row.domain
        remoteIP = row.remoteIP
        port = Self.single(row.ports).flatMap { UInt16($0) }
        appProtocol = Self.single(row.protocols) ?? ""
        owner = row.owner
        asn = row.asn
        agentID = row.parentAgent
        agentName = row.parentAgentName
        mcpServer = row.mcpServer
        channel = row.channel
        bytesIn = row.counters.bytesIn
        bytesOut = row.counters.bytesOut
        flows = row.counters.flows
    }

    private static func single(_ list: String) -> String? {
        let parts = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count == 1 ? parts[0] : nil
    }
}

extension ExportAlert {
    init(_ record: AlertRecord) {
        id = record.id
        time = record.timestamp
        kind = record.kind
        bundleID = record.bundleID
        appName = record.appName
        detail = record.detail
        severity = record.severity
    }
}
