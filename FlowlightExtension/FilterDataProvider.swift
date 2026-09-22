import Foundation
import Network
import NetworkExtension
import os.log

let extensionLog = Logger(subsystem: FlowlightConstants.extensionBundleIdentifier, category: "filter")

/// Observes every TCP/UDP socket flow. It never blocks traffic: it peeks at the first bytes for
/// classification / domain extraction, then lets the flow pass and relies on statistics reports
/// for byte counts, which keeps the hot path cheap.
final class FilterDataProvider: NEFilterDataProvider {
    private let tracker = FlowTracker()
    private var flushTimer: DispatchSourceTimer?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let anyNetwork = NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                                       protocol: .any, direction: .any)
        let settings = NEFilterSettings(rules: [NEFilterRule(networkRule: anyNetwork, action: .filterData)],
                                        defaultAction: .allow)
        apply(settings) { [weak self] error in
            if let error {
                extensionLog.error("apply(settings) failed: \(error.localizedDescription, privacy: .public)")
            } else {
                extensionLog.info("Filter started")
                self?.startFlushing()
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        extensionLog.info("Filter stopped: \(reason.rawValue)")
        flushTimer?.cancel()
        flushTimer = nil
        completionHandler()
    }

    private func startFlushing() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [tracker] in
            let now = Int64(Date().timeIntervalSince1970)
            let batches = tracker.aggregator.drain(before: now)
            if !batches.isEmpty { IPCServer.shared.send(batches) }
            tracker.sweepStale()
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
        return verdict(for: state, passing: readBytes.count, peek: state.outboundPeek)
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        guard let state = tracker.state(for: flow) else { return .allow() }
        state.observeInbound(readBytes)
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
