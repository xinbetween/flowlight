import Foundation

/// One staged pack upload. Nothing here touches the active matcher: it only validates a bounded sequence of chunks
/// and returns one complete payload after a compare-and-swap check against the active generation.
struct RulePackTransferBuffer {
    enum CommitResult {
        case payload(Data, RulePackTransferHeader)
        case rejected(RulePackApplyResult)
    }

    private(set) var header: RulePackTransferHeader?
    private(set) var chunks: [Int: Data] = [:]
    private(set) var receivedBytes = 0
    let maxBytes: Int
    let maxChunks: Int

    init(maxBytes: Int = 32 * 1_024 * 1_024, maxChunks: Int = 512) {
        self.maxBytes = maxBytes
        self.maxChunks = maxChunks
    }

    mutating func begin(_ candidate: RulePackTransferHeader,
                        active: RulePackHandshake) -> RulePackApplyResult {
        guard candidate.protocolVersion == RulePackSnapshot.protocolVersion,
              candidate.totalBytes > 0, candidate.totalBytes <= maxBytes,
              candidate.chunks > 0, candidate.chunks <= maxChunks else {
            return RulePackApplyResult(status: .incompatible, generation: active.activeGeneration,
                                       activeDigest: active.activeDigest, detail: "Unsupported pack transfer")
        }
        guard candidate.expectedActiveGeneration == active.activeGeneration else {
            return stale(active)
        }
        header = candidate
        chunks.removeAll(keepingCapacity: true)
        receivedBytes = 0
        return RulePackApplyResult(status: .accepted, generation: candidate.generation,
                                   activeDigest: active.activeDigest)
    }

    mutating func append(generation: String, index: Int, payload: Data) -> Bool {
        guard let header, header.generation.uuidString == generation,
              index >= 0, index < header.chunks else { return false }
        if chunks[index] == payload { return true }
        let oldSize = chunks[index]?.count ?? 0
        let projected = receivedBytes - oldSize + payload.count
        guard projected <= header.totalBytes else { return false }
        chunks[index] = payload
        receivedBytes = projected
        return true
    }

    mutating func commit(generation: String, active: RulePackHandshake) -> CommitResult {
        guard let header, header.generation.uuidString == generation,
              chunks.count == header.chunks else {
            reset()
            return .rejected(RulePackApplyResult(status: .invalid, generation: active.activeGeneration,
                                                 activeDigest: active.activeDigest,
                                                 detail: "Incomplete pack transfer"))
        }
        guard header.expectedActiveGeneration == active.activeGeneration else {
            reset()
            return .rejected(stale(active))
        }
        var data = Data()
        data.reserveCapacity(receivedBytes)
        for index in 0..<header.chunks {
            guard let chunk = chunks[index] else {
                reset()
                return .rejected(RulePackApplyResult(status: .invalid, generation: active.activeGeneration,
                                                     activeDigest: active.activeDigest,
                                                     detail: "A pack chunk is missing."))
            }
            data.append(chunk)
        }
        reset()
        guard data.count == header.totalBytes else {
            return .rejected(RulePackApplyResult(status: .invalid, generation: active.activeGeneration,
                                                 activeDigest: active.activeDigest,
                                                 detail: "Pack byte count mismatch"))
        }
        return .payload(data, header)
    }

    mutating func reset() {
        header = nil
        chunks.removeAll(keepingCapacity: true)
        receivedBytes = 0
    }

    private func stale(_ active: RulePackHandshake) -> RulePackApplyResult {
        RulePackApplyResult(status: .stale, generation: active.activeGeneration,
                            activeDigest: active.activeDigest,
                            detail: "The active pack generation changed.")
    }
}
