import XCTest
@testable import Flowlight

final class SystemExtensionScanTests: XCTestCase {
    /// The shape of `systemextensionsctl list` on a managed Mac where Flowlight's filter never started: other
    /// vendors hold active network extensions, and macOS runs one content filter at a time. The identifiers are
    /// stand-ins — a real user's security stack isn't something to publish in a test.
    private let sample = """
    9 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tTEAMONE123\tcom.example.security.macos.proxy (7.4.8/1977)\tExampleSecurityProxy\t[activated enabled]
    *\t*\tTEAMONE123\tcom.example.edr.macos.SysExt.nefilter (6.1.1/1281)\tExampleEDRNetworkFilter\t[activated enabled]
    \t\t38RJUJHKZS\tcom.flowlight.app.filter (0.2.2/8)\tFlowlight Filter\t[terminated waiting to uninstall on reboot]
    *\t*\t38RJUJHKZS\tcom.flowlight.app.filter (0.2.5/8)\tFlowlight Filter\t[activated enabled]
    --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tTEAMTWO456\tcom.example.endpoint.daemon (11.5.2622.12.M/1)\tExampleEndpointDaemon\t[activated enabled]
    """

    func testParsesEveryRowAndSkipsHeaders() {
        let found = SystemExtensionScan.parse(sample)
        XCTAssertEqual(found.count, 5)
        XCTAssertFalse(found.contains { $0.teamID == "teamID" }, "the column header is not an extension")
    }

    func testReadsNameVersionAndState() {
        let edr = SystemExtensionScan.parse(sample).first { $0.bundleID.contains("edr") }
        XCTAssertEqual(edr?.name, "ExampleEDRNetworkFilter")
        XCTAssertEqual(edr?.version, "6.1.1/1281")
        XCTAssertEqual(edr?.state, "activated enabled")
        XCTAssertEqual(edr?.teamID, "TEAMONE123")
        XCTAssertTrue(edr?.isActive == true)
    }

    func testCategoriesAreCarried() {
        let found = SystemExtensionScan.parse(sample)
        XCTAssertTrue(found.first { $0.bundleID.contains("endpoint") }?.isNetworkExtension == false,
                      "an endpoint security extension doesn't take the content-filter slot")
        XCTAssertTrue(found.first { $0.bundleID.contains("security") }?.isNetworkExtension == true)
    }

    func testCompetingFiltersExcludeOursAndInactiveOnes() {
        let competing = SystemExtensionScan.competingFilters(in: SystemExtensionScan.parse(sample))
        XCTAssertEqual(Set(competing.map(\.name)), ["ExampleSecurityProxy", "ExampleEDRNetworkFilter"])
        XCTAssertFalse(competing.contains { $0.isOurs }, "our own filter isn't competing with us")
        XCTAssertFalse(competing.contains { $0.state.contains("terminated") }, "a retired extension holds nothing")
    }

    func testNoCompetitionWhenOnlyOursIsInstalled() {
        let alone = """
        1 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings')
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\t38RJUJHKZS\tcom.flowlight.app.filter (0.2.5/8)\tFlowlight Filter\t[activated enabled]
        """
        XCTAssertTrue(SystemExtensionScan.competingFilters(in: SystemExtensionScan.parse(alone)).isEmpty)
    }

    func testEmptyOutputIsHandled() {
        XCTAssertTrue(SystemExtensionScan.parse("").isEmpty)
        XCTAssertTrue(SystemExtensionScan.parse("0 extension(s)\n").isEmpty)
    }
}
