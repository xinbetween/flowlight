import Foundation

/// Broad families of network communication, used for reporting and for agent rules.
enum ProtocolCategory: String, CaseIterable, Codable, Sendable {
    case web, mail, fileTransfer, remoteAccess, nameResolution, tunnel, database, messaging, media,
         push, networkServices, peerToPeer, developer, other

    var title: String {
        switch self {
        case .web: return "Web"
        case .mail: return "Email"
        case .fileTransfer: return "File transfer"
        case .remoteAccess: return "Remote access"
        case .nameResolution: return "Name resolution"
        case .tunnel: return "VPN, proxy & tunnels"
        case .database: return "Databases & caches"
        case .messaging: return "Messaging & queues"
        case .media: return "Voice, video & streaming"
        case .push: return "Push notifications"
        case .networkServices: return "Network services"
        case .peerToPeer: return "Peer-to-peer"
        case .developer: return "Developer services"
        case .other: return "Other"
        }
    }

    /// Channels that can carry data out of the machine outside ordinary web APIs. An AI agent
    /// using one of these deserves a look.
    var isSensitiveEgress: Bool {
        switch self {
        case .mail, .fileTransfer, .remoteAccess, .tunnel, .peerToPeer, .database: return true
        default: return false
        }
    }
}

/// Port → protocol tables and protocol → category, for everything Flowlight can name.
/// Flowlight observes every TCP and UDP flow (the transports nearly all app traffic uses);
/// content detectors refine the port guess where the first bytes are recognizable.
enum ProtocolCatalog {
    static let tcpPorts: [UInt16: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 43: "whois", 53: "dns", 79: "finger", 80: "http",
        88: "kerberos", 110: "pop3", 111: "rpcbind", 119: "nntp", 135: "msrpc", 139: "netbios-ssn", 143: "imap", 179: "bgp",
        389: "ldap", 443: "https", 445: "smb", 465: "smtps", 515: "lpd", 548: "afp", 554: "rtsp", 563: "nntps",
        587: "smtp-submission", 631: "ipp", 636: "ldaps", 853: "dns-over-tls", 873: "rsync", 989: "ftps-data", 990: "ftps",
        992: "telnets", 993: "imaps", 995: "pop3s", 1080: "socks", 1194: "openvpn", 1433: "mssql", 1521: "oracle",
        1723: "pptp", 1883: "mqtt", 2049: "nfs", 2375: "docker", 2376: "docker-tls", 2525: "smtp-alt", 3128: "http-proxy",
        3268: "ldap-gc", 3306: "mysql", 3389: "rdp", 3690: "svn", 4222: "nats", 5222: "xmpp", 5223: "apns", 5228: "fcm",
        5269: "xmpp-server", 5432: "postgres", 5671: "amqps", 5672: "amqp", 5900: "vnc", 5938: "teamviewer",
        6379: "redis", 6443: "kubernetes", 6667: "irc", 6697: "ircs", 6881: "bittorrent", 8000: "http-alt",
        8080: "http-alt", 8443: "https-alt", 8883: "mqtts", 8888: "http-alt", 9001: "tor", 9030: "tor-dir", 9042: "cassandra",
        9050: "tor-socks", 9092: "kafka", 9150: "tor-socks", 9200: "elasticsearch", 9418: "git", 11211: "memcached",
        11434: "ollama", 27017: "mongodb",
    ]

    static let udpPorts: [UInt16: String] = [
        53: "dns", 67: "dhcp", 68: "dhcp", 69: "tftp", 123: "ntp", 137: "netbios-ns", 138: "netbios-dgm", 161: "snmp",
        162: "snmp-trap", 443: "quic", 500: "ipsec", 514: "syslog", 546: "dhcpv6", 547: "dhcpv6", 853: "dns-over-quic",
        1194: "openvpn", 1701: "l2tp", 1900: "ssdp", 3478: "stun", 3479: "stun", 3480: "stun", 3481: "stun", 3544: "teredo",
        4500: "ipsec-nat-t", 5060: "sip", 5353: "mdns", 5355: "llmnr", 6881: "bittorrent", 8801: "zoom-media",
        19302: "stun", 41641: "tailscale", 51820: "wireguard",
    ]

    /// Ports served over TLS, named by what runs inside.
    static let tlsPorts: [UInt16: String] = [
        443: "https", 8443: "https-alt", 993: "imaps", 995: "pop3s", 465: "smtps", 990: "ftps", 636: "ldaps", 853: "dns-over-tls",
        5061: "sips", 5223: "apns", 5671: "amqps", 6697: "ircs", 8883: "mqtts", 2376: "docker-tls", 6443: "kubernetes",
    ]

    static let categories: [String: ProtocolCategory] = {
        var map: [String: ProtocolCategory] = [:]
        func set(_ c: ProtocolCategory, _ names: String...) { names.forEach { map[$0] = c } }
        set(.web, "http", "https", "http-alt", "https-alt", "http2", "websocket", "quic", "tls", "http-proxy")
        set(.mail, "smtp", "smtps", "smtp-submission", "smtp-alt", "imap", "imaps", "pop3", "pop3s")
        set(.fileTransfer, "ftp", "ftp-data", "ftps", "ftps-data", "tftp", "sftp", "rsync", "smb", "afp", "nfs", "svn", "git")
        set(.remoteAccess, "ssh", "telnet", "telnets", "rdp", "vnc", "teamviewer")
        set(.nameResolution, "dns", "dns-over-tls", "dns-over-https", "dns-over-quic", "mdns", "llmnr", "netbios-ns", "whois")
        set(.tunnel, "openvpn", "wireguard", "ipsec", "ipsec-nat-t", "l2tp", "pptp", "socks", "socks5", "tor", "tor-dir",
            "tor-socks", "tailscale", "teredo")
        set(.database, "mysql", "postgres", "mssql", "oracle", "redis", "mongodb", "cassandra", "elasticsearch", "memcached")
        set(.messaging, "xmpp", "xmpp-server", "irc", "ircs", "mqtt", "mqtts", "amqp", "amqps", "kafka", "nats", "nntp", "nntps")
        set(.media, "rtsp", "sip", "sips", "stun", "zoom-media")
        set(.push, "apns", "fcm")
        set(.networkServices, "ntp", "dhcp", "dhcpv6", "snmp", "snmp-trap", "syslog", "ssdp", "netbios-ssn", "netbios-dgm",
            "kerberos", "ldap", "ldaps", "ldap-gc", "ipp", "lpd", "msrpc", "rpcbind", "bgp", "finger")
        set(.peerToPeer, "bittorrent")
        set(.developer, "docker", "docker-tls", "kubernetes", "ollama")
        return map
    }()

    static func category(of name: String) -> ProtocolCategory {
        categories[name.lowercased()] ?? .other
    }

    static func port(_ port: UInt16, transport: TransportProtocol) -> String? {
        transport == .tcp ? tcpPorts[port] : udpPorts[port]
    }

    /// Well-known DNS-over-HTTPS resolvers: HTTPS to these is name resolution, not browsing.
    static let dohResolvers: Set<String> = [
        "dns.google", "dns.google.com", "cloudflare-dns.com", "mozilla.cloudflare-dns.com", "one.one.one.one",
        "dns.quad9.net", "dns.nextdns.io", "doh.opendns.com", "dns.adguard-dns.com", "doh.cleanbrowsing.org",
    ]

    /// Uses the destination hostname to sharpen a port/content guess.
    static func refine(_ proto: String, domain: String) -> String {
        guard !domain.isEmpty else { return proto }
        if proto == "https" || proto == "tls", dohResolvers.contains(domain.lowercased()) { return "dns-over-https" }
        return proto
    }
}
