import XCTest
@testable import Flowlight

final class SystemExtensionScanTests: XCTestCase {
    /// Real output from a managed Mac where Flowlight's filter never started: Palo Alto Networks GlobalProtect, CrowdStrike Falcon and a data-loss agent
    /// all hold active network extensions, and macOS runs one content filter at a time.
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
    *\t*\tTEAMTWO456\tcom.example.endpoint.daemon (11.5.2622.12.M/1)\tProtectord\t[activated enabled]
    """

    func testParsesEveryRowAndSkipsHeaders() {
        let found = SystemExtensionScan.parse(sample)
        XCTAssertEqual(found.count, 5)
        XCTAssertFalse(found.contains { $0.teamID == "teamID" }, "the column header is not an extension")
    }

    func testReadsNameVersionAndState() {
        let fortiEDR = SystemExtensionScan.parse(sample).first { $0.bundleID.contains("fortiedr") }
        XCTAssertEqual(fortiEDR?.name, "ExampleEDRNetworkFilter")
        XCTAssertEqual(fortiEDR?.version, "6.1.1/1281")
        XCTAssertEqual(fortiEDR?.state, "activated enabled")
        XCTAssertEqual(fortiEDR?.teamID, "TEAMONE123")
        XCTAssertTrue(fortiEDR?.isActive == true)
    }

    func testCategoriesAreCarried() {
        let found = SystemExtensionScan.parse(sample)
        XCTAssertTrue(found.first { $0.bundleID.contains("manageengine") }?.isNetworkExtension == false,
                      "an endpoint security extension doesn't take the content-filter slot")
        XCTAssertTrue(found.first { $0.bundleID.contains("forticlient") }?.isNetworkExtension == true)
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
