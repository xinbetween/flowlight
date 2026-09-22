import Darwin
import Foundation

/// Agents known by name plus those discovered by their LLM API traffic, shared across threads.
final class AgentRegistry: @unchecked Sendable {
    static let shared = AgentRegistry()
    private var discovered: Set<String> = []
    private let lock = NSLock()

    func insert(_ bundleID: String) { lock.lock(); discovered.insert(bundleID); lock.unlock() }
    func insert(contentsOf ids: Set<String>) { lock.lock(); discovered.formUnion(ids); lock.unlock() }

    func isDiscovered(_ bundleID: String) -> Bool { lock.lock(); defer { lock.unlock() }; return discovered.contains(bundleID) }

    /// Display name when the app is an agent.
    func name(bundleID: String, appName: String) -> String? {
        if let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: appName) { return known.name }
        return isDiscovered(bundleID) ? appName : nil
    }
}

/// Reads parent PID and command line for live processes (cached briefly; PIDs are reused over time).
final class SystemProcessTable: @unchecked Sendable {
    static let shared = SystemProcessTable()
    private let lookup = ProcessLookup()
    private var cache: [Int32: (snapshot: ProcessSnapshot, at: Date)] = [:]
    private let lock = NSLock()

    func snapshot(_ pid: Int32) -> ProcessSnapshot? {
        lock.lock()
        if let hit = cache[pid], Date().timeIntervalSince(hit.at) < 30 { lock.unlock(); return hit.snapshot }
        lock.unlock()
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let meta = lookup.info(pid: pid)
        let snapshot = ProcessSnapshot(pid: pid, ppid: info.kp_eproc.e_ppid, bundleID: meta.bundleID, name: meta.name,
                                       argv: Self.arguments(pid: pid))
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[pid] = (snapshot, Date())
        lock.unlock()
        return snapshot
    }

    /// argv from KERN_PROCARGS2: argc, exec path, NUL padding, then argc NUL-terminated strings.
    static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = Int(bytes.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, bytes[i] != 0 { i += 1 }        // exec path
        while i < size, bytes[i] == 0 { i += 1 }        // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

/// Fills in `parentAgent` / `mcpServer` on flow keys before they're stored.
final class AgentAttributor: @unchecked Sendable {
    static let shared = AgentAttributor()
    private var servers: [MCPServerConfig] = []
    private var loadedAt = Date.distantPast
    private var cache: [Int32: (context: AgentContext?, at: Date)] = [:]
    private let lock = NSLock()
    var enabled = true

    var mcpServers: [MCPServerConfig] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(loadedAt) > 300 {   // configs change rarely; re-read every 5 minutes
            servers = MCPConfigReader.load()
            loadedAt = Date()
        }
        return servers
    }

    func enrich(_ batches: [TrafficBatch]) -> [TrafficBatch] {
        guard enabled else { return batches }
        let servers = mcpServers
        return batches.map { batch in
            var batch = batch
            batch.records = batch.records.map { record in
                var record = record
                guard record.key.parentAgent == nil, record.key.pid > 1 else { return record }
                if let context = context(for: record.key, servers: servers) {
                    record.key.parentAgent = context.agentBundleID
                    record.key.parentAgentName = context.agentName
                    record.key.mcpServer = context.mcpServer
                } else if let remote = AgentLineage.remoteServer(forHost: record.key.domain, servers: servers) {
                    record.key.mcpServer = remote.name   // the agent talking to a remote MCP server itself
                }
                return record
            }
            return batch
        }
    }

    private func context(for key: FlowKey, servers: [MCPServerConfig]) -> AgentContext? {
        lock.lock()
        if let hit = cache[key.pid], Date().timeIntervalSince(hit.at) < 30 { lock.unlock(); return hit.context }
        lock.unlock()
        let context = AgentLineage.context(for: key.pid, lookup: SystemProcessTable.shared.snapshot,
                                           agentName: AgentRegistry.shared.name, servers: servers)
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[key.pid] = (context, Date())
        lock.unlock()
        return context
    }
}
