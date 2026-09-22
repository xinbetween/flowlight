import Darwin
import XCTest
@testable import Flowlight

/// Minimal classic-BPF interpreter covering the opcodes CaptureFilter uses.
private func runBPF(_ program: [bpf_insn], _ packet: [UInt8]) -> UInt32 {
    var a: UInt32 = 0, x: UInt32 = 0, pc = 0
    func load(_ offset: Int, _ size: Int) -> UInt32? {
        guard offset >= 0, offset + size <= packet.count else { return nil }
        return packet[offset..<(offset + size)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    while pc < program.count {
        let i = program[pc]
        let k = i.k
        switch i.code {
        case BPF.LD | BPF.W | BPF.ABS: guard let v = load(Int(k), 4) else { return 0 }; a = v
        case BPF.LD | BPF.H | BPF.ABS: guard let v = load(Int(k), 2) else { return 0 }; a = v
        case BPF.LD | BPF.B | BPF.ABS: guard let v = load(Int(k), 1) else { return 0 }; a = v
        case BPF.LD | BPF.H | BPF.IND: guard let v = load(Int(x) + Int(k), 2) else { return 0 }; a = v
        case BPF.LD | BPF.B | BPF.IND: guard let v = load(Int(x) + Int(k), 1) else { return 0 }; a = v
        case BPF.LDX | BPF.B | BPF.MSH: guard let v = load(Int(k), 1) else { return 0 }; x = (v & 0x0F) * 4
        case BPF.ALU | BPF.RSH | BPF.K: a >>= k
        case BPF.ALU | BPF.LSH | BPF.K: a <<= k
        case BPF.ALU | BPF.ADD | BPF.X: a = a &+ x
        case BPF.MISC | BPF.TAX: x = a
        case BPF.JMP | BPF.JEQ | BPF.K: pc += a == k ? Int(i.jt) : Int(i.jf)
        case BPF.JMP | BPF.JSET | BPF.K: pc += a & k != 0 ? Int(i.jt) : Int(i.jf)
        case BPF.RET | BPF.K: return k
        default: XCTFail("unsupported opcode \(i.code)"); return 0
        }
        pc += 1
    }
    return 0
}

private func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

private func dnsResponse() -> [UInt8] {
    var b: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
    b += [3] + Array("api".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0] + [0x00, 0x01, 0x00, 0x01]
    b += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0, 0, 0x01, 0x2C, 0x00, 0x04, 93, 184, 216, 34]
    return b
}

private func ipv4(proto: UInt8, src: [UInt8], dst: [UInt8], transport: [UInt8], fragment: Int = 0) -> [UInt8] {
    [0x45, 0x00] + u16(20 + transport.count) + [0x00, 0x01] + u16(fragment) + [64, proto, 0, 0] + src + dst + transport
}

private func ipv6(next: UInt8, dst: [UInt8], transport: [UInt8]) -> [UInt8] {
    [0x60, 0, 0, 0] + u16(transport.count) + [next, 64] + [UInt8](repeating: 0x11, count: 16) + dst + transport
}

private func udp(src: Int, dst: Int, _ payload: [UInt8]) -> [UInt8] { u16(src) + u16(dst) + u16(8 + payload.count) + [0, 0] + payload }
private func tcp(src: Int, dst: Int, _ payload: [UInt8]) -> [UInt8] {
    u16(src) + u16(dst) + [0, 0, 0, 1, 0, 0, 0, 0] + [0x50, 0x18] + [0xFF, 0xFF, 0, 0, 0, 0] + payload
}

private func ethernet(_ type: Int, _ ip: [UInt8]) -> [UInt8] { [UInt8](repeating: 0xAA, count: 12) + u16(type) + ip }
private func loopback(_ family: Int32, _ ip: [UInt8]) -> [UInt8] {
    withUnsafeBytes(of: UInt32(family).littleEndian) { Array($0) } + ip
}

final class EnrichmentTests: XCTestCase {
    let hello = [UInt8](ParserTests.clientHello(sni: "chat.example.org"))

    func testFilterAcceptsOnlyDNSAndClientHellos() {
        let prog = CaptureFilter.program(linkType: BPF.DLT_EN10MB)!
        let dns4 = ethernet(0x0800, ipv4(proto: 17, src: [1, 1, 1, 1], dst: [192, 168, 1, 2], transport: udp(src: 53, dst: 5000, dnsResponse())))
        let hello4 = ethernet(0x0800, ipv4(proto: 6, src: [192, 168, 1, 2], dst: [104, 18, 0, 1], transport: tcp(src: 5000, dst: 443, hello)))
        let data4 = ethernet(0x0800, ipv4(proto: 6, src: [192, 168, 1, 2], dst: [104, 18, 0, 1], transport: tcp(src: 5000, dst: 443, [0x17, 3, 3, 0, 5, 1, 2, 3, 4, 5])))
        let ack4 = ethernet(0x0800, ipv4(proto: 6, src: [192, 168, 1, 2], dst: [104, 18, 0, 1], transport: tcp(src: 5000, dst: 443, [])))
        let query4 = ethernet(0x0800, ipv4(proto: 17, src: [192, 168, 1, 2], dst: [1, 1, 1, 1], transport: udp(src: 5000, dst: 53, [1, 2, 3])))
        let fragment = ethernet(0x0800, ipv4(proto: 17, src: [1, 1, 1, 1], dst: [192, 168, 1, 2], transport: udp(src: 53, dst: 5000, dnsResponse()), fragment: 0x0010))
        let dst6 = [UInt8]([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1])
        let hello6 = ethernet(0x86DD, ipv6(next: 6, dst: dst6, transport: tcp(src: 5000, dst: 443, hello)))
        let dns6 = ethernet(0x86DD, ipv6(next: 17, dst: dst6, transport: udp(src: 53, dst: 5000, dnsResponse())))
        let arp = ethernet(0x0806, [UInt8](repeating: 0, count: 28))

        XCTAssertEqual(runBPF(prog, dns4), CaptureFilter.snapLength)
        XCTAssertEqual(runBPF(prog, hello4), CaptureFilter.snapLength)
        XCTAssertEqual(runBPF(prog, hello6), CaptureFilter.snapLength)
        XCTAssertEqual(runBPF(prog, dns6), CaptureFilter.snapLength)
        XCTAssertEqual(runBPF(prog, data4), 0, "application data is dropped in the kernel")
        XCTAssertEqual(runBPF(prog, ack4), 0, "empty segments are dropped")
        XCTAssertEqual(runBPF(prog, query4), 0, "outgoing queries are not needed")
        XCTAssertEqual(runBPF(prog, fragment), 0)
        XCTAssertEqual(runBPF(prog, arp), 0)

        let nullProg = CaptureFilter.program(linkType: BPF.DLT_NULL)!
        XCTAssertEqual(runBPF(nullProg, loopback(AF_INET, ipv4(proto: 6, src: [10, 0, 0, 2], dst: [104, 18, 0, 1], transport: tcp(src: 1, dst: 443, hello)))), CaptureFilter.snapLength)
        XCTAssertEqual(runBPF(nullProg, loopback(AF_INET6, ipv6(next: 17, dst: dst6, transport: udp(src: 53, dst: 9, dnsResponse())))), CaptureFilter.snapLength)
        XCTAssertNil(CaptureFilter.program(linkType: 999))
    }

    func testDecoderExtractsFacts() {
        func decode(_ frame: [UInt8], _ dlt: UInt32 = BPF.DLT_EN10MB) -> PacketDecoder.Fact? {
            frame.withUnsafeBytes { PacketDecoder.decode($0, linkType: dlt) }
        }
        let dns = decode(ethernet(0x0800, ipv4(proto: 17, src: [1, 1, 1, 1], dst: [192, 168, 1, 2], transport: udp(src: 53, dst: 5000, dnsResponse()))))
        XCTAssertEqual(dns, .dns(DNSParser.Answer(queriedName: "api.example.com", addresses: ["93.184.216.34"], ttl: 300)))

        let sni4 = decode(ethernet(0x0800, ipv4(proto: 6, src: [192, 168, 1, 2], dst: [104, 18, 0, 1], transport: tcp(src: 5000, dst: 443, hello))))
        XCTAssertEqual(sni4, .sni(ip: "104.18.0.1", name: "chat.example.org"))

        let dst6 = [UInt8]([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1])
        let sni6 = decode(loopback(AF_INET6, ipv6(next: 6, dst: dst6, transport: tcp(src: 5000, dst: 443, hello))), BPF.DLT_NULL)
        XCTAssertEqual(sni6, .sni(ip: "2606:4700::1", name: "chat.example.org"))
    }

    func testTruncatedClientHelloStillYieldsSNI() {
        // Pad a hello with a large key share before SNI, then cut it at a typical MSS.
        var big = [UInt8](ParserTests.clientHello(sni: "big.example.net"))
        XCTAssertEqual(TLSSNIParser.serverName(in: Data(big)), "big.example.net")
        big += [UInt8](repeating: 0x42, count: 2000)
        let truncated = Data(big.prefix(1448))
        XCTAssertEqual(TLSSNIParser.serverName(in: truncated), "big.example.net")
        XCTAssertNil(TLSSNIParser.scanForServerName(in: Data([0x16, 3, 1] + [UInt8](repeating: 0, count: 200))))
    }

    func testOwnerNamesAndQueries() {
        XCTAssertEqual(IPOwner.displayName(fromASDescription: " CLOUDFLARENET - Cloudflare, Inc., US"), "Cloudflare, Inc.")
        XCTAssertEqual(IPOwner.displayName(fromASDescription: "ANTHROPIC - Anthropic, PBC, US"), "Anthropic, PBC")
        XCTAssertEqual(IPOwner.displayName(fromASDescription: "EXAMPLE-AS"), "EXAMPLE-AS")
        XCTAssertEqual(IPOwner.displayName(fromASDescription: "TENCENT-NET-AP-CN - Tencent Building, Kejizhongyi Avenue, CN"), "Tencent")
        XCTAssertEqual(IPOwner.displayName(fromASDescription: "AKAMAI-ASN1 - Akamai International B.V., NL"), "Akamai International B.V.")
        XCTAssertEqual(IPOwnerLookup.originQueryName("1.2.3.4"), "4.3.2.1.origin.asn.cymru.com")
        XCTAssertEqual(IPOwnerLookup.originQueryName("2607:6bc0::10")?.hasSuffix("0.c.b.6.7.0.6.2.origin6.asn.cymru.com"), true)
        XCTAssertNil(IPOwnerLookup.originQueryName("not-an-ip"))
        XCTAssertTrue(IPOwnerLookup.isPrivate("192.168.1.9"))
        XCTAssertTrue(IPOwnerLookup.isPrivate("172.20.0.1"))
        XCTAssertFalse(IPOwnerLookup.isPrivate("172.32.0.1"))
        XCTAssertTrue(IPOwnerLookup.isPrivate("fe80::1"))
        XCTAssertFalse(IPOwnerLookup.isPrivate("2606:4700::1"))
        for ip in ["0.0.0.0", "100.64.0.1", "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "ff02::1", "fe90::1", "2001:db8::1", "::ffff:192.168.1.1"] {
            XCTAssertTrue(IPOwnerLookup.isPrivate(ip), ip)
        }
        XCTAssertFalse(IPOwnerLookup.isPrivate("8.8.8.8"))
        XCTAssertFalse(IPOwnerLookup.isPrivate("2001:4860:4860::8888"))
    }

    func testSNIOverridesDNSInCache() {
        let cache = DNSCache()
        cache.record(DNSParser.Answer(queriedName: "cdn.example.com", addresses: ["203.0.113.5"], ttl: 60))
        XCTAssertEqual(cache.name(for: "203.0.113.5"), "cdn.example.com")
        cache.recordSNI(ip: "203.0.113.5", name: "app.example.com")
        XCTAssertEqual(cache.name(for: "203.0.113.5"), "app.example.com")
    }

    func testTreeGroupsHostnamelessTrafficByOwner() {
        func row(_ domain: String, _ ip: String, owner: String, asn: Int) -> BreakdownRow {
            BreakdownRow(bundleID: "com.a", appName: "A", appPath: "", domain: domain, remoteIP: ip, ports: "443", protocols: "https",
                         counters: FlowCounters(bytesIn: 10, bytesOut: 0, flows: 1), owner: owner, asn: asn)
        }
        let tree = TrafficNode.tree(from: [row("", "104.18.0.1", owner: "Cloudflare, Inc.", asn: 13335),
                                           row("", "104.18.0.2", owner: "Cloudflare, Inc.", asn: 13335),
                                           row("", "8.8.8.8", owner: "", asn: 0),
                                           row("x.com", "1.2.3.4", owner: "X Corp", asn: 1)])
        let groups = tree[0].children!
        XCTAssertEqual(groups.count, 3)
        let cf = groups.first { $0.owner == "Cloudflare, Inc." }
        XCTAssertEqual(cf?.title, "Cloudflare, Inc. · AS13335")
        XCTAssertEqual(cf?.children?.count, 2)
        XCTAssertNotNil(groups.first { $0.domain == "x.com" && $0.owner == nil }, "named traffic keeps its hostname")
        XCTAssertNotNil(groups.first { $0.title == "(no domain)" })
    }
}
