import AppKit
import Darwin
import Foundation

/// pid → (bundle id, display name, path) for the fallback sampler.
final class ProcessLookup: @unchecked Sendable {
    struct Info { var bundleID: String; var name: String; var path: String }

    private static let genericDirectories: Set<String> = ["bin", "sbin", "libexec", "versions", "current", "latest", "lib", "share", "local", "macos"]

    /// Reads the exec path from `KERN_PROCARGS2` (layout: argc, exec path, NUL padding, argv…).
    static func execPathFromArguments(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = bytes[start..<size].firstIndex(of: 0), end > start else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Picks a readable name for a bare executable. Versioned installs such as
    /// `~/.local/share/claude/versions/2.1.0` are named after the tool (`claude`), not the version.
    static func displayName(fromPathComponents components: [String]) -> String {
        for component in components.reversed() {
            let lower = component.lowercased()
            if component.contains(where: \.isLetter), !genericDirectories.contains(lower), !lower.hasPrefix(".") {
                return component
            }
        }
        return ""
    }
    private var cache: [Int32: (info: Info, at: Date)] = [:]
    private let lock = NSLock()

    func info(pid: Int32) -> Info {
        lock.lock()
        if let hit = cache[pid], Date().timeIntervalSince(hit.at) < 300 { lock.unlock(); return hit.info }
        lock.unlock()

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        // proc_pidpath fails once the executable is deleted (e.g. replaced by an update);
        // the exec path recorded in the process arguments survives.
        let path = length > 0 ? String(cString: buffer) : (Self.execPathFromArguments(pid: pid) ?? "")
        var info: Info
        let components = path.split(separator: "/")
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = "/" + components[...appIndex].joined(separator: "/")
            let name = String(components[appIndex].dropLast(4))
            info = Info(bundleID: Bundle(path: appPath)?.bundleIdentifier ?? name, name: name, path: path)
        } else if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier {
            info = Info(bundleID: id, name: app.localizedName ?? id, path: path)
        } else {
            var name = Self.displayName(fromPathComponents: components.map(String.init))
            if name.isEmpty {
                var nameBuf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                name = String(cString: nameBuf)
            }
            if name.isEmpty { name = "pid \(pid)" }
            info = Info(bundleID: name, name: name, path: path)
        }
        lock.lock(); cache[pid] = (info, Date()); lock.unlock()
        return info
    }
}

/// Last-resort domain source: asynchronous reverse DNS with a cache. Slow and often wrong,
/// so it is only used when no SNI / Host / DNS mapping is available.
final class ReverseDNS: @unchecked Sendable {
    static let shared = ReverseDNS()
    private var cache: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "flowlight.rdns", attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 4)

    func name(for ip: String) -> String? {
        lock.lock()
        if let hit = cache[ip] { lock.unlock(); return hit.isEmpty ? nil : hit }
        let shouldResolve = inFlight.insert(ip).inserted
        lock.unlock()
        if shouldResolve { resolve(ip) }
        return nil
    }

    private func resolve(_ ip: String) {
        queue.async {
            self.limiter.wait(); defer { self.limiter.signal() }
            let name = Self.lookup(ip) ?? ""
            self.lock.lock()
            self.cache[ip] = name
            self.inFlight.remove(ip)
            self.lock.unlock()
        }
    }

    private static func lookup(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = String(cString: host).lowercased()
        return name == ip ? nil : name
    }
}
