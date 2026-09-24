import XCTest
@testable import Flowlight

/// Payload shape, against the OpenTelemetry specification's own field names.
final class ExportPayloadTests: XCTestCase {
    private let resource = ExportResource(serviceName: "flowlight", serviceVersion: "0.3.1", hostName: "test-mac.local")

    private func rollup(bytesIn: Int64 = 4096, bytesOut: Int64 = 512, flows: Int64 = 3,
                        ports: String = "443", protocols: String = "https") -> ExportRollup {
        var row = BreakdownRow(bundleID: "com.example.Agent", appName: "Agent", appPath: "/Applications/Agent.app",
                               domain: "api.example.com", remoteIP: "203.0.113.7", ports: ports, protocols: protocols,
                               counters: FlowCounters(bytesIn: bytesIn, bytesOut: bytesOut, flows: flows))
        row.owner = "Example Networks, Inc."
        row.asn = 64496
        row.parentAgent = "com.example.ClaudeCode"
        row.parentAgentName = "Claude Code"
        row.mcpServer = "github"
        return ExportRollup(row, from: Date(timeIntervalSince1970: 1_750_000_000),
                            to: Date(timeIntervalSince1970: 1_750_000_060))
    }

    private func alert(severity: Int = 3) -> ExportAlert {
        ExportAlert(id: 42, time: Date(timeIntervalSince1970: 1_750_000_030), kind: "Possible data exfiltration by agent",
                    bundleID: "com.example.Agent", appName: "Agent",
                    detail: "Agent uploaded 210 MB to non-AI hosts in the last hour: paste.example (210 MB)",
                    severity: severity)
    }

    func testOTLPMetricsUseTheSpecsFieldNames() throws {
        let data = try ExportPayload.otlpMetrics([rollup()], resource: resource)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceMetrics = try XCTUnwrap((json["resourceMetrics"] as? [[String: Any]])?.first)
        let scopeMetrics = try XCTUnwrap((resourceMetrics["scopeMetrics"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap(scopeMetrics["metrics"] as? [[String: Any]])

        let bytes = try XCTUnwrap(metrics.first { $0["name"] as? String == "flowlight.network.bytes" })
        XCTAssertEqual(bytes["unit"] as? String, "By", "OpenTelemetry's UCUM code for bytes")
        let sum = try XCTUnwrap(bytes["sum"] as? [String: Any])
        XCTAssertEqual(sum["aggregationTemporality"] as? Int, 1, "1 is DELTA: each rollup is a window, not a running total")
        XCTAssertEqual(sum["isMonotonic"] as? Bool, true)

        let points = try XCTUnwrap(sum["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(points.count, 2, "one point per direction")
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point["startTimeUnixNano"] as? String, "1750000000000000000", "fixed64 goes on the wire as a string")
        XCTAssertEqual(point["timeUnixNano"] as? String, "1750000060000000000")
        XCTAssertTrue(point["asInt"] is String, "int64 goes on the wire as a string, or a big byte count loses precision")

        let directions = Set(points.compactMap { attribute($0, "network.io.direction") })
        XCTAssertEqual(directions, ["receive", "transmit"])
        XCTAssertEqual(attribute(point, "server.address"), "api.example.com")
        XCTAssertEqual(attribute(point, "network.peer.address"), "203.0.113.7")
        XCTAssertEqual(attribute(point, "app.bundle_id"), "com.example.Agent")
        XCTAssertEqual(attribute(point, "flowlight.agent.name"), "Claude Code")
        XCTAssertEqual(attribute(point, "flowlight.mcp.server"), "github")

        let flows = try XCTUnwrap(metrics.first { $0["name"] as? String == "flowlight.network.flows" })
        XCTAssertEqual(flows["unit"] as? String, "{connection}")

        let attributes = try XCTUnwrap((resourceMetrics["resource"] as? [String: Any])?["attributes"] as? [[String: Any]])
        XCTAssertEqual(value(attributes, "service.name"), "flowlight")
        XCTAssertEqual(value(attributes, "host.name"), "test-mac.local")
    }

    func testOTLPIntegersAreStringsAndPortsAreIntegers() throws {
        let data = try ExportPayload.otlpMetrics([rollup()], resource: resource)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""asInt":"4096""#))
        XCTAssertTrue(text.contains(#"{"key":"server.port","value":{"intValue":"443"}}"#),
                      "an int attribute is an intValue carrying a string, per ProtoJSON")
    }

    func testAPortOrProtocolOnlyRidesAlongWhenTheRollupCoversOne() throws {
        let several = rollup(ports: "443,8443", protocols: "https,quic")
        XCTAssertNil(several.port, "a rollup spanning two ports must not claim one of them")
        XCTAssertEqual(several.appProtocol, "")
        let data = try ExportPayload.otlpMetrics([several], resource: resource)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("server.port"))
        XCTAssertFalse(text.contains("network.protocol.name"))
    }

    func testOTLPLogsCarryAlertsWithTheSpecsSeverities() throws {
        let data = try ExportPayload.otlpLogs([alert(severity: 3), alert(severity: 2), alert(severity: 1)], resource: resource)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceLogs = try XCTUnwrap((json["resourceLogs"] as? [[String: Any]])?.first)
        let scopeLogs = try XCTUnwrap((resourceLogs["scopeLogs"] as? [[String: Any]])?.first)
        let records = try XCTUnwrap(scopeLogs["logRecords"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["severityNumber"] as? Int }, [17, 13, 9], "ERROR, WARN, INFO in the spec's table")
        XCTAssertEqual(records.map { $0["severityText"] as? String }, ["ERROR", "WARN", "INFO"])

        let first = try XCTUnwrap(records.first)
        XCTAssertEqual(first["timeUnixNano"] as? String, "1750000030000000000")
        XCTAssertEqual(first["observedTimeUnixNano"] as? String, "1750000030000000000")
        XCTAssertEqual((first["body"] as? [String: Any])?["stringValue"] as? String,
                       "Agent uploaded 210 MB to non-AI hosts in the last hour: paste.example (210 MB)")
        XCTAssertEqual(attribute(first, "event.name"), "flowlight.alert")
        XCTAssertEqual(attribute(first, "flowlight.alert.kind"), "Possible data exfiltration by agent")
        XCTAssertEqual(attribute(first, "flowlight.alert.id"), "42")
    }

    func testTheEmptyRequestTestConnectionSendsCarriesNoRecords() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ExportPayload.emptyLogsRequest) as? [String: Any])
        XCTAssertEqual((json["resourceLogs"] as? [Any])?.count, 0, "valid OTLP, and not a byte of recorded traffic")
    }

    func testSubSecondTimestampsSurviveTheNanosecondConversion() {
        // 1.75e18 nanoseconds is far past the last exactly representable Double integer, so the naive
        // multiply-by-a-billion silently rounds. These have to come back exact.
        XCTAssertEqual(ExportPayload.nanoseconds(Date(timeIntervalSince1970: 1_750_000_000)), "1750000000000000000")
        XCTAssertEqual(ExportPayload.nanoseconds(Date(timeIntervalSince1970: 1_750_000_000.25)), "1750000000250000000")
        XCTAssertEqual(ExportPayload.nanoseconds(Date(timeIntervalSince1970: 1_750_000_001.5)), "1750000001500000000")
    }

    func testNDJSONIsOneObjectPerLine() throws {
        let data = try ExportPayload.ndjson(rollups: [rollup(), rollup()], alerts: [alert()], resource: resource)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["type"] as? String }, ["rollup", "rollup", "alert"])

        let rollupLine = try XCTUnwrap(objects.first)
        XCTAssertEqual(rollupLine["time"] as? String, "2025-06-15T15:06:40Z")
        XCTAssertEqual(rollupLine["interval_seconds"] as? Int, 60)
        XCTAssertEqual(rollupLine["bytes_received"] as? Int, 4096)
        XCTAssertEqual(rollupLine["bytes_sent"] as? Int, 512)
        XCTAssertEqual(rollupLine["server.address"] as? String, "api.example.com")

        let alertLine = try XCTUnwrap(objects.last)
        XCTAssertEqual(alertLine["severity"] as? String, "critical")
        XCTAssertEqual(alertLine["flowlight.alert.kind"] as? String, "Possible data exfiltration by agent")
        XCTAssertNotNil(alertLine["message"])
    }

    func testTheNDJSONTestLineCarriesNoTraffic() throws {
        let data = try ExportPayload.ndjsonTestLine(resource: resource, at: Date(timeIntervalSince1970: 1_750_000_000))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "test")
        for key in ["app.bundle_id", "server.address", "network.peer.address", "bytes_sent", "bytes_received", "message"] {
            XCTAssertNil(json[key], "\(key) has no business in a connection test")
        }
    }

    // MARK: Helpers

    private func attribute(_ object: [String: Any], _ key: String) -> String? {
        value(object["attributes"] as? [[String: Any]] ?? [], key)
    }

    private func value(_ attributes: [[String: Any]], _ key: String) -> String? {
        guard let match = attributes.first(where: { $0["key"] as? String == key }),
              let value = match["value"] as? [String: Any] else { return nil }
        return (value["stringValue"] as? String) ?? (value["intValue"] as? String)
    }
}

/// What can and cannot leave the Mac. These are the tests that have to keep passing if the feature is to stay
/// compatible with the promise the rest of the app makes.
final class ExportRedactionTests: XCTestCase {
    /// The two types the payload builders accept. If someone adds a field to either, this fails and they have to
    /// decide, in the open, that the new field is one a SIEM should see.
    func testOnlyTheDeclaredFieldsExistOnTheExportedTypes() {
        let rollup = ExportRollup(start: .distantPast, end: .distantPast, bundleID: "", appName: "", domain: "",
                                  remoteIP: "", port: nil, appProtocol: "", owner: "", asn: 0, agentID: "",
                                  agentName: "", mcpServer: "", bytesIn: 0, bytesOut: 0, flows: 0)
        XCTAssertEqual(Set(Mirror(reflecting: rollup).children.compactMap(\.label)),
                       ["start", "end", "bundleID", "appName", "domain", "remoteIP", "port", "appProtocol",
                        "owner", "asn", "agentID", "agentName", "mcpServer", "bytesIn", "bytesOut", "flows"])

        let alert = ExportAlert(id: 0, time: .distantPast, kind: "", bundleID: "", appName: "", detail: "", severity: 0)
        XCTAssertEqual(Set(Mirror(reflecting: alert).children.compactMap(\.label)),
                       ["id", "time", "kind", "bundleID", "appName", "detail", "severity"])
    }

    /// No field name may even suggest inspected content. HTTPS inspection records headers and bodies; an export
    /// has no type that can hold one, and this is the guard against that changing by accident.
    func testNoDeclaredFieldNamesAnythingInspectionRecords() {
        let forbidden = ["header", "body", "payload", "cookie", "authorization", "token", "secret", "content",
                         "request", "response", "tool_call", "prompt"]
        for field in ExportField.allCases {
            let name = field.rawValue.lowercased()
            for word in forbidden {
                XCTAssertFalse(name.contains(word), "\(field.rawValue) reads like inspected content")
            }
        }
    }

    /// Every key that actually appears in a payload is one the Settings tab lists. Values are the user's own
    /// traffic; keys are the contract, and this is what stops the contract drifting from the code.
    func testEveryKeyInEveryFormatIsDeclared() throws {
        let declared = Set(ExportField.allCases.map(\.rawValue))
        let attributeKeys = Set(ExportField.attributeFields.map(\.rawValue))
        // Values chosen to look like the things that must never get out, so a leak by way of a stray key is loud.
        var row = BreakdownRow(bundleID: "com.example.App", appName: "App", appPath: "/Applications/App.app",
                               domain: "collector.example", remoteIP: "203.0.113.1", ports: "443", protocols: "https",
                               counters: FlowCounters(bytesIn: 1, bytesOut: 2, flows: 1))
        row.owner = "Authorization: Bearer sk-not-a-real-token"
        row.asn = 64496
        row.parentAgent = "com.example.Agent"
        row.parentAgentName = "Agent"
        row.mcpServer = "github"
        let rollup = ExportRollup(row, from: Date(timeIntervalSince1970: 1_750_000_000),
                                  to: Date(timeIntervalSince1970: 1_750_000_060))
        let alert = ExportAlert(id: 1, time: Date(timeIntervalSince1970: 1_750_000_000), kind: "First contact with domain",
                                bundleID: "com.example.App", appName: "App", detail: "App contacted collector.example",
                                severity: 1)
        let resource = ExportResource(serviceName: "flowlight", serviceVersion: "0.3.1", hostName: "mac.local")

        for data in [try ExportPayload.otlpMetrics([rollup], resource: resource),
                     try ExportPayload.otlpLogs([alert], resource: resource)] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data))
            let keys = Self.attributeKeys(in: json)
            XCTAssertFalse(keys.isEmpty)
            XCTAssertTrue(keys.isSubset(of: attributeKeys), "undeclared OTLP attributes: \(keys.subtracting(attributeKeys))")
        }

        let ndjson = try ExportPayload.ndjson(rollups: [rollup], alerts: [alert], resource: resource)
        for line in String(decoding: ndjson, as: UTF8.self).split(separator: "\n") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let keys = Set(object.keys)
            XCTAssertTrue(keys.isSubset(of: declared), "undeclared NDJSON keys: \(keys.subtracting(declared))")
        }
    }

    /// Walks an OTLP document and collects every `{"key": …}` an attribute list uses.
    private static func attributeKeys(in json: Any) -> Set<String> {
        var found: Set<String> = []
        if let object = json as? [String: Any] {
            if let key = object["key"] as? String, object["value"] != nil { found.insert(key) }
            for value in object.values { found.formUnion(attributeKeys(in: value)) }
        } else if let array = json as? [Any] {
            for value in array { found.formUnion(attributeKeys(in: value)) }
        }
        return found
    }
}

/// Being off unless someone turned it on, and pointing only where they said.
final class ExportConfigurationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "flowlight.export.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testDisabledByDefaultAndNeverRegisteredOn() {
        XCTAssertFalse(ExportConfiguration().enabled)
        XCTAssertFalse(ExportConfiguration().isReady)
        XCTAssertEqual(ExportConfiguration().endpoint, "", "there is no endpoint to fall back to, and never will be")

        // Registering defaults must not put `enabled` in the registration domain. A Mac that has never seen this
        // feature, and one whose preferences were wiped, both have to answer "off" — which they only do if the
        // key is genuinely absent rather than registered as something.
        ExportConfiguration.registerDefaults(in: defaults)
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertNil(registered[ExportConfiguration.Keys.enabled])
        XCTAssertEqual(registered[ExportConfiguration.Keys.endpoint] as? String, "")
    }

    func testSwitchedOnIsStillNotReadyWithoutAnEndpointOrAnythingToSend() {
        ExportConfiguration.registerDefaults(in: defaults)
        defaults.set(true, forKey: ExportConfiguration.Keys.includeRollups)
        defaults.set(true, forKey: ExportConfiguration.Keys.includeAlerts)
        defaults.set(true, forKey: ExportConfiguration.Keys.enabled)
        XCTAssertFalse(ExportConfiguration.load(defaults).isReady, "no endpoint")

        defaults.set("not a url", forKey: ExportConfiguration.Keys.endpoint)
        XCTAssertFalse(ExportConfiguration.load(defaults).isReady)

        defaults.set("https://collector.example:4318", forKey: ExportConfiguration.Keys.endpoint)
        XCTAssertTrue(ExportConfiguration.load(defaults).isReady)

        defaults.set(false, forKey: ExportConfiguration.Keys.includeRollups)
        defaults.set(false, forKey: ExportConfiguration.Keys.includeAlerts)
        XCTAssertFalse(ExportConfiguration.load(defaults).isReady, "nothing to include is not a configuration")
    }

    func testIntervalIsClampedToSomethingSane() {
        ExportConfiguration.registerDefaults(in: defaults)
        defaults.set(1.0, forKey: ExportConfiguration.Keys.intervalSeconds)
        XCTAssertEqual(ExportConfiguration.load(defaults).interval, 10)
        defaults.set(99_999.0, forKey: ExportConfiguration.Keys.intervalSeconds)
        XCTAssertEqual(ExportConfiguration.load(defaults).interval, 3600)
    }

    func testEndpointAcceptsOnlyHTTPAddressesWithAHost() {
        XCTAssertNotNil(ExportEndpoint.base("http://127.0.0.1:4318"))
        XCTAssertNotNil(ExportEndpoint.base("  https://collector.example.com/otlp  "), "trimmed")
        XCTAssertNil(ExportEndpoint.base(""))
        XCTAssertNil(ExportEndpoint.base("collector.example.com:4318"), "no scheme")
        XCTAssertNil(ExportEndpoint.base("ftp://collector.example.com"))
        XCTAssertNil(ExportEndpoint.base("file:///etc/passwd"))
        XCTAssertNil(ExportEndpoint.base("https://"), "no host")
    }

    func testSignalPathIsAppendedOnceAndNeverDoubled() throws {
        let base = try XCTUnwrap(ExportEndpoint.base("http://127.0.0.1:4318"))
        XCTAssertEqual(ExportEndpoint.signal("/v1/logs", base: base).absoluteString, "http://127.0.0.1:4318/v1/logs")
        XCTAssertEqual(ExportEndpoint.signal("/v1/metrics", base: base).absoluteString, "http://127.0.0.1:4318/v1/metrics")

        let trailing = try XCTUnwrap(ExportEndpoint.base("https://collector.example/otlp/"))
        XCTAssertEqual(ExportEndpoint.signal("/v1/logs", base: trailing).absoluteString, "https://collector.example/otlp/v1/logs")

        // Someone whose gateway sits on the signal path itself points straight at it.
        let exact = try XCTUnwrap(ExportEndpoint.base("https://collector.example/v1/logs"))
        XCTAssertEqual(ExportEndpoint.signal("/v1/logs", base: exact).absoluteString, "https://collector.example/v1/logs")
    }
}

/// Batching, the hard buffer cap, and giving up rather than retrying forever.
final class ExportQueueTests: XCTestCase {
    private func rollup(_ index: Int) -> ExportRollup {
        ExportRollup(start: Date(timeIntervalSince1970: TimeInterval(index)), end: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                     bundleID: "com.example.App", appName: "App", domain: "example.com", remoteIP: "203.0.113.1",
                     port: 443, appProtocol: "https", owner: "", asn: 0, agentID: "", agentName: "", mcpServer: "",
                     bytesIn: Int64(index), bytesOut: 0, flows: 1)
    }

    private func alert(_ id: Int64) -> ExportAlert {
        ExportAlert(id: id, time: Date(timeIntervalSince1970: 1), kind: "First contact with domain",
                    bundleID: "com.example.App", appName: "App", detail: "…", severity: 1)
    }

    func testBatchesAreCappedAndAlertsGoFirst() {
        var queue = ExportQueue()
        queue.batchSize = 10
        queue.add(rollups: (0..<50).map(rollup), alerts: (0..<4).map { alert(Int64($0)) })
        let batch = queue.next()
        XCTAssertEqual(batch?.alerts.count, 4, "the small urgent half isn't held up behind a rollup backlog")
        XCTAssertEqual(batch?.rollups.count, 6)
        XCTAssertEqual(batch?.count, 10)
        XCTAssertEqual(queue.count, 54, "an unacknowledged batch is still held")
    }

    func testTheSameBatchComesBackUntilItIsAcknowledged() {
        var queue = ExportQueue()
        queue.batchSize = 2
        queue.add(rollups: (0..<6).map(rollup))
        let first = queue.next()
        XCTAssertEqual(queue.next(), first, "a batch in flight is not re-sliced")
        queue.succeeded()
        XCTAssertNotEqual(queue.next(), first)
    }

    func testTheBufferHasAHardCapAndDropsTheOldestFirst() {
        var queue = ExportQueue()
        queue.limit = 10
        queue.add(rollups: (0..<25).map(rollup))
        XCTAssertEqual(queue.count, 10, "a collector that's down must cost a fixed amount of memory")
        XCTAssertEqual(queue.dropped, 15)
        XCTAssertEqual(queue.rollups.first?.bytesIn, 15, "the oldest went")
    }

    func testAlertsAreKeptInPreferenceToRollups() {
        var queue = ExportQueue()
        queue.limit = 5
        queue.add(rollups: (0..<4).map(rollup), alerts: (0..<4).map { alert(Int64($0)) })
        XCTAssertEqual(queue.count, 5)
        XCTAssertEqual(queue.alerts.count, 4, "an alert is a one-off somebody wants to see")
        XCTAssertEqual(queue.rollups.count, 1)
    }

    func testRetryKeepsOnlyThePartThatFailed() throws {
        var queue = ExportQueue()
        queue.add(rollups: [rollup(1)], alerts: [alert(1)])
        let batch = try XCTUnwrap(queue.next())
        // OTLP sends two requests: metrics landed, logs didn't.
        XCTAssertTrue(queue.failed(retaining: ExportBatch(alerts: batch.alerts)))
        XCTAssertEqual(queue.next()?.rollups.count, 0)
        XCTAssertEqual(queue.next()?.alerts.count, 1)
    }

    func testBackoffGrowsThenCapsAndTheBatchIsGivenUpOn() throws {
        var queue = ExportQueue()
        queue.maxAttempts = 5
        queue.add(rollups: [rollup(1)])
        let batch = try XCTUnwrap(queue.next())
        XCTAssertEqual(queue.retryDelay(base: 5, cap: 300), 0, "nothing has failed yet")

        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            XCTAssertTrue(queue.failed(retaining: batch))
            delays.append(queue.retryDelay(base: 5, cap: 300))
        }
        XCTAssertEqual(delays, [5, 10, 20, 40])
        XCTAssertFalse(queue.failed(retaining: batch), "the fifth attempt is the last one")
        XCTAssertNil(queue.inFlight)
        XCTAssertEqual(queue.dropped, 1, "given up on, and counted rather than hidden")
        XCTAssertEqual(queue.count, 0)
    }

    func testBackoffIsCapped() {
        var queue = ExportQueue()
        queue.maxAttempts = 20
        queue.add(rollups: [rollup(1)])
        _ = queue.next()
        for _ in 0..<12 { _ = queue.failed(retaining: ExportBatch(rollups: [rollup(1)])) }
        XCTAssertEqual(queue.retryDelay(base: 5, cap: 300), 300, "a collector that's been down for a day is polled every 5 min")
    }

    func testAnEmptyQueueHasNothingToSend() {
        var queue = ExportQueue()
        XCTAssertNil(queue.next())
        queue.add(rollups: [], alerts: [])
        XCTAssertNil(queue.next())
    }
}

/// The conversion from what the database holds to what an export carries.
final class ExportRowTests: XCTestCase {
    func testABreakdownRowBecomesARollupWithoutItsPath() {
        let row = BreakdownRow(bundleID: "com.example.App", appName: "App", appPath: "/Users/someone/Secret/App.app",
                               domain: "example.com", remoteIP: "203.0.113.1", ports: "443", protocols: "https",
                               counters: FlowCounters(bytesIn: 10, bytesOut: 20, flows: 2))
        let rollup = ExportRollup(row, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(rollup.port, 443)
        XCTAssertEqual(rollup.intervalSeconds, 60)
        XCTAssertEqual(rollup.bytesIn, 10)
        // The app's path on disk names the user's home folder. It is in the breakdown and it stays there.
        XCTAssertFalse(Mirror(reflecting: rollup).children.contains { $0.label == "appPath" })
    }

    func testAnAlertRecordBecomesAnExportAlert() {
        let record = AlertRecord(id: 7, timestamp: Date(timeIntervalSince1970: 100), kind: "Non-standard port",
                                 bundleID: "com.example.App", appName: "App", detail: "App → example.com on TCP port 9000",
                                 severity: 2, acknowledged: false, allowPattern: "example.com")
        let alert = ExportAlert(record)
        XCTAssertEqual(alert.id, 7)
        XCTAssertEqual(alert.severity, 2)
        XCTAssertEqual(alert.detail, "App → example.com on TCP port 9000")
        XCTAssertFalse(Mirror(reflecting: alert).children.contains { $0.label == "allowPattern" },
                       "what a one-click Allow would add is a local affordance, not something a SIEM needs")
    }
}
