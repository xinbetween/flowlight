import XCTest
@testable import Flowlight

/// Which way the bytes left the Mac. The point of the whole thing is that an AirDrop no longer looks like a few
/// megabytes to an address with no name, so most of this is about the two ways Flowlight can tell.
final class NetworkChannelTests: XCTestCase {

    // MARK: From the interface, which is what the sampler gets

    func testTheAWDLInterfacesArePeerToPeer() {
        XCTAssertEqual(NetworkChannel.of(interface: "awdl0"), .peerToPeer)
        XCTAssertEqual(NetworkChannel.of(interface: "llw0"), .peerToPeer, "the low-latency link rides the same radio")
        XCTAssertEqual(NetworkChannel.of(interface: "ap1"), .peerToPeer)
    }

    func testOrdinaryInterfacesAreTheNetwork() {
        for name in ["en0", "en6", "bridge0", "anpi0"] {
            XCTAssertEqual(NetworkChannel.of(interface: name), .ip, name)
        }
    }

    func testLoopbackAndTunnels() {
        XCTAssertEqual(NetworkChannel.of(interface: "lo0"), .loopback)
        XCTAssertEqual(NetworkChannel.of(interface: "utun4"), .tunnel)
        XCTAssertEqual(NetworkChannel.of(interface: "ipsec0"), .tunnel)
    }

    func testNoInterfaceIsTheOrdinaryCase() {
        XCTAssertEqual(NetworkChannel.of(interface: ""), .ip)
        XCTAssertEqual(NetworkChannel.of(interface: "  "), .ip)
    }

    // MARK: From the address, which is all the extension has

    func testLinkLocalAddressesReadAsPeerToPeer() {
        XCTAssertEqual(NetworkChannel.of(address: "fe80::1c:2d:3e:4f"), .peerToPeer)
        XCTAssertEqual(NetworkChannel.of(address: "169.254.1.2"), .peerToPeer)
    }

    func testLoopbackAddresses() {
        XCTAssertEqual(NetworkChannel.of(address: "127.0.0.1"), .loopback)
        XCTAssertEqual(NetworkChannel.of(address: "::1"), .loopback)
    }

    func testRoutableAddressesAreTheNetwork() {
        for ip in ["93.184.216.34", "192.168.1.5", "10.0.0.1", "2606:4700::1111"] {
            XCTAssertEqual(NetworkChannel.of(address: ip), .ip, ip)
        }
    }

    func testAnUnparseableAddressIsNotGuessedAt() {
        XCTAssertEqual(NetworkChannel.of(address: "(unconnected)"), .ip)
        XCTAssertEqual(NetworkChannel.of(address: ""), .ip)
    }

    // MARK: Naming what used the radio

    func testTheDaemonBehindAFeatureIsNamed() {
        XCTAssertEqual(PeerToPeerService.name(forProcess: "sharingd"), "AirDrop and Handoff")
        XCTAssertEqual(PeerToPeerService.name(forProcess: "rapportd"), "Continuity")
        XCTAssertEqual(PeerToPeerService.name(forProcess: "AirPlayXPCHelper"), "AirPlay")
    }

    func testAnAppThatUsesTheRadioKeepsItsOwnName() {
        XCTAssertNil(PeerToPeerService.name(forProcess: "Google Chrome H"))
        XCTAssertEqual(PeerToPeerService.destination(forProcess: "Google Chrome H"), "Nearby device")
        XCTAssertEqual(PeerToPeerService.destination(forProcess: "sharingd"), "AirDrop and Handoff · nearby device")
    }

    // MARK: The parser

    private let header = ",interface,bytes_in,bytes_out,"

    func testTheInterfaceIsReadFromTheNamedColumn() {
        let parser = NettopParser()
        _ = parser.feedSample("\(header)\nsharingd.42,,0,0,\ntcp6 fe80::1.51000<->fe80::2.8770,awdl0,0,0,")
        let deltas = parser.feedSample("\(header)\nsharingd.42,,10,2000,\ntcp6 fe80::1.51000<->fe80::2.8770,awdl0,10,2000,")
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.interface, "awdl0")
        XCTAssertEqual(deltas.first?.channel, .peerToPeer)
        XCTAssertEqual(deltas.first?.counters.bytesOut, 2000)
    }

    /// nettop's man page says the `-J` ordering "may change in future revisions". A silent shift by one would turn
    /// every byte count into an interface name, so the columns are read by name.
    func testColumnsAreFoundByNameNotByPosition() {
        let reordered = ",bytes_in,bytes_out,interface,"
        let parser = NettopParser()
        _ = parser.feedSample("\(reordered)\nsharingd.42,0,0,awdl0,\ntcp6 fe80::1.51000<->fe80::2.8770,0,0,llw0,")
        let deltas = parser.feedSample("\(reordered)\nsharingd.42,0,0,awdl0,\ntcp6 fe80::1.51000<->fe80::2.8770,5,7,llw0,")
        XCTAssertEqual(deltas.first?.counters.bytesIn, 5)
        XCTAssertEqual(deltas.first?.counters.bytesOut, 7)
        XCTAssertEqual(deltas.first?.channel, .peerToPeer)
    }

    /// The same socket descriptor appears once per interface it is bound to — a process doing Bonjour discovery
    /// shows the same line on en0, llw0 and awdl0 — and those are different things that happened.
    func testTheSameSocketOnTwoInterfacesStaysTwoRows() {
        let parser = NettopParser()
        let baseline = "\(header)\nChrome.72816,,0,0,\nudp6 *.5353<->*.*,llw0,0,0,\nudp6 *.5353<->*.*,awdl0,0,0,"
        _ = parser.feedSample(baseline)
        let deltas = parser.feedSample("\(header)\nChrome.72816,,0,0,\nudp6 *.5353<->*.*,llw0,100,200,\nudp6 *.5353<->*.*,awdl0,0,300,")
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(Set(deltas.map(\.interface)), ["llw0", "awdl0"])
        XCTAssertEqual(deltas.reduce(0) { $0 + $1.counters.bytesOut }, 500)
    }

    func testAHeaderlessSampleStillReadsItsBytes() {
        // The column map defaults to the columns this parser asks for, so nothing is lost if a header is missed.
        let parser = NettopParser()
        _ = parser.feedSample("\(header)\nsharingd.42,,0,0,\ntcp4 1.2.3.4:1<->5.6.7.8:443,en0,0,0,")
        let deltas = parser.feedSample("sharingd.42,,0,0,\ntcp4 1.2.3.4:1<->5.6.7.8:443,en0,40,60,")
        XCTAssertEqual(deltas.first?.counters.bytesIn, 40)
        XCTAssertEqual(deltas.first?.channel, .ip)
    }

    // MARK: The key

    func testChannelIsPartOfTheKey() {
        var wifi = FlowKey(pid: 1, bundleID: "a", appName: "a", appPath: "", remoteIP: "*", domain: "", port: 5353,
                           transport: .udp, appProtocol: "mDNS")
        var radio = wifi
        radio.channel = .peerToPeer
        XCTAssertNotEqual(wifi, radio, "merging these is exactly how peer-to-peer traffic stayed invisible")
        wifi.channel = .ip
        XCTAssertEqual(wifi.channel, .ip)
    }

    func testAKeyFromAnOlderBuildDecodesAsOrdinaryTraffic() throws {
        // Synthesized decoding ignores property defaults, so a missing key would throw away the whole batch.
        let json = """
        {"pid":1,"bundleID":"a","appName":"A","appPath":"/A","remoteIP":"1.2.3.4","domain":"x.test",
         "port":443,"transport":"tcp","appProtocol":"HTTPS"}
        """
        let key = try JSONDecoder().decode(FlowKey.self, from: Data(json.utf8))
        XCTAssertEqual(key.channel, .ip)
        XCTAssertEqual(key.domain, "x.test")
    }
}

/// What a collector is told about the channel. An attribute on every row saying "this went over the network"
/// would be noise in whatever the collector charges by, so only the unusual ones carry it.
final class ChannelExportTests: XCTestCase {
    private func rollup(_ channel: NetworkChannel) -> ExportRollup {
        ExportRollup(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60),
                     bundleID: "sharingd", appName: "sharingd", domain: "AirDrop and Handoff · nearby device",
                     remoteIP: "fe80::1", port: 8770, appProtocol: "airdrop", owner: "", asn: 0, agentID: "",
                     agentName: "", mcpServer: "", channel: channel, bytesIn: 10, bytesOut: 4_800_000, flows: 1)
    }

    private let resource = ExportResource(serviceName: "flowlight", serviceVersion: "0.4.0", hostName: "test-mac.local")

    func testAPeerToPeerRollupSaysSo() throws {
        let otlp = String(decoding: try ExportPayload.otlpMetrics([rollup(.peerToPeer)], resource: resource), as: UTF8.self)
        XCTAssertTrue(otlp.contains("flowlight.network.channel"))
        XCTAssertTrue(otlp.contains("p2p"))
        let lines = String(decoding: try ExportPayload.ndjson(rollups: [rollup(.peerToPeer)], alerts: [], resource: resource), as: UTF8.self)
        XCTAssertTrue(lines.contains("flowlight.network.channel"))
    }

    func testOrdinaryTrafficCarriesNoChannelAttribute() throws {
        let otlp = String(decoding: try ExportPayload.otlpMetrics([rollup(.ip)], resource: resource), as: UTF8.self)
        XCTAssertFalse(otlp.contains("flowlight.network.channel"))
        let lines = String(decoding: try ExportPayload.ndjson(rollups: [rollup(.ip)], alerts: [], resource: resource), as: UTF8.self)
        XCTAssertFalse(lines.contains("flowlight.network.channel"))
    }
}
