import Foundation

@MainActor
final class AdvisoryCatalogUpdater: ObservableObject {
    enum Status: Equatable, Sendable { case idle, checking, current, stale, recovery(String), failed(String, usingLastKnownGood: Bool) }
    enum UpdateError: Error, Equatable {
        case invalidResponse, wrongOrigin, badStatus(Int), wrongMIME(String), responseTooLarge, missingCache
    }

    nonisolated static let healthyInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let startupDelay: TimeInterval = 8
    nonisolated static let failureBackoff: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    @Published private(set) var status: Status = .idle
    @Published private(set) var catalogState: AdvisoryCatalogState
    var receipt: AdvisoryCatalogReceipt? { catalogState.receipt }
    var advisories: [SecurityAdvisory] { store.advisories }

    private let db: TrafficDatabase
    private let store: AdvisoryStore
    private let bundledCatalog: @Sendable () throws -> Data
    private let trustedSigners: [AdvisoryCatalogTrustedSigner]
    private let injectedTransport: HTTPDataTransport?
    private let now: @Sendable () -> Date
    private let sourceURL = URL(string: AdvisoryCatalogVerifier.sourceURL)!
    private let productionTransport: BoundedHTTPDataTransport
    private var timer: Timer?
    private var networkingEnabled = false
    private var inFlight = false
    private var recoveryNeeded = false

    init(db: TrafficDatabase, store: AdvisoryStore, bundledCatalog: @escaping @Sendable () throws -> Data,
         transport: HTTPDataTransport? = nil,
         trustedSigners: [AdvisoryCatalogTrustedSigner] = AdvisoryCatalogVerifier.productionTrustedSigners,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.store = store; self.bundledCatalog = bundledCatalog
        self.injectedTransport = transport; self.trustedSigners = trustedSigners; self.now = now
        productionTransport = BoundedHTTPDataTransport(allowedOrigin: sourceURL, maximumBytes: AdvisoryCatalogVerifier.maximumDataBytes)
        catalogState = AdvisoryCatalogState(receipt: nil, cache: nil, update: AdvisoryCatalogUpdateState(catalogID: AdvisoryCatalogVerifier.catalogID))
    }

    deinit { timer?.invalidate() }

    func bootstrap() async {
        do {
            let state = try await db.asyncResult { try $0.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID) }
            catalogState = state
            if let receipt = state.receipt {
                guard let cache = state.cache else { throw UpdateError.missingCache }
                let verified = try await verify(cache.rawEnvelope, receipt: receipt, allowExpired: true)
                let checked = self.now()
                let acceptance = try await db.asyncResult { try $0.acceptVerifiedAdvisoryCatalog(verified, checkedAt: checked, nextEligibleAt: checked.addingTimeInterval(Self.healthyInterval)) }
                catalogState = acceptance.state
                store.install(verified, acceptance: acceptance)
                recoveryNeeded = false; status = verified.stale ? .stale : .current
            } else {
                let data = try await Task.detached(priority: .userInitiated) { try self.bundledCatalog() }.value
                let verified = try await verify(data, receipt: nil, allowExpired: false)
                let checked = now()
                let acceptance = try await db.asyncResult { try $0.acceptVerifiedAdvisoryCatalog(verified, checkedAt: checked, nextEligibleAt: checked.addingTimeInterval(Self.healthyInterval)) }
                catalogState = acceptance.state
                store.install(verified, acceptance: acceptance)
                recoveryNeeded = false; status = verified.stale ? .stale : .current
            }
        } catch {
            recoveryNeeded = true; store.enterRecovery(); status = .recovery(String(describing: error))
        }
    }

    func startScheduling(networkingEnabled: Bool) { self.networkingEnabled = networkingEnabled; schedule() }
    func checkNow() async { await check(manual: true) }
    func checkIfDue() async { await check(manual: false) }

    func setAutomaticRefresh(_ enabled: Bool) async {
        do {
            try await db.asyncResult {
                try $0.setAdvisoryCatalogAutomaticRefresh(catalogID: AdvisoryCatalogVerifier.catalogID, enabled: enabled)
            }
            catalogState = try await db.asyncResult {
                try $0.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID)
            }
            networkingEnabled = enabled
            schedule()
        } catch {
            status = .failed(String(describing: error), usingLastKnownGood: catalogState.receipt != nil)
        }
    }

    func clearLocalCatalog() async {
        do {
            try await db.asyncResult { try $0.clearAdvisoryCatalog() }
            catalogState = AdvisoryCatalogState(
                receipt: nil,
                cache: nil,
                update: AdvisoryCatalogUpdateState(catalogID: AdvisoryCatalogVerifier.catalogID)
            )
            recoveryNeeded = true
            status = .recovery("No verified advisory catalog installed")
            store.enterRecovery()
        } catch {
            status = .failed(String(describing: error), usingLastKnownGood: catalogState.receipt != nil)
        }
    }

    private func check(manual: Bool) async {
        // Manual refresh is an explicit user action and remains available when automatic networking is disabled.
        guard (networkingEnabled || manual), !inFlight else { return }
        let attempted = now()
        if !manual {
            guard catalogState.update.automaticRefresh,
                  catalogState.update.nextEligibleAttempt.map({ $0 <= attempted }) ?? true else { schedule(); return }
        }
        inFlight = true; status = .checking
        defer { inFlight = false; schedule() }
        do {
            var request = URLRequest(url: sourceURL); request.httpMethod = "GET"; request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !recoveryNeeded { request.setValue(catalogState.cache?.etag, forHTTPHeaderField: "If-None-Match"); request.setValue(catalogState.cache?.lastModified, forHTTPHeaderField: "If-Modified-Since") }
            let (data, response): (Data, URLResponse)
            if let injectedTransport {
                (data, response) = try await injectedTransport(request)
            } else {
                (data, response) = try await productionTransport.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw UpdateError.invalidResponse }
            guard sameOrigin(finalURL) else { throw UpdateError.wrongOrigin }
            switch http.statusCode {
            case 200:
                guard data.count <= AdvisoryCatalogVerifier.maximumDataBytes else { throw UpdateError.responseTooLarge }
                guard (http.mimeType?.lowercased() ?? "") == "application/json" else { throw UpdateError.wrongMIME(http.mimeType ?? "") }
                let verified = try await verify(data, receipt: catalogState.receipt, allowExpired: false)
                let acceptance = try await db.asyncResult { try $0.acceptVerifiedAdvisoryCatalog(verified, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"), checkedAt: attempted, nextEligibleAt: attempted.addingTimeInterval(Self.healthyInterval)) }
                catalogState = acceptance.state; store.install(verified, acceptance: acceptance); recoveryNeeded = false; status = .current
            case 304:
                guard let receipt = catalogState.receipt, let cache = catalogState.cache, !recoveryNeeded else { throw UpdateError.missingCache }
                let verified = try await verify(cache.rawEnvelope, receipt: receipt, allowExpired: true)
                try await db.asyncResult { try $0.recordAdvisoryCatalogNotModified(catalogID: AdvisoryCatalogVerifier.catalogID, expectedSequence: receipt.sequence, expectedDigest: receipt.digest, checkedAt: attempted, nextEligibleAt: attempted.addingTimeInterval(Self.healthyInterval)) }
                catalogState = try await db.asyncResult { try $0.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID) }
                store.install(verified, acceptance: AdvisoryCatalogAcceptance(state: catalogState, advisories: verified.advisories)); status = verified.stale ? .stale : .current
            default: throw UpdateError.badStatus(http.statusCode)
            }
        } catch is CancellationError {} catch { await recordFailure(error, at: attempted) }
    }

    private func verify(_ data: Data, receipt: AdvisoryCatalogReceipt?, allowExpired: Bool) async throws -> VerifiedAdvisoryCatalog {
        let signers = trustedSigners; let timestamp = Int64(now().timeIntervalSince1970); let priorSequence = receipt?.sequence; let priorDigest = receipt?.digest
        return try await Task.detached(priority: .userInitiated) {
            try AdvisoryCatalogVerifier.verify(data: data, trustedSigners: signers, now: timestamp, priorSequence: priorSequence, priorDigest: priorDigest, allowExpiredLastKnownGood: allowExpired)
        }.value
    }

    private func recordFailure(_ error: Error, at date: Date) async {
        let count = min(catalogState.update.failureCount + 1, Int.max)
        let delay = Self.failureBackoff[min(count - 1, Self.failureBackoff.count - 1)]
        let failureStatus = self.recoveryNeeded ? "recovery-failed" : "failed"
        let failureDescription = String(describing: error)
        try? await db.asyncResult { try $0.recordAdvisoryCatalogFailure(catalogID: AdvisoryCatalogVerifier.catalogID, attemptedAt: date, failureCount: count, nextEligibleAt: date.addingTimeInterval(delay), status: failureStatus, error: failureDescription) }
        catalogState = (try? await db.asyncResult { try $0.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID) }) ?? catalogState
        status = recoveryNeeded ? .recovery(String(describing: error)) : .failed(String(describing: error), usingLastKnownGood: catalogState.receipt != nil)
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard networkingEnabled, catalogState.update.automaticRefresh, !inFlight else { return }
        let delay = max(0.1, catalogState.update.nextEligibleAttempt.map { max(0, $0.timeIntervalSince(now())) } ?? Self.startupDelay)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in Task { @MainActor in await self?.checkIfDue() } }
    }

    private func sameOrigin(_ candidate: URL) -> Bool {
        candidate.scheme?.lowercased() == sourceURL.scheme?.lowercased() && candidate.host?.lowercased() == sourceURL.host?.lowercased() && (candidate.port ?? 443) == (sourceURL.port ?? 443)
    }
}
