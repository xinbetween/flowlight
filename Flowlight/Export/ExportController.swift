import Foundation

enum ExportError: LocalizedError {
    case http(Int, String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The collector answered HTTP \(code)." : "The collector answered HTTP \(code): \(detail)"
        case .notConfigured:
            return "No endpoint. Type the address of your collector first."
        }
    }
}

/// Sends recorded metadata to a collector the user chose. Off unless they turn it on, and there is no endpoint
/// to fall back to — there is no Flowlight service, and there must never be one.
///
/// Three things make this feature fit an app whose promise is that nothing leaves the Mac:
///
/// - It is off, and it stays off until it is both switched on and pointed somewhere. Switching it on starts the
///   clock from that moment: history already in the database is never sent, so turning it on is a decision about
///   the future rather than a disclosure of the past.
/// - It sends metadata and alerts, and it is *structurally* incapable of sending anything else. The only things
///   `ExportPayload` accepts are `ExportRollup` and `ExportAlert`, neither of which has anywhere to put a header,
///   a body or anything else HTTPS inspection records.
/// - What it sends is visible in Flowlight. The requests leave as the app's own traffic, so they appear in Live
///   and Reports, count towards the app's baselines, and raise a first-contact alert the first time they go
///   somewhere new — exactly as any other app's would.
@MainActor
final class ExportController: ObservableObject {
    enum TestState: Equatable {
        case idle, running, succeeded(String), failed(String)
    }

    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastRecordsSent = 0
    @Published private(set) var lastError: String?
    @Published private(set) var buffered = 0
    @Published private(set) var dropped = 0
    @Published private(set) var sending = false
    @Published private(set) var testState: TestState = .idle
    /// When a backed-off retry is due, so the status line can say "retrying in…" rather than looking stuck.
    @Published private(set) var nextAttempt: Date?

    /// Rollups for a window and the most recent alerts, supplied by `TrafficMonitor`. Injected rather than opened
    /// here so this type never touches the database, and so a preview can be built in a test without one.
    private var readRollups: ((Date, Date) async throws -> [ExportRollup])?
    private var readRecentAlerts: ((Int) async throws -> [ExportAlert])?

    private var queue = ExportQueue()
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private let version: String

    /// A minute only lands in `agg_1m` once it is complete and maintenance has folded it, so the export window
    /// stops two minutes short of now. Exporting the current minute would send a number that is still growing.
    private static let foldingLag: Int64 = 120
    /// How far back a resumed export reaches. A Mac that was asleep for a week should carry on, not replay the
    /// week: whatever was missed stayed in the local database, which is where it was always going to live.
    private static let maximumCatchUp: Int64 = 3600

    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        ExportConfiguration.registerDefaults()
    }

    // MARK: Settings

    var configuration: ExportConfiguration { .load() }

    var enabled: Bool { UserDefaults.standard.bool(forKey: ExportConfiguration.Keys.enabled) }

    /// Turning it on starts the rollup watermark at this moment, which is what keeps "on from now" true. Turning
    /// it off drops whatever was buffered: keeping records for a collector the user has stopped sending to would
    /// be holding data for a purpose they just withdrew.
    func setEnabled(_ on: Bool) {
        let defaults = UserDefaults.standard
        if on {
            defaults.set(Int(Date().timeIntervalSince1970), forKey: ExportConfiguration.Keys.watermark)
        } else {
            queue = ExportQueue()
            nextAttempt = nil
        }
        defaults.set(on, forKey: ExportConfiguration.Keys.enabled)
        lastError = nil
        testState = .idle
        objectWillChange.send()
        refreshCounts()
        apply()
    }

    /// Any other setting changed. Kept separate from `setEnabled` because changing the endpoint or the interval
    /// must not silently re-arm an export that is switched off.
    func settingsChanged() {
        objectWillChange.send()
        apply()
    }

    func setValue(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        settingsChanged()
    }

    /// The identity a collector sees. Three strings, none of them an installation id.
    var resource: ExportResource {
        let config = configuration
        return ExportResource(serviceName: config.serviceName, serviceVersion: version,
                              hostName: config.includeHostName ? ProcessInfo.processInfo.hostName : "")
    }

    /// Where each request would go, for the Settings tab to show before anything is sent.
    var destinations: [String] {
        guard let base = configuration.endpointURL else { return [] }
        switch configuration.mode {
        case .otlp:
            let config = configuration
            var urls: [String] = []
            if config.includeRollups { urls.append(ExportEndpoint.signal(ExportEndpoint.metricsPath, base: base).absoluteString) }
            if config.includeAlerts { urls.append(ExportEndpoint.signal(ExportEndpoint.logsPath, base: base).absoluteString) }
            return urls
        case .ndjson:
            return [base.absoluteString]
        }
    }

    // MARK: Running

    func start(rollups: @escaping (Date, Date) async throws -> [ExportRollup],
               recentAlerts: @escaping (Int) async throws -> [ExportAlert]) {
        readRollups = rollups
        readRecentAlerts = recentAlerts
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        let config = configuration
        queue.limit = config.maxBufferedRecords
        queue.batchSize = config.batchSize
        // Tell the inspection proxy which loopback port is a collector rather than one of its own legs, so an
        // export to 127.0.0.1 still shows up in Live and Reports. Promising that what Flowlight sends is visible
        // and then hiding the commonest case would be worse than not promising it.
        let base = ExportEndpoint.base(config.endpoint)
        ProxyAttribution.shared.exportPort = base.flatMap { url in
            url.port.map { UInt16(truncatingIfNeeded: $0) } ?? (url.scheme == "https" ? 443 : 80)
        }
        guard config.isReady, readRollups != nil else { return }
        // A fixed short tick rather than one at the export interval: it also drives the backoff, and re-arming a
        // timer every time a setting moves is how an export ends up skipping a round.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Alerts as the engine raises them. Buffered whatever the settings say and filtered at send time, so an
    /// alert raised a second before the switch is flipped isn't sent, and one raised a second after is.
    func record(_ alerts: [AlertRecord]) {
        guard !alerts.isEmpty, configuration.isReady, configuration.includeAlerts else { return }
        queue.add(alerts: alerts.map(ExportAlert.init))
        refreshCounts()
    }

    private func tick() {
        let config = configuration
        guard !sending, config.isReady else { return }
        if let nextAttempt, nextAttempt > Date() { return }
        // Nothing waiting on a retry: keep to the interval the user asked for.
        if queue.inFlight == nil, Date().timeIntervalSince(lastAttempt) < config.interval { return }
        sending = true
        lastAttempt = Date()
        Task { await runOnce(config) }
    }

    private func runOnce(_ config: ExportConfiguration) async {
        defer {
            sending = false
            refreshCounts()
        }
        await collectRollups(config)
        guard let batch = queue.next(), !batch.isEmpty else { return }
        await send(batch, config: config)
    }

    /// Pulls the minute rollups that completed since the last export and advances the watermark.
    private func collectRollups(_ config: ExportConfiguration) async {
        guard config.includeRollups, let readRollups else { return }
        let defaults = UserDefaults.standard
        let now = Int64(Date().timeIntervalSince1970)
        let upper = ((now - Self.foldingLag) / 60) * 60
        let stored = Int64(defaults.integer(forKey: ExportConfiguration.Keys.watermark))
        // No watermark at all means rollups were switched on after export was: start here rather than reaching
        // back into history nobody asked to send.
        guard stored > 0 else {
            defaults.set(Int(upper), forKey: ExportConfiguration.Keys.watermark)
            return
        }
        let lower = max(stored, now - Self.maximumCatchUp)
        guard upper > lower else { return }
        do {
            let rows = try await readRollups(Date(timeIntervalSince1970: TimeInterval(lower)),
                                             Date(timeIntervalSince1970: TimeInterval(upper)))
            queue.add(rollups: rows)
            defaults.set(Int(upper), forKey: ExportConfiguration.Keys.watermark)
        } catch {
            lastError = "Couldn't read the rollups to export: \(error.localizedDescription)"
        }
    }

    private func send(_ batch: ExportBatch, config: ExportConfiguration) async {
        guard let base = config.endpointURL else { return }
        let resource = self.resource
        var remainder = ExportBatch()
        var failure: String?
        do {
            switch config.mode {
            case .otlp:
                if !batch.rollups.isEmpty {
                    let body = try ExportPayload.otlpMetrics(batch.rollups, resource: resource)
                    do { try await post(body, to: ExportEndpoint.signal(ExportEndpoint.metricsPath, base: base), config: config) }
                    catch {
                        remainder.rollups = batch.rollups
                        failure = error.localizedDescription
                    }
                }
                if !batch.alerts.isEmpty {
                    let body = try ExportPayload.otlpLogs(batch.alerts, resource: resource)
                    do { try await post(body, to: ExportEndpoint.signal(ExportEndpoint.logsPath, base: base), config: config) }
                    catch {
                        remainder.alerts = batch.alerts
                        failure = error.localizedDescription
                    }
                }
            case .ndjson:
                let body = try ExportPayload.ndjson(rollups: batch.rollups, alerts: batch.alerts, resource: resource)
                do { try await post(body, to: base, config: config) }
                catch {
                    remainder = batch
                    failure = error.localizedDescription
                }
            }
        } catch {
            // The payload itself couldn't be built. Retrying identical input would fail identically, so the batch
            // goes rather than blocking every later one behind it.
            queue.succeeded()
            lastError = "Couldn't build the payload: \(error.localizedDescription)"
            return
        }
        guard let failure else {
            queue.succeeded()
            nextAttempt = nil
            lastError = nil
            lastSuccess = Date()
            lastRecordsSent = batch.count
            return
        }
        lastError = failure
        nextAttempt = queue.failed(retaining: remainder) ? Date().addingTimeInterval(queue.retryDelay()) : nil
    }

    private func post(_ body: Data, to url: URL, config: ExportConfiguration) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.mode.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in ExportSecrets.load() { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ExportError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Flowlight/\(version)"]
        // Never through Flowlight's own HTTPS inspection proxy, even when the system proxy points at it. An
        // export that proxied itself would be recorded in Inspect with its whole body, and a collector on this
        // Mac would have Flowlight talking to Flowlight. It still leaves as the app's own traffic, so Live,
        // Reports and the anomaly rules see it like anything else.
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        return URLSession(configuration: config)
    }()

    private func refreshCounts() {
        buffered = queue.count
        dropped = queue.dropped
    }

    // MARK: Checking before trusting

    /// Sends the smallest thing the chosen format allows and reports what actually came back — the status code,
    /// or the transport error. No recorded traffic is part of it: OTLP gets a well-formed request with an empty
    /// record list, and newline-delimited JSON gets one line that says it is a test.
    func testConnection() async {
        let config = configuration
        guard let base = config.endpointURL else {
            testState = .failed(ExportError.notConfigured.localizedDescription)
            return
        }
        testState = .running
        do {
            switch config.mode {
            case .otlp:
                let url = ExportEndpoint.signal(ExportEndpoint.logsPath, base: base)
                try await post(ExportPayload.emptyLogsRequest, to: url, config: config)
                testState = .succeeded("\(url.absoluteString) accepted an empty OTLP request.")
            case .ndjson:
                let body = try ExportPayload.ndjsonTestLine(resource: resource)
                try await post(body, to: base, config: config)
                testState = .succeeded("\(base.absoluteString) accepted one test line.")
            }
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    /// Exactly what would go on the wire, built from this Mac's own recent traffic and never sent.
    ///
    /// Someone has to be able to answer "what will my SIEM see?" before the switch goes on, and a documented
    /// field list answers it in the abstract. Their own rows answer it concretely, which is the version that
    /// catches "I didn't realise the hostname was in there".
    func preview(minutes: Int = 15, limit: Int = 5) async -> String {
        let config = configuration
        let resource = self.resource
        let now = Date()
        var rollups: [ExportRollup] = []
        var alerts: [ExportAlert] = []
        if config.includeRollups, let readRollups {
            let from = now.addingTimeInterval(-Double(minutes) * 60)
            rollups = Array(((try? await readRollups(from, now)) ?? []).prefix(limit))
        }
        if config.includeAlerts, let readRecentAlerts {
            alerts = Array(((try? await readRecentAlerts(limit)) ?? []).prefix(3))
        }
        if rollups.isEmpty && alerts.isEmpty {
            return "Nothing has been recorded in the last \(minutes) minutes, so there is no sample to show. "
                + "Leave Flowlight running for a moment and try again."
        }
        let headers = ExportSecrets.load().keys.sorted()
            .map { "\($0): ••••••••" }
        func section(_ url: String, _ body: Data) -> String {
            (["POST \(url)", "Content-Type: \(config.mode.contentType)"] + headers + ["", pretty(body)]).joined(separator: "\n")
        }
        guard let base = config.endpointURL else {
            return "Type the address of your collector first — the preview shows the request that would go to it."
        }
        var parts: [String] = []
        do {
            switch config.mode {
            case .otlp:
                if !rollups.isEmpty {
                    parts.append(section(ExportEndpoint.signal(ExportEndpoint.metricsPath, base: base).absoluteString,
                                         try ExportPayload.otlpMetrics(rollups, resource: resource)))
                }
                if !alerts.isEmpty {
                    parts.append(section(ExportEndpoint.signal(ExportEndpoint.logsPath, base: base).absoluteString,
                                         try ExportPayload.otlpLogs(alerts, resource: resource)))
                }
            case .ndjson:
                parts.append(section(base.absoluteString,
                                     try ExportPayload.ndjson(rollups: rollups, alerts: alerts, resource: resource)))
            }
        } catch {
            return "Couldn't build a sample: \(error.localizedDescription)"
        }
        let counted = "\(rollups.count) rollup\(rollups.count == 1 ? "" : "s") and \(alerts.count) alert\(alerts.count == 1 ? "" : "s")"
        return (["# A sample of \(counted) from your own data. Nothing here has been sent.", ""] + parts).joined(separator: "\n\n")
    }

    /// Re-encodes for reading. The wire format is compact; a preview nobody can read answers nothing.
    private func pretty(_ data: Data) -> String {
        let lines = data.split(separator: 0x0A).map { line -> String in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let formatted = try? JSONSerialization.data(withJSONObject: object,
                                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { return String(decoding: line, as: UTF8.self) }
            return String(decoding: formatted, as: UTF8.self)
        }
        return lines.joined(separator: "\n")
    }
}
