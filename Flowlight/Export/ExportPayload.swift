import Foundation

/// Turns rollups and alerts into the bytes that leave the Mac.
///
/// Pure on purpose: values in, JSON out, with no database, no network and no clock of its own. Everything that
/// decides what a collector sees is therefore covered by tests rather than by running the app and watching, and
/// the only inputs are `ExportRollup` and `ExportAlert` — neither of which can carry a header or a body.
enum ExportPayload {
    static let scopeName = "flowlight"

    /// What `Test Connection` sends in OTLP mode: a well-formed logs request with no records in it. It exercises
    /// the URL, TLS, the auth header and the collector's own validation without a byte of recorded traffic.
    static let emptyLogsRequest = Data(#"{"resourceLogs":[]}"#.utf8)

    // MARK: OTLP/HTTP JSON

    /// Metrics: one delta sum per rollup, split by direction, plus a connection count.
    ///
    /// Delta rather than cumulative (`aggregationTemporality: 1`) because that's what Flowlight actually has —
    /// each rollup is the traffic inside one window, and a monitor that restarts would otherwise have to fake a
    /// running total it never kept.
    static func otlpMetrics(_ rollups: [ExportRollup], resource: ExportResource) throws -> Data {
        var bytes: [NumberDataPoint] = []
        var flows: [NumberDataPoint] = []
        for rollup in rollups {
            let attributes = self.attributes(for: rollup)
            let start = nanoseconds(rollup.start), end = nanoseconds(rollup.end)
            if rollup.bytesIn != 0 {
                bytes.append(NumberDataPoint(startTimeUnixNano: start, timeUnixNano: end, asInt: String(rollup.bytesIn),
                                             attributes: attributes + [KeyValue(.ioDirection, "receive")]))
            }
            if rollup.bytesOut != 0 {
                bytes.append(NumberDataPoint(startTimeUnixNano: start, timeUnixNano: end, asInt: String(rollup.bytesOut),
                                             attributes: attributes + [KeyValue(.ioDirection, "transmit")]))
            }
            if rollup.flows != 0 {
                flows.append(NumberDataPoint(startTimeUnixNano: start, timeUnixNano: end, asInt: String(rollup.flows),
                                             attributes: attributes))
            }
        }
        var metrics: [Metric] = []
        if !bytes.isEmpty {
            metrics.append(Metric(name: "flowlight.network.bytes", unit: "By",
                                  sum: Sum(dataPoints: bytes, aggregationTemporality: 1, isMonotonic: true)))
        }
        if !flows.isEmpty {
            metrics.append(Metric(name: "flowlight.network.flows", unit: "{connection}",
                                  sum: Sum(dataPoints: flows, aggregationTemporality: 1, isMonotonic: true)))
        }
        let scope = ScopeMetrics(scope: Scope(name: scopeName, version: resource.serviceVersion), metrics: metrics)
        let request = MetricsRequest(resourceMetrics: [ResourceMetrics(resource: block(resource), scopeMetrics: [scope])])
        return try encoder.encode(request)
    }

    /// Alerts as log records. An alert is an event with a sentence attached, which is what a log record is; a
    /// metric would have thrown the sentence away and left the SIEM with a number nobody can act on.
    static func otlpLogs(_ alerts: [ExportAlert], resource: ExportResource) throws -> Data {
        let records = alerts.map { alert in
            LogRecord(timeUnixNano: nanoseconds(alert.time), observedTimeUnixNano: nanoseconds(alert.time),
                      severityNumber: severityNumber(alert.severity), severityText: severityText(alert.severity),
                      body: .string(alert.detail),
                      attributes: [KeyValue(.eventName, "flowlight.alert"), KeyValue(.alertKind, alert.kind),
                                   KeyValue(.appBundleID, alert.bundleID), KeyValue(.appName, alert.appName),
                                   KeyValue(.alertID, int: alert.id)])
        }
        let scope = ScopeLogs(scope: Scope(name: scopeName, version: resource.serviceVersion), logRecords: records)
        let request = LogsRequest(resourceLogs: [ResourceLogs(resource: block(resource), scopeLogs: [scope])])
        return try encoder.encode(request)
    }

    // MARK: Newline-delimited JSON

    /// One flat object per line. The keys are the same ones OTLP uses as attributes, so the Settings tab's list
    /// of what leaves describes both formats and there is only one thing to keep honest.
    static func ndjson(rollups: [ExportRollup], alerts: [ExportAlert], resource: ExportResource) throws -> Data {
        var lines: [Data] = []
        for rollup in rollups { lines.append(try encoder.encode(Line(rollup, resource: resource))) }
        for alert in alerts { lines.append(try encoder.encode(Line(alert, resource: resource))) }
        return join(lines)
    }

    /// What `Test Connection` sends in newline-delimited mode. A zero-byte POST is rejected by enough collectors
    /// to be a useless test, so it sends one line that names itself and carries no traffic at all.
    static func ndjsonTestLine(resource: ExportResource, at date: Date = Date()) throws -> Data {
        var line = Line(time: timestamp(date), type: "test", serviceName: resource.serviceName)
        line.serviceVersion = resource.serviceVersion.isEmpty ? nil : resource.serviceVersion
        line.hostName = resource.hostName.isEmpty ? nil : resource.hostName
        return join([try encoder.encode(line)])
    }

    // MARK: Shaping

    /// OTLP severity numbers, from the spec's table: 9 INFO, 13 WARN, 17 ERROR.
    static func severityNumber(_ severity: Int) -> Int {
        switch severity {
        case 3...: return 17
        case 2: return 13
        default: return 9
        }
    }

    static func severityText(_ severity: Int) -> String {
        switch severity {
        case 3...: return "ERROR"
        case 2: return "WARN"
        default: return "INFO"
        }
    }

    /// Flowlight's own word for the same thing, for the newline-delimited format, where "ERROR" would suggest
    /// something went wrong with Flowlight rather than with what it was watching.
    static func severityWord(_ severity: Int) -> String {
        switch severity {
        case 3...: return "critical"
        case 2: return "warning"
        default: return "info"
        }
    }

    private static func attributes(for rollup: ExportRollup) -> [KeyValue] {
        var attributes = [KeyValue(.appBundleID, rollup.bundleID), KeyValue(.appName, rollup.appName)]
        if !rollup.domain.isEmpty { attributes.append(KeyValue(.serverAddress, rollup.domain)) }
        if !rollup.remoteIP.isEmpty { attributes.append(KeyValue(.peerAddress, rollup.remoteIP)) }
        if let port = rollup.port { attributes.append(KeyValue(.serverPort, int: Int64(port))) }
        if !rollup.appProtocol.isEmpty { attributes.append(KeyValue(.protocolName, rollup.appProtocol)) }
        if !rollup.owner.isEmpty { attributes.append(KeyValue(.destinationOwner, rollup.owner)) }
        if rollup.asn > 0 { attributes.append(KeyValue(.destinationASN, int: Int64(rollup.asn))) }
        if !rollup.agentID.isEmpty { attributes.append(KeyValue(.agentID, rollup.agentID)) }
        if !rollup.agentName.isEmpty { attributes.append(KeyValue(.agentName, rollup.agentName)) }
        if !rollup.mcpServer.isEmpty { attributes.append(KeyValue(.mcpServer, rollup.mcpServer)) }
        // Only when it isn't the ordinary case: an attribute saying "this went over the network" on every row
        // would be noise in whatever the collector charges by.
        if rollup.channel != .ip { attributes.append(KeyValue(.channel, rollup.channel.rawValue)) }
        return attributes
    }

    private static func block(_ resource: ExportResource) -> Resource {
        var attributes = [KeyValue(.serviceName, resource.serviceName)]
        if !resource.serviceVersion.isEmpty { attributes.append(KeyValue(.serviceVersion, resource.serviceVersion)) }
        if !resource.hostName.isEmpty { attributes.append(KeyValue(.hostName, resource.hostName)) }
        return Resource(attributes: attributes)
    }

    private static func join(_ lines: [Data]) -> Data {
        var out = Data()
        for line in lines { out.append(line); out.append(0x0A) }
        return out
    }

    /// Unix nanoseconds as a decimal string, which is what ProtoJSON asks for a `fixed64`.
    ///
    /// Whole seconds and the fraction are converted separately: a Double holding 1.8e18 nanoseconds has run out
    /// of exact integers, so the obvious one-liner quietly rounds timestamps to the nearest few hundred.
    static func nanoseconds(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = Int64(seconds.rounded(.down))
        let fraction = min(999_999_999, Int64(((seconds - Double(whole)) * 1_000_000_000).rounded()))
        return String(whole * 1_000_000_000 + max(0, fraction))
    }

    static func timestamp(_ date: Date) -> String { iso.string(from: date) }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Sorted keys so a preview, a test and a request all show the same bytes for the same input.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: OTLP shapes
    //
    // These mirror the protobuf messages one for one, with the spec's field names, so what goes on the wire can
    // be read against the specification rather than against a mapping table kept somewhere else.

    private struct AnyValue: Encodable {
        var stringValue: String?
        /// ProtoJSON writes 64-bit integers as strings; a collector that parsed a JSON number here would lose
        /// precision on a large byte count.
        var intValue: String?

        static func string(_ value: String) -> AnyValue { AnyValue(stringValue: value) }
        static func int(_ value: Int64) -> AnyValue { AnyValue(intValue: String(value)) }
    }

    private struct KeyValue: Encodable {
        var key: String
        var value: AnyValue

        init(_ field: ExportField, _ value: String) {
            key = field.rawValue
            self.value = .string(value)
        }

        init(_ field: ExportField, int value: Int64) {
            key = field.rawValue
            self.value = .int(value)
        }
    }

    private struct Resource: Encodable { var attributes: [KeyValue] }
    private struct Scope: Encodable { var name: String; var version: String }

    private struct LogRecord: Encodable {
        var timeUnixNano: String
        var observedTimeUnixNano: String
        var severityNumber: Int
        var severityText: String
        var body: AnyValue
        var attributes: [KeyValue]
    }

    private struct ScopeLogs: Encodable { var scope: Scope; var logRecords: [LogRecord] }
    private struct ResourceLogs: Encodable { var resource: Resource; var scopeLogs: [ScopeLogs] }
    private struct LogsRequest: Encodable { var resourceLogs: [ResourceLogs] }

    private struct NumberDataPoint: Encodable {
        var startTimeUnixNano: String
        var timeUnixNano: String
        var asInt: String
        var attributes: [KeyValue]
    }

    private struct Sum: Encodable {
        var dataPoints: [NumberDataPoint]
        /// 1 is DELTA in the spec's enum, 2 is CUMULATIVE.
        var aggregationTemporality: Int
        var isMonotonic: Bool
    }

    private struct Metric: Encodable { var name: String; var unit: String; var sum: Sum }
    private struct ScopeMetrics: Encodable { var scope: Scope; var metrics: [Metric] }
    private struct ResourceMetrics: Encodable { var resource: Resource; var scopeMetrics: [ScopeMetrics] }
    private struct MetricsRequest: Encodable { var resourceMetrics: [ResourceMetrics] }

    // MARK: Newline-delimited shape

    /// One line, whichever kind of record it holds. A single struct with optionals rather than two, so the key
    /// names live in one `CodingKeys` and can be checked against `ExportField` in one place.
    private struct Line: Encodable {
        var time: String
        var type: String
        var serviceName: String
        var serviceVersion: String?
        var hostName: String?
        var intervalSeconds: Int?
        var bundleID: String?
        var appName: String?
        var serverAddress: String?
        var serverPort: Int?
        var peerAddress: String?
        var protocolName: String?
        var owner: String?
        var asn: Int?
        var agentID: String?
        var agentName: String?
        var mcpServer: String?
        var channel: String?
        var bytesReceived: Int64?
        var bytesSent: Int64?
        var flows: Int64?
        var severity: String?
        var kind: String?
        var alertID: Int64?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case time, type, flows, severity, message
            case serviceName = "service.name"
            case serviceVersion = "service.version"
            case hostName = "host.name"
            case intervalSeconds = "interval_seconds"
            case bundleID = "app.bundle_id"
            case appName = "app.name"
            case serverAddress = "server.address"
            case serverPort = "server.port"
            case peerAddress = "network.peer.address"
            case protocolName = "network.protocol.name"
            case owner = "flowlight.destination.owner"
            case asn = "flowlight.destination.asn"
            case agentID = "flowlight.agent.id"
            case agentName = "flowlight.agent.name"
            case mcpServer = "flowlight.mcp.server"
            case channel = "flowlight.network.channel"
            case bytesReceived = "bytes_received"
            case bytesSent = "bytes_sent"
            case kind = "flowlight.alert.kind"
            case alertID = "flowlight.alert.id"
        }

        init(time: String, type: String, serviceName: String) {
            self.time = time
            self.type = type
            self.serviceName = serviceName
        }

        init(_ rollup: ExportRollup, resource: ExportResource) {
            self.init(time: ExportPayload.timestamp(rollup.start), type: "rollup", serviceName: resource.serviceName)
            serviceVersion = resource.serviceVersion.nilIfEmpty
            hostName = resource.hostName.nilIfEmpty
            intervalSeconds = rollup.intervalSeconds
            bundleID = rollup.bundleID
            appName = rollup.appName
            serverAddress = rollup.domain.nilIfEmpty
            serverPort = rollup.port.map(Int.init)
            peerAddress = rollup.remoteIP.nilIfEmpty
            protocolName = rollup.appProtocol.nilIfEmpty
            owner = rollup.owner.nilIfEmpty
            asn = rollup.asn > 0 ? rollup.asn : nil
            agentID = rollup.agentID.nilIfEmpty
            agentName = rollup.agentName.nilIfEmpty
            mcpServer = rollup.mcpServer.nilIfEmpty
            channel = rollup.channel == .ip ? nil : rollup.channel.rawValue
            bytesReceived = rollup.bytesIn
            bytesSent = rollup.bytesOut
            flows = rollup.flows
        }

        init(_ alert: ExportAlert, resource: ExportResource) {
            self.init(time: ExportPayload.timestamp(alert.time), type: "alert", serviceName: resource.serviceName)
            serviceVersion = resource.serviceVersion.nilIfEmpty
            hostName = resource.hostName.nilIfEmpty
            bundleID = alert.bundleID
            appName = alert.appName
            severity = ExportPayload.severityWord(alert.severity)
            kind = alert.kind
            alertID = alert.id
            message = alert.detail
        }
    }
}
