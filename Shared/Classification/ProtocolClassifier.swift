import Foundation

/// Context for classifying a flow from its port and first bytes.
struct ClassificationInput {
    var remotePort: UInt16
    var transport: TransportProtocol
    var firstOutbound: Data?
    var firstInbound: Data?
}

/// A pluggable detector. Return nil when the detector has no opinion.
protocol ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String?
}

struct ProtocolClassifier {
    var detectors: [ProtocolDetector]

    static let `default` = ProtocolClassifier(detectors: [
        DNSDetector(),
        FTPSDetector(),
        TLSDetector(),
        QUICDetector(),
        HTTP2Detector(),
        WebSocketDetector(),
        HTTPDetector(),
        SSHDetector(),
        MailDetector(),
        FTPDetector(),
        SOCKSDetector(),
        PortDetector(),
    ])

    func classify(_ input: ClassificationInput) -> String {
        for detector in detectors {
            if let proto = detector.detect(input) { return proto }
        }
        return input.transport.rawValue
    }
}

// MARK: - Detectors

struct DNSDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        switch input.remotePort {
        case 53: return "dns"
        case 853: return "dns-over-tls"
        case 5353: return "mdns"
        default: return nil
        }
    }
}

/// FTPS: implicit TLS on 990, or explicit `AUTH TLS` on 21.
struct FTPSDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        if input.remotePort == 990, input.firstOutbound?.first == 0x16 { return "ftps" }
        if input.remotePort == 21, let out = input.firstOutbound,
           let text = String(data: out.prefix(512), encoding: .ascii)?.uppercased(),
           text.contains("AUTH TLS") || text.contains("AUTH SSL") {
            return "ftps"
        }
        return nil
    }
}

struct TLSDetector: ProtocolDetector {
    static let tlsPorts = ProtocolCatalog.tlsPorts

    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let out = input.firstOutbound, out.count >= 3 else { return nil }
        let bytes = [UInt8](out.prefix(3))
        guard bytes[0] == 0x16, bytes[1] == 0x03 else { return nil }
        return Self.tlsPorts[input.remotePort] ?? "tls"
    }
}

struct QUICDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .udp, input.remotePort == 443 || input.remotePort == 8443 else { return nil }
        if let first = input.firstOutbound?.first, first & 0xC0 == 0xC0 { return "quic" }
        return input.firstOutbound == nil ? "quic" : nil
    }
}

struct HTTPDetector: ProtocolDetector {
    static let methods = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "]

    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let out = input.firstOutbound,
              let prefix = String(data: out.prefix(8), encoding: .ascii) else { return nil }
        return Self.methods.contains(where: prefix.hasPrefix) ? "http" : nil
    }
}

struct SSHDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        let banner = Data("SSH-".utf8)
        if input.firstInbound?.starts(with: banner) == true || input.firstOutbound?.starts(with: banner) == true {
            return "ssh"
        }
        return nil
    }
}

struct FTPDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let inbound = input.firstInbound,
              inbound.starts(with: Data("220".utf8)) else { return nil }
        // "220" is also the SMTP greeting; tell them apart by port and banner.
        let banner = String(data: inbound.prefix(256), encoding: .ascii)?.uppercased() ?? ""
        if [25, 465, 587].contains(input.remotePort) || banner.contains("SMTP") || banner.contains("ESMTP") { return "smtp" }
        return "ftp"
    }
}

/// HTTP/2 with prior knowledge (cleartext h2c) starts with the connection preface.
struct HTTP2Detector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let out = input.firstOutbound else { return nil }
        return out.starts(with: Data("PRI * HTTP/2.0".utf8)) ? "http2" : nil
    }
}

/// A plain-HTTP request asking to upgrade to WebSocket.
struct WebSocketDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let out = input.firstOutbound, out.starts(with: Data("GET ".utf8)),
              let text = String(data: out.prefix(4096), encoding: .isoLatin1)?.lowercased() else { return nil }
        return text.contains("\r\nupgrade: websocket") ? "websocket" : nil
    }
}

/// Mail protocols by greeting or first command (servers speak first for IMAP/POP3/SMTP).
struct MailDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp else { return nil }
        if let inbound = input.firstInbound {
            if inbound.starts(with: Data("* OK".utf8)) { return "imap" }
            if inbound.starts(with: Data("+OK".utf8)) { return "pop3" }
        }
        if let out = input.firstOutbound, let text = String(data: out.prefix(8), encoding: .ascii)?.uppercased(),
           text.hasPrefix("EHLO ") || text.hasPrefix("HELO ") {
            return input.remotePort == 587 ? "smtp-submission" : "smtp"
        }
        return nil
    }
}

/// SOCKS5 greeting: version 5, method count, then that many method bytes.
struct SOCKSDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        guard input.transport == .tcp, let out = input.firstOutbound, out.count >= 3 else { return nil }
        let b = [UInt8](out.prefix(10))
        guard b[0] == 0x05, b[1] >= 1, b[1] <= 8, out.count == 2 + Int(b[1]) else { return nil }
        return [9050, 9150].contains(input.remotePort) ? "tor-socks" : "socks5"
    }
}

/// Last-resort port heuristics (see `ProtocolCatalog` for the full tables).
struct PortDetector: ProtocolDetector {
    func detect(_ input: ClassificationInput) -> String? {
        ProtocolCatalog.port(input.remotePort, transport: input.transport)
    }
}
