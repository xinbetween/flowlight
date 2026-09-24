import Foundation

/// Which way the bytes actually left the Mac.
///
/// Until now every flow was treated as *the network*, which quietly lumped three different things together: traffic
/// that went to the internet, traffic that never left the machine, and traffic that went straight to a device in the
/// room over peer-to-peer Wi-Fi. The last of those is how AirDrop, Handoff, AirPlay, Sidecar and Universal Control
/// work, and it is the one nobody could see — an AirDrop of a 4 GB folder looked, in Reports, like a few megabytes
/// to an address with no name.
///
/// None of this is newly recorded. Flowlight has always counted these flows; it just had no word for them.
enum NetworkChannel: String, Codable, Sendable, CaseIterable {
    /// The ordinary case: out through Wi-Fi or Ethernet to somewhere else.
    case ip = ""
    /// Apple Wireless Direct Link and its low-latency sibling — a radio link straight to a nearby device, with no
    /// router, no internet and no address anyone else can reach.
    case peerToPeer = "p2p"
    /// It never left the Mac.
    case loopback = "lo"
    /// Inside a VPN or another tunnel. Where it went after that is the tunnel's business, not Flowlight's.
    case tunnel = "tun"

    var title: String {
        switch self {
        case .ip: return "Network"
        case .peerToPeer: return "Peer-to-peer Wi-Fi"
        case .loopback: return "This Mac"
        case .tunnel: return "Tunnel"
        }
    }

    var detail: String {
        switch self {
        case .ip: return "Out through Wi-Fi or Ethernet."
        case .peerToPeer: return "Straight to a device nearby over AWDL — AirDrop, Handoff, AirPlay, Sidecar, Universal Control."
        case .loopback: return "Between processes on this Mac. It never touched a network."
        case .tunnel: return "Through a VPN or another tunnel; where it went after that isn't visible here."
        }
    }

    var icon: String {
        switch self {
        case .ip: return "globe"
        case .peerToPeer: return "wave.3.right"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .tunnel: return "shield.lefthalf.filled"
        }
    }

    /// From the interface a flow was bound to, which is what `nettop` reports per socket.
    ///
    /// `awdl0` is Apple Wireless Direct Link; `llw0` is the low-latency link that rides the same radio and carries
    /// Continuity. `ap1` is the hotspot interface. Everything else is judged on its prefix, because interface
    /// numbering is not fixed: a Mac can have `en0` through `en6`, and several `utun`s.
    static func of(interface: String) -> NetworkChannel {
        let name = interface.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return .ip }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") { return .peerToPeer }
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("gif")
            || name.hasPrefix("stf") { return .tunnel }
        return .ip
    }

    /// From the address alone, for the Network Extension — which sees sockets rather than interfaces and so can
    /// only tell these apart by where they point. It is the coarser answer of the two and knows it: a link-local
    /// address is how peer-to-peer traffic is addressed, but a Mac can also reach a printer that way over Ethernet.
    static func of(address ip: String) -> NetworkChannel {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let o = withUnsafeBytes(of: &v4) { Array($0) }
            if o[0] == 127 { return .loopback }
            return o[0] == 169 && o[1] == 254 ? .peerToPeer : .ip
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return .ip }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }
        return b[0] == 0xfe && (b[1] & 0xc0) == 0x80 ? .peerToPeer : .ip
    }
}

/// What a peer-to-peer flow is actually doing, from the process that opened it.
///
/// There is no hostname on this channel and no port worth reading — the addresses are link-local and the ports are
/// ephemeral — so the process is the only thing that says what happened. These are the macOS daemons that own each
/// feature; an app that uses the radio directly keeps its own name, which is the truthful answer for it.
enum PeerToPeerService {
    private static let services: [(process: String, name: String)] = [
        ("sharingd", "AirDrop and Handoff"),
        ("rapportd", "Continuity"),
        ("identityservicesd", "Continuity (Messages and FaceTime)"),
        ("AirPlayXPCHelper", "AirPlay"),
        ("airplayd", "AirPlay"),
        ("AirPlayUIAgent", "AirPlay"),
        ("sidecar-relay", "Sidecar"),
        ("SidecarRelay", "Sidecar"),
        ("wifip2pd", "Peer-to-peer Wi-Fi setup"),
        ("mDNSResponder", "Service discovery (Bonjour)"),
        ("nearbyd", "Nearby devices"),
        ("bluetoothd", "Bluetooth pairing and handoff"),
        ("searchpartyd", "Find My"),
        ("remoted", "Device pairing"),
        ("UniversalControl", "Universal Control"),
    ]

    /// The feature behind a peer-to-peer flow, or nil when the process is the answer in itself.
    static func name(forProcess process: String) -> String? {
        let name = process.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return services.first { $0.process.caseInsensitiveCompare(name) == .orderedSame }?.name
    }

    /// How a peer-to-peer flow should read where a hostname would normally go. A device in the room has no name
    /// Flowlight can learn, so saying which feature reached it is more use than the link-local address.
    static func destination(forProcess process: String) -> String {
        name(forProcess: process).map { "\($0) · nearby device" } ?? "Nearby device"
    }
}
