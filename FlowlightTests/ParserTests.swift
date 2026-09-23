import XCTest
@testable import Flowlight

final class ParserTests: XCTestCase {
    static func clientHello(sni: String) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let name = Array(sni.utf8)
        let serverNameList: [UInt8] = [0x00] + u16(name.count) + name
        let sniExt: [UInt8] = u16(0x0000) + u16(serverNameList.count + 2) + u16(serverNameList.count) + serverNameList
        let otherExt: [UInt8] = u16(0x000A) + u16(4) + u16(2) + u16(0x001D) // supported_groups
        let extensions = otherExt + sniExt
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32)
        body += [0x20] + [UInt8](repeating: 0x01, count: 32)   // session id
        body += u16(4) + [0x13, 0x01, 0x13, 0x02]              // cipher suites
        body += [0x01, 0x00]                                   // compression
        body += u16(extensions.count) + extensions
        let handshake: [UInt8] = [0x01, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
        return Data([0x16, 0x03, 0x01] + u16(handshake.count) + handshake)
    }

    func testSNI() {
        XCTAssertEqual(TLSSNIParser.serverName(in: Self.clientHello(sni: "Example.COM")), "example.com")
        XCTAssertNil(TLSSNIParser.serverName(in: Data("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertNil(TLSSNIParser.serverName(in: Self.clientHello(sni: "example.com").prefix(40)))
    }

    func testHTTPHost() {
        let req = Data("GET /index HTTP/1.1\r\nUser-Agent: x\r\nhost: Api.Example.org:8080\r\n\r\n".utf8)
        XCTAssertEqual(HTTPHostParser.host(in: req), "api.example.org")
        XCTAssertEqual(HTTPHostParser.host(in: Data("GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n".utf8)), "::1")
        XCTAssertNil(HTTPHostParser.host(in: Data("GET / HTTP/1.0\r\n\r\n".utf8)))
    }

    func testDNSResponse() {
        // Response for www.example.com: CNAME → edge.example.net, A 93.184.216.34, AAAA 2606:2800::1
        //
        // Every array here is annotated and appended one at a time. Chaining `+` across bare integer literals
        // reads more compactly but the type checker explores it exponentially: Xcode 16.4 gives up on it.
        func label(_ s: String) -> [UInt8] { [UInt8(s.utf8.count)] + Array(s.utf8) }
        var b: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]
        b += label("www")
        b += label("example")
        b += label("com")
        let terminator: [UInt8] = [0]
        b += terminator
        let question: [UInt8] = [0x00, 0x01, 0x00, 0x01]
        b += question
        var cname: [UInt8] = label("edge")
        cname += label("example")
        cname += label("net")
        cname += terminator
        let cnameHeader: [UInt8] = [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0, 0, 0x0E, 0x10, 0x00, UInt8(cname.count)]
        b += cnameHeader
        b += cname
        let aRecord: [UInt8] = [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0, 0, 0x00, 0x3C, 0x00, 0x04, 93, 184, 216, 34]
        b += aRecord
        let aaaaHeader: [UInt8] = [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0, 0, 0x00, 0x3C, 0x00, 0x10, 0x26, 0x06, 0x28, 0x00]
        b += aaaaHeader
        b += [UInt8](repeating: 0, count: 11)
        b += [UInt8(1)]

        let answer = DNSParser.parseResponse(Data(b))
        XCTAssertEqual(answer?.queriedName, "www.example.com")
        XCTAssertEqual(answer?.addresses, ["93.184.216.34", "2606:2800::1"])
        XCTAssertEqual(answer?.ttl, 60)

        let framed: [UInt8] = [0x00, UInt8(b.count)] + b
        let tcp = DNSParser.parseResponse(Data(framed), tcpFraming: true)
        XCTAssertEqual(tcp?.addresses.count, 2)

        var query = b; query[2] = 0x01 // QR bit cleared → a query, not a response
        XCTAssertNil(DNSParser.parseResponse(Data(query)))
    }

    func testClassifier() {
        let c = ProtocolClassifier.default
        func classify(_ port: UInt16, _ t: TransportProtocol, out: String? = nil, outData: Data? = nil, inbound: String? = nil) -> String {
            c.classify(ClassificationInput(remotePort: port, transport: t, firstOutbound: outData ?? out.map { Data($0.utf8) },
                                           firstInbound: inbound.map { Data($0.utf8) }))
        }
        XCTAssertEqual(classify(443, .tcp, outData: Self.clientHello(sni: "a.com")), "https")
        XCTAssertEqual(classify(8000, .tcp, outData: Self.clientHello(sni: "a.com")), "tls")
        XCTAssertEqual(classify(990, .tcp, outData: Self.clientHello(sni: "a.com")), "ftps")
        XCTAssertEqual(classify(21, .tcp, out: "AUTH TLS\r\n", inbound: "220 ProFTPD ready"), "ftps")
        XCTAssertEqual(classify(21, .tcp, out: "USER anonymous\r\n", inbound: "220 ProFTPD ready"), "ftp")
        XCTAssertEqual(classify(2121, .tcp, inbound: "220 FTP server"), "ftp")
        XCTAssertEqual(classify(25, .tcp, inbound: "220 mx ESMTP"), "smtp")
        XCTAssertEqual(classify(8081, .tcp, out: "POST /x HTTP/1.1\r\n"), "http")
        XCTAssertEqual(classify(2222, .tcp, inbound: "SSH-2.0-OpenSSH_9.6"), "ssh")
        XCTAssertEqual(classify(53, .udp), "dns")
        XCTAssertEqual(classify(443, .udp, outData: Data([0xC3, 0, 0, 0, 1])), "quic")
        XCTAssertEqual(classify(40000, .udp), "udp")
    }

    func testExtendedProtocolCoverage() {
        let c = ProtocolClassifier.default
        func classify(_ port: UInt16, _ t: TransportProtocol = .tcp, out: String? = nil, inbound: String? = nil) -> String {
            c.classify(ClassificationInput(remotePort: port, transport: t, firstOutbound: out.map { Data($0.utf8) },
                                           firstInbound: inbound.map { Data($0.utf8) }))
        }
        // Mail, by greeting or command, on any port
        XCTAssertEqual(classify(1143, inbound: "* OK Dovecot ready"), "imap")
        XCTAssertEqual(classify(1110, inbound: "+OK POP3 ready"), "pop3")
        XCTAssertEqual(classify(587, out: "EHLO laptop\r\n"), "smtp-submission")
        XCTAssertEqual(classify(2525, out: "HELO x\r\n"), "smtp")
        XCTAssertEqual(classify(25), "smtp")
        // Web variants
        XCTAssertEqual(classify(8080, out: "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n"), "websocket")
        XCTAssertEqual(classify(8080, out: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), "http2")
        XCTAssertEqual(c.classify(ClassificationInput(remotePort: 9050, transport: .tcp, firstOutbound: Data([5, 1, 0]), firstInbound: nil)), "tor-socks")
        XCTAssertEqual(c.classify(ClassificationInput(remotePort: 1080, transport: .tcp, firstOutbound: Data([5, 2, 0, 2]), firstInbound: nil)), "socks5")
        // Port tables, both transports
        XCTAssertEqual(classify(5432), "postgres")
        XCTAssertEqual(classify(3389), "rdp")
        XCTAssertEqual(classify(445), "smb")
        XCTAssertEqual(classify(51820, .udp), "wireguard")
        XCTAssertEqual(classify(123, .udp), "ntp")
        XCTAssertEqual(classify(5060, .udp), "sip")
        XCTAssertEqual(classify(636, out: String(decoding: Self.clientHello(sni: "ldap.corp"), as: UTF8.self)), "ldaps")
        // Categories and hostname refinement
        XCTAssertEqual(ProtocolCatalog.category(of: "smtp-submission"), .mail)
        XCTAssertTrue(ProtocolCatalog.category(of: "ssh").isSensitiveEgress)
        XCTAssertTrue(ProtocolCatalog.category(of: "tor-socks").isSensitiveEgress)
        XCTAssertFalse(ProtocolCatalog.category(of: "https").isSensitiveEgress)
        XCTAssertEqual(ProtocolCatalog.refine("https", domain: "dns.google"), "dns-over-https")
        XCTAssertEqual(ProtocolCatalog.refine("https", domain: "example.com"), "https")
        // Every named protocol has a category.
        let named = Set(ProtocolCatalog.tcpPorts.values).union(ProtocolCatalog.udpPorts.values).union(ProtocolCatalog.tlsPorts.values)
        XCTAssertEqual(named.filter { ProtocolCatalog.category(of: $0) == .other }, [])
    }

    func testNettopParser() {
        let parser = NettopParser()
        func sample(_ apsdIn: Int, _ apsdOut: Int, extra: String = "") -> String {
            """
            ,bytes_in,bytes_out,
            apsd.373,\(apsdIn),\(apsdOut),
            tcp4 192.168.1.133:49538<->17.57.144.26:5223,\(apsdIn),\(apsdOut),
            mysqld.495,0,0,
            tcp6 *.3306<->*.*,,,
            mDNSResponder.514,500,100,
            udp4 *:5353<->*:*,500,100,
            \(extra)
            """
        }
        XCTAssertTrue(parser.feed(sample(1000, 200)).isEmpty) // header of first sample
        XCTAssertTrue(parser.feed(sample(1500, 260)).isEmpty) // closes baseline sample
        let extra = "Safari.900,0,0,\ntcp6 fe80::1%en0.50000<->2606:4700::6810:84e5.443,4000,700,\n"
        let thirdSample: String = sample(1800, 300, extra: extra) + "\n,bytes_in,bytes_out,\n"
        let deltas = parser.feed(thirdSample)
        XCTAssertEqual(deltas.count, 2)
        let first = deltas[0]
        let apsd = first.first { $0.pid == 373 }
        XCTAssertEqual(apsd?.counters.bytesIn, 500)
        XCTAssertEqual(apsd?.counters.bytesOut, 60)
        XCTAssertEqual(apsd?.connection.remoteIP, "17.57.144.26")
        XCTAssertEqual(apsd?.connection.remotePort, 5223)
        XCTAssertNil(first.first { $0.pid == 514 }) // unchanged counters produce no delta

        let second = deltas[1]
        let apsd2 = second.first { $0.pid == 373 }
        XCTAssertEqual(apsd2?.counters.bytesIn, 300)
        let safari = second.first { $0.pid == 900 }
        XCTAssertEqual(safari?.connection.remoteIP, "2606:4700::6810:84e5")
        XCTAssertEqual(safari?.connection.remotePort, 443)
        XCTAssertEqual(safari?.counters.bytesIn, 4000)
        XCTAssertEqual(safari?.counters.flows, 1)
    }

    func testNettopOneShotSamples() {
        let parser = NettopParser()
        func run(_ bytes: Int) -> String {
            ",bytes_in,bytes_out,\nsshd.42,\(bytes),0,\ntcp4 10.0.0.2:22<->10.0.0.9:51000,\(bytes),10,\n"
        }
        XCTAssertTrue(parser.feedSample(run(100)).isEmpty, "first run is the baseline")
        XCTAssertEqual(parser.feedSample(run(250)).first?.counters.bytesIn, 150)
        XCTAssertEqual(parser.feedSample(",bytes_in,bytes_out,\n").count, 0, "empty output keeps the baseline")
        let next = parser.feedSample(run(300))
        XCTAssertEqual(next.first?.counters.bytesIn, 50)
        XCTAssertEqual(next.first?.counters.flows, 0)
    }

    func testProcessDisplayName() {
        func name(_ path: String) -> String { ProcessLookup.displayName(fromPathComponents: path.split(separator: "/").map(String.init)) }
        XCTAssertEqual(name("/Users/x/.local/share/claude/versions/2.1.275"), "claude")
        XCTAssertEqual(name("/usr/libexec/rapportd"), "rapportd")
        XCTAssertEqual(name("/opt/homebrew/Cellar/node/22.1.0/bin/node"), "node")
    }

    func testCompactByteFormat() {
        XCTAssertEqual(ByteFormat.compact(0), "0B")
        XCTAssertEqual(ByteFormat.compact(1_234), "1.2K")
        XCTAssertEqual(ByteFormat.compact(830_000), "830K")
        XCTAssertEqual(ByteFormat.compact(12_500_000), "12M")
    }

    func testRegistrableDomain() {
        XCTAssertEqual(AnomalyEngine.registrableDomain("a.b.example.com"), "example.com")
        XCTAssertEqual(AnomalyEngine.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(AnomalyEngine.registrableDomain("example.com"), "example.com")
    }
}

final class NettopWatchdogTests: XCTestCase {
    /// A sample that never finishes (as nettop sometimes does) is killed, reported, and sampling carries on.
    func testHungSampleIsKilledAndReported() {
        let source = NettopTrafficSource()
        source.executable = "/bin/sleep"
        source.arguments = ["30"]
        source.sampleTimeout = 0.5
        let reported = expectation(description: "stall reported")
        var messages: [String] = []
        let lock = NSLock()
        source.start(sink: { _ in }, status: { message in
            lock.lock(); messages.append(message); lock.unlock()
            if message.contains("stopped responding") { reported.fulfill() }
        })
        wait(for: [reported], timeout: 5)
        source.stop()
        XCTAssertTrue(messages.contains { $0.contains("restarted (1×)") })
    }

    /// A quiet second still reaches the app, as an empty delivery.
    func testQuietSampleIsAHeartbeat() {
        let source = NettopTrafficSource()
        source.executable = "/bin/echo"
        source.arguments = ["time,,bytes_in,bytes_out,"]
        let beat = expectation(description: "heartbeat")
        beat.assertForOverFulfill = false
        source.start(sink: { batches in if batches.isEmpty { beat.fulfill() } }, status: { _ in })
        wait(for: [beat], timeout: 5)
        source.stop()
    }
}

final class NettopNamingTests: XCTestCase {
    func testUsesNettopNameWhenLookupFails() {
        XCTAssertEqual(NettopTrafficSource.name(lookedUp: "pid 4244", fromNettop: "codex"), "codex")
        XCTAssertEqual(NettopTrafficSource.name(lookedUp: "", fromNettop: "mysqld"), "mysqld")
        XCTAssertNil(NettopTrafficSource.name(lookedUp: "Claude Code", fromNettop: "claude"), "a real name wins")
        XCTAssertNil(NettopTrafficSource.name(lookedUp: "pid 99", fromNettop: "  "), "nothing useful to fall back to")
    }
}
