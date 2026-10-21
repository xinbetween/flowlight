import Foundation

@MainActor
final class RulePackCatalogUpdater: ObservableObject {
    enum Status: Equatable, Sendable {
        case idle
        case checking
        case current
        case stale
        case recovery(String)
        case failed(String, usingLastKnownGood: Bool)
    }

    enum UpdateError: Error, Equatable, CustomStringConvertible {
        case invalidResponse
        case wrongOrigin
        case badStatus(Int)
        case wrongMIME(String)
        case responseTooLarge
        case missingCache

        var description: String {
            switch self {
            case .invalidResponse: return "The official catalog returned an invalid response."
            case .wrongOrigin: return "The official catalog redirected outside its trusted HTTPS origin."
            case .badStatus(let code): return "The official catalog returned HTTP \(code)."
            case .wrongMIME(let value): return "The official catalog returned an unsupported content type: \(value)."
            case .responseTooLarge: return "The official catalog exceeded the 8 MiB size limit."
            case .missingCache: return "The server reported no change, but no verified cached catalog is available."
            }
        }
    }

    nonisolated static let healthyInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let startupDelay: TimeInterval = 8
    nonisolated static let failureBackoff: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    @Published private(set) var status: Status = .idle
    @Published private(set) var catalogState: RulePackCatalogState

    var automaticRefresh: Bool { catalogState.update.automaticRefresh }
    var receipt: RulePackCatalogReceipt? { catalogState.receipt }

    private let db: TrafficDatabase
    private let store: RulePackStore
    private let currentAppVersion: String
    private let bundledCatalog: @Sendable () throws -> Data
    private let trustedSigners: [RulePackCatalogTrustedSigner]
    private let injectedTransport: HTTPDataTransport?
    private let now: @Sendable () -> Date
    private let sourceURL = URL(string: RulePackCatalogVerifier.sourceURL)!
    private let productionTransport: BoundedHTTPDataTransport
    private var timer: Timer?
    private var networkingEnabled = false
    private var inFlight = false
    private var requestGeneration = 0
    private var recoveryNeeded = false

    init(db: TrafficDatabase,
         store: RulePackStore,
         currentAppVersion: String,
         bundledCatalog: @escaping @Sendable () throws -> Data,
         transport: HTTPDataTransport? = nil,
         trustedSigners: [RulePackCatalogTrustedSigner] = RulePackCatalogVerifier.productionTrustedSigners,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.store = store
        self.currentAppVersion = currentAppVersion
        self.bundledCatalog = bundledCatalog
        self.injectedTransport = transport
        self.trustedSigners = trustedSigners
        self.now = now
        productionTransport = BoundedHTTPDataTransport(
            allowedOrigin: URL(string: RulePackCatalogVerifier.sourceURL)!,
            maximumBytes: RulePackCatalogVerifier.maximumDataBytes
        )
        catalogState = RulePackCatalogState(
            receipt: nil,
            cache: nil,
            update: RulePackCatalogUpdateState(catalogID: RulePackCatalogVerifier.catalogID)
        )
    }

    deinit { timer?.invalidate() }

    /// Establishes local trust before normal rule-pack state is loaded. It never performs network I/O.
    func bootstrap() async {
        do {
            let bootstrap = try await db.asyncResult {
                try $0.loadRulePackCatalogBootstrap(catalogID: RulePackCatalogVerifier.catalogID)
            }
            catalogState = bootstrap.state

            if let receipt = bootstrap.state.receipt {
                guard let cache = bootstrap.state.cache else {
                    enterRecovery("The accepted official catalog cache is missing.")
                    return
                }
                do {
                    let verified = try verify(
                        cache.rawEnvelope,
                        receipt: receipt,
                        allowExpiredLastKnownGood: true
                    )
                    let composed = try RulePackCatalogComposition.compose(verified)
                    store.installCommittedCatalog(composed, acceptance: bootstrap)
                    recoveryNeeded = false
                    status = verified.stale ? .stale : .current
                } catch {
                    enterRecovery("The accepted official catalog cache could not be verified: \(error)")
                }
                return
            }

            let verified = try verify(try bundledCatalog(), receipt: nil, allowExpiredLastKnownGood: false)
            let composed = try RulePackCatalogComposition.compose(verified)
            let checkedAt = now()
            let acceptance = try await db.asyncResult {
                try $0.acceptVerifiedRulePackCatalog(
                    composed,
                    checkedAt: checkedAt,
                    nextEligibleAt: checkedAt.addingTimeInterval(Self.healthyInterval)
                )
            }
            catalogState = acceptance.state
            store.installCommittedCatalog(composed, acceptance: acceptance)
            recoveryNeeded = false
            status = verified.stale ? .stale : .current
        } catch {
            enterRecovery("The bundled official catalog could not be established: \(error)")
        }
    }

    func startScheduling(networkingEnabled: Bool) {
        self.networkingEnabled = networkingEnabled
        schedule()
    }

    func setAutomaticRefresh(_ enabled: Bool) async {
        do {
            try await db.asyncResult {
                try $0.setRulePackCatalogAutomaticRefresh(
                    catalogID: RulePackCatalogVerifier.catalogID,
                    enabled: enabled
                )
            }
            catalogState = try await db.asyncResult {
                try $0.loadRulePackCatalogState(catalogID: RulePackCatalogVerifier.catalogID)
            }
            schedule()
        } catch {
            status = .failed(String(describing: error), usingLastKnownGood: store.snapshot != nil)
        }
    }

    /// Manual checks bypass the persisted due time, but never any transport, signature, compatibility, or rollback gate.
    func checkNow() async {
        await check(manual: true)
    }

    func checkIfDue() async {
        await check(manual: false)
    }

    private func check(manual: Bool) async {
        guard networkingEnabled, !inFlight else { return }
        let attempt = now()
        if !manual {
            guard catalogState.update.automaticRefresh else { return }
            if let next = catalogState.update.nextEligibleAttempt, next > attempt { schedule(); return }
        }

        inFlight = true
        requestGeneration += 1
        let generation = requestGeneration
        status = .checking
        defer {
            if generation == requestGeneration { inFlight = false; schedule() }
        }

        do {
            let request = makeRequest(useValidators: !recoveryNeeded)
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
                throw UpdateError.invalidResponse
            }
            guard sameOrigin(finalURL) else { throw UpdateError.wrongOrigin }

            switch http.statusCode {
            case 200:
                try validateJSONResponse(http, data: data)
                let prior = catalogState.receipt
                let verified = try verify(data, receipt: prior, allowExpiredLastKnownGood: false)
                let composed = try RulePackCatalogComposition.compose(verified)
                let acceptance = try await db.asyncResult {
                    try $0.acceptVerifiedRulePackCatalog(
                        composed,
                        etag: http.value(forHTTPHeaderField: "ETag"),
                        lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                        checkedAt: attempt,
                        nextEligibleAt: attempt.addingTimeInterval(Self.healthyInterval)
                    )
                }
                guard generation == requestGeneration else { return }
                catalogState = acceptance.state
                store.installCommittedCatalog(composed, acceptance: acceptance)
                recoveryNeeded = false
                status = .current

            case 304:
                guard !recoveryNeeded,
                      let receipt = catalogState.receipt,
                      let cache = catalogState.cache else { throw UpdateError.missingCache }
                let verified = try verify(
                    cache.rawEnvelope,
                    receipt: receipt,
                    allowExpiredLastKnownGood: true
                )
                let composed = try RulePackCatalogComposition.compose(verified)
                try await db.asyncResult {
                    try $0.recordRulePackCatalogNotModified(
                        catalogID: RulePackCatalogVerifier.catalogID,
                        expectedSequence: receipt.sequence,
                        expectedDigest: receipt.digest,
                        checkedAt: attempt,
                        nextEligibleAt: attempt.addingTimeInterval(Self.healthyInterval)
                    )
                }
                guard generation == requestGeneration else { return }
                let acceptance = try await db.asyncResult {
                    try $0.loadRulePackCatalogBootstrap(catalogID: RulePackCatalogVerifier.catalogID)
                }
                catalogState = acceptance.state
                store.installCommittedCatalog(composed, acceptance: acceptance)
                status = verified.stale ? .stale : .current

            default:
                throw UpdateError.badStatus(http.statusCode)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            await recordFailure(error, attemptedAt: attempt)
        }
    }

    private func makeRequest(useValidators: Bool) -> URLRequest {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Flowlight/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if useValidators {
            if let etag = catalogState.cache?.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let modified = catalogState.cache?.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        return request
    }

    private func validateJSONResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard data.count <= RulePackCatalogVerifier.maximumDataBytes else {
            throw UpdateError.responseTooLarge
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let count = Int64(length), count > Int64(RulePackCatalogVerifier.maximumDataBytes) {
            throw UpdateError.responseTooLarge
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime == "application/json" else { throw UpdateError.wrongMIME(mime) }
    }

    private func verify(_ data: Data, receipt: RulePackCatalogReceipt?,
                        allowExpiredLastKnownGood: Bool) throws -> VerifiedRulePackCatalog {
        try RulePackCatalogVerifier.verify(
            data: data,
            trustedSigners: trustedSigners,
            now: Int64(now().timeIntervalSince1970),
            currentAppVersion: currentAppVersion,
            priorSequence: receipt?.sequence,
            priorDigest: receipt?.digest,
            allowExpiredLastKnownGood: allowExpiredLastKnownGood
        )
    }

    private func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let injectedTransport { return try await injectedTransport(request) }
        return try await productionTransport.data(for: request)
    }

    private func recordFailure(_ error: Error, attemptedAt: Date) async {
        let failures = min(catalogState.update.failureCount + 1, Int.max)
        let delay = Self.failureBackoff[min(failures - 1, Self.failureBackoff.count - 1)]
        let failureStatus = recoveryNeeded ? "recovery-failed" : "failed"
        let failureDescription = String(describing: error)
        do {
            try await db.asyncResult {
                try $0.recordRulePackCatalogFailure(
                    catalogID: RulePackCatalogVerifier.catalogID,
                    attemptedAt: attemptedAt,
                    failureCount: failures,
                    nextEligibleAt: attemptedAt.addingTimeInterval(delay),
                    status: failureStatus,
                    error: failureDescription
                )
            }
            catalogState = try await db.asyncResult {
                try $0.loadRulePackCatalogState(catalogID: RulePackCatalogVerifier.catalogID)
            }
        } catch {
            // The catalog and active snapshot remain unchanged if even failure bookkeeping cannot commit.
        }
        status = recoveryNeeded
            ? .recovery(String(describing: error))
            : .failed(String(describing: error), usingLastKnownGood: catalogState.receipt != nil)
    }

    private func enterRecovery(_ message: String) {
        recoveryNeeded = true
        store.enterCatalogRecovery()
        status = .recovery(message)
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard networkingEnabled, catalogState.update.automaticRefresh, !inFlight else { return }
        let delay: TimeInterval
        if let next = catalogState.update.nextEligibleAttempt {
            delay = max(0, next.timeIntervalSince(now()))
        } else {
            delay = Self.startupDelay
        }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func sameOrigin(_ candidate: URL) -> Bool {
        candidate.scheme?.lowercased() == sourceURL.scheme?.lowercased()
            && candidate.host?.lowercased() == sourceURL.host?.lowercased()
            && effectivePort(candidate) == effectivePort(sourceURL)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}
