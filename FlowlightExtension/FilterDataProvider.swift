import Foundation
import Network
import NetworkExtension
import os.log

let extensionLog = Logger(subsystem: FlowlightConstants.extensionBundleIdentifier, category: "filter")

/// Observes every TCP/UDP socket flow: it peeks at the first bytes for classification / domain extraction, then
/// lets the flow pass and relies on statistics reports for byte counts, which keeps the hot path cheap.
///
/// It refuses a connection only when the user has switched an agent's allowlist to blocking, and only from
/// `handleOutboundData` — `flow.remoteHostname` is usually nil when a flow starts, and TLS SNI arrives in the
/// first outbound bytes. Everything else passes exactly as it did before.
final class FilterDataProvider: NEFilterDataProvider {
    private let tracker = FlowTracker()
    private var flushTimer: DispatchSourceTimer?

    /// Set once macOS has asked this provider to start and the settings applied.
    static let filterStarted = OSAllocatedUnfairLock(
        initialState: (running: false, detail: "", generation: UInt64(0))
    )

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        #if APP_STORE
        IPCServer.shared.attach(tracker: tracker)
        IPCServer.shared.startListener()
        #endif
        let anyNetwork = NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                                       protocol: .any, direction: .any)
        let settings = NEFilterSettings(rules: [NEFilterRule(networkRule: anyNetwork, action: .filterData)],
                                        defaultAction: .allow)
        let generation = Self.filterStarted.withLock { state in
            state.generation &+= 1
            state.running = false
            state.detail = ""
            return state.generation
        }
        #if APP_STORE
        tracker.filterStarted(generation: generation)
        #endif
        apply(settings) { [weak self] error in
            if let error {
                extensionLog.error("apply(settings) failed: \(error.localizedDescription, privacy: .public)")
                let current = Self.filterStarted.withLock { state -> Bool in
                    guard state.generation == generation else { return false }
                    state.running = false
                    state.detail = error.localizedDescription
                    return true
                }
                #if APP_STORE
                if current { self?.tracker.filterStopped() }
                #endif
            } else {
                let current = Self.filterStarted.withLock { state -> Bool in
                    guard state.generation == generation else { return false }
                    state.running = true
                    state.detail = ""
                    return true
                }
                if current {
                    extensionLog.info("Filter started")
                    self?.startFlushing()
                }
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        extensionLog.info("Filter stopped: \(reason.rawValue)")
        flushTimer?.cancel()
        flushTimer = nil
        let batches = tracker.aggregator.drain(before: .max)
        if !batches.isEmpty { IPCServer.shared.send(batches) }
        Self.filterStarted.withLock { state in
            state.generation &+= 1
            state.running = false
            state.detail = ""
        }
        #if APP_STORE
        tracker.filterStopped()
        #endif
        completionHandler()
    }

    private func startFlushing() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        var lastReport = Date.distantPast
        timer.setEventHandler { [tracker] in
            let now = Int64(Date().timeIntervalSince1970)
            let batches = tracker.aggregator.drain(before: now)
            if !batches.isEmpty { IPCServer.shared.send(batches) }
            tracker.sweepStale()
            // A minute's summary, so "the filter is connected but nothing arrives" can be told apart from
            // "macOS isn't handing this filter any flows at all". Counts only — no hosts, no addresses.
            if Date().timeIntervalSince(lastReport) >= 60 {
                lastReport = Date()
                extensionLog.info("""
                    last minute: \(tracker.flowsSeen, privacy: .public) flows seen, \
                    \(tracker.reportsSeen, privacy: .public) statistics reports, \
                    \(batches.count, privacy: .public) batches sent
                    """)
                tracker.resetCounters()
            }
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: Flow callbacks

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow, let state = tracker.begin(socketFlow) else {
            return .allow()
        }
        let verdict = NEFilterNewFlowVerdict.filterDataVerdict(
            withFilterInbound: true, peekInboundBytes: state.inboundPeek,
            filterOutbound: true, peekOutboundBytes: state.outboundPeek)
        verdict.statisticsReportFrequency = .high
        return verdict
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        guard let state = tracker.state(for: flow) else { return .allow() }
        state.observeOutbound(readBytes)
        // The host is known by now, or never will be — either way this is where the flow can still be refused.
        if BlockEnforcer.shared.refuses(state) { return .drop() }
        return verdict(for: state, passing: readBytes.count, peek: state.outboundPeek)
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        guard let state = tracker.state(for: flow) else { return .allow() }
        state.observeInbound(readBytes)
        // The last place an unjudged flow can still be refused: the name may have arrived from passive DNS after
        // the connection opened, in which case the outbound side never got a second chance to ask.
        if BlockEnforcer.shared.refuses(state) { return .drop() }
        return verdict(for: state, passing: readBytes.count, peek: state.inboundPeek)
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { .allow() }
    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { .allow() }

    private func verdict(for state: FlowState, passing count: Int, peek: Int) -> NEFilterDataVerdict {
        state.inspectionDone ? .allow() : NEFilterDataVerdict(passBytes: count, peekBytes: peek)
    }

    // MARK: Statistics

    override func handle(_ report: NEFilterReport) {
        guard let flow = report.flow else { return }
        switch report.event {
        case .statistics, .flowClosed:
            tracker.account(flow: flow, bytesIn: Int64(report.bytesInboundCount), bytesOut: Int64(report.bytesOutboundCount),
                            closed: report.event == .flowClosed)
        default:
            break
        }
    }
}
