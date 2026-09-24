import Darwin
import Foundation
import SystemConfiguration

/// Decodes one captured frame into hostname facts. Pure, so it can be unit tested.
enum PacketDecoder {
    enum Fact: Equatable {
        case dns(DNSParser.Answer)
        case sni(ip: String, name: String)
    }

    static func decode(_ frame: UnsafeRawBufferPointer, linkType: UInt32) -> Fact? {
        let b = frame
        let l: Int
        switch linkType {
        case BPF.DLT_EN10MB: l = 14
        case BPF.DLT_NULL: l = 4
        default: return nil
        }
        guard b.count > l + 20 else { return nil }
        let version = b[l] >> 4
        var proto: UInt8
        var transport: Int
        var dst: String

        if version == 4 {
            let ihl = Int(b[l] & 0x0F) * 4
            guard ihl >= 20, b.count >= l + ihl else { return nil }
            proto = b[l + 9]
            transport = l + ihl
            dst = "\(b[l + 16]).\(b[l + 17]).\(b[l + 18]).\(b[l + 19])"
        } else if version == 6 {
            guard b.count > l + 40 else { return nil }
            proto = b[l + 6]
            transport = l + 40
            dst = DNSParser.formatIPv6(Array(b[(l + 24)..<(l + 40)]))
        } else {
            return nil
        }

        if proto == UInt8(IPPROTO_UDP) {
            guard b.count > transport + 8 else { return nil }
            let srcPort = Int(b[transport]) << 8 | Int(b[transport + 1])
            guard srcPort == 53 else { return nil }
            return DNSParser.parseResponse(Data(b[(transport + 8)...])).map(Fact.dns)
        }
        if proto == UInt8(IPPROTO_TCP) {
            guard b.count > transport + 20 else { return nil }
            let dstPort = Int(b[transport + 2]) << 8 | Int(b[transport + 3])
            let payload = transport + Int(b[transport + 12] >> 4) * 4
            guard dstPort == 443, payload < b.count else { return nil }
            return TLSSNIParser.serverName(in: Data(b[payload...])).map { .sni(ip: dst, name: $0) }
        }
        return nil
    }
}

/// Passive hostname learning from the wire: DNS answers and TLS SNI on the primary interface.
/// Needs read access to /dev/bpf* (see `CaptureAccess`). The kernel filter passes only DNS
/// responses and ClientHellos, so the cost is independent of how much traffic flows.
final class PacketSniffer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case noPermission
        case running(interface: String)
        case failed(String)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var thread: Thread?
    private var generation = 0
    private(set) var packetsSeen = 0
    var onStateChange: (State) -> Void = { _ in }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    /// Opens a BPF device on the primary interface and starts reading on a background thread.
    func start() {
        stop()
        let interface = Self.primaryInterface() ?? "en0"
        switch Self.openDevice() {
        case .failure(let error):
            state = error.isPermission ? .noPermission : .failed(String(cString: strerror(error.code)))
            return
        case .success(let device):
            do {
                let linkType = try Self.configure(device, interface: interface)
                lock.lock()
                fd = device
                generation += 1
                let myGeneration = generation
                lock.unlock()
                let thread = Thread { [weak self] in self?.readLoop(fd: device, linkType: linkType, generation: myGeneration) }
                thread.name = "flowlight.bpf"
                thread.qualityOfService = .utility
                thread.start()
                self.thread = thread
                state = .running(interface: interface)
            } catch {
                close(device)
                state = .failed("\(error)")
            }
        }
    }

    func stop() {
        lock.lock()
        let device = fd
        fd = -1
        generation += 1
        lock.unlock()
        // close() on a BPF descriptor sleeps in the kernel until a reader blocked in read() lets go, which on a
        // quiet interface used to mean minutes. Switching capture source calls this from the main thread, so the
        // whole app hung; the descriptor is closed on another thread and the UI carries on immediately.
        if device >= 0 { DispatchQueue.global(qos: .utility).async { close(device) } }
        if state != .noPermission { state = .stopped }
    }

    /// Reopens if the primary interface changed (e.g. Wi-Fi → Ethernet or a VPN came up).
    func refreshInterface() {
        guard case .running(let current) = state, let primary = Self.primaryInterface(), primary != current else { return }
        start()
    }

    static func hasAccess() -> Bool {
        switch openDevice() {
        case .success(let fd): close(fd); return true
        case .failure: return false
        }
    }

    private func readLoop(fd: Int32, linkType: UInt32, generation myGeneration: Int) {
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, size)
            lock.lock(); let current = generation; lock.unlock()
            guard current == myGeneration else { return }
            // With a read timeout set, 0 means the interval passed with no packets — not that capture ended.
            if n == 0 { continue }
            if n < 0 {
                if errno == EINTR { continue }
                state = .failed(String(cString: strerror(errno)))
                return
            }
            var offset = 0
            while offset + 18 <= n {
                // struct bpf_hdr { timeval32 tstamp; u32 caplen; u32 datalen; u16 hdrlen; }
                let caplen = Int(buffer.load(fromByteOffset: offset + 8, as: UInt32.self))
                let hdrlen = Int(buffer.load(fromByteOffset: offset + 16, as: UInt16.self))
                guard caplen > 0, offset + hdrlen + caplen <= n else { break }
                let frame = UnsafeRawBufferPointer(start: buffer + offset + hdrlen, count: caplen)
                switch PacketDecoder.decode(frame, linkType: linkType) {
                case .dns(let answer): DNSCache.shared.record(answer)
                case .sni(let ip, let name): DNSCache.shared.recordSNI(ip: ip, name: name)
                case nil: break
                }
                packetsSeen += 1
                offset += (hdrlen + caplen + 3) & ~3 // BPF_WORDALIGN
            }
        }
    }

    private struct Errno: Error {
        var code: Int32
        var isPermission: Bool { code == EACCES || code == EPERM }
    }

    private static func openDevice() -> Result<Int32, Errno> {
        var lastError: Int32 = ENOENT
        for index in 0..<64 {
            let fd = open("/dev/bpf\(index)", O_RDONLY)
            if fd >= 0 { return .success(fd) }
            lastError = errno
            if errno == ENOENT { break }
            if errno == EACCES || errno == EPERM { return .failure(Errno(code: errno)) }
            // EBUSY: device in use by another capture, try the next one.
        }
        return .failure(Errno(code: lastError))
    }

    private struct ConfigError: Error, CustomStringConvertible {
        var description: String
    }

    private static func configure(_ fd: Int32, interface: String) throws -> UInt32 {
        var bufferLength: UInt32 = 64 * 1024
        _ = ioctl(fd, BPF.BIOCSBLEN, &bufferLength)

        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { raw in
            for (i, byte) in interface.utf8.prefix(Int(IFNAMSIZ) - 1).enumerated() { raw[i] = byte }
        }
        guard ioctl(fd, BPF.BIOCSETIF, &request) == 0 else {
            throw ConfigError(description: "cannot attach to \(interface): \(String(cString: strerror(errno)))")
        }
        var on: UInt32 = 1
        _ = ioctl(fd, BPF.BIOCIMMEDIATE, &on)
        // Wake the reader once a second even when nothing arrives, so it notices it has been stopped.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = ioctl(fd, BPF.BIOCSRTIMEOUT, &timeout)
        _ = ioctl(fd, BPF.BIOCSSEESENT, &on) // we need outbound ClientHellos

        var linkType: UInt32 = 0
        guard ioctl(fd, BPF.BIOCGDLT, &linkType) == 0 else { throw ConfigError(description: "BIOCGDLT failed") }
        guard var instructions = CaptureFilter.program(linkType: linkType) else {
            throw ConfigError(description: "unsupported link type \(linkType) on \(interface)")
        }
        let result = instructions.withUnsafeMutableBufferPointer { insns -> Int32 in
            var program = bpf_program(bf_len: UInt32(insns.count), bf_insns: insns.baseAddress)
            return ioctl(fd, BPF.BIOCSETF, &program)
        }
        guard result == 0 else { throw ConfigError(description: "BIOCSETF failed: \(String(cString: strerror(errno)))") }
        return linkType
    }

    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Flowlight" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }
}
