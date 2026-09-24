import XCTest
@testable import Flowlight

/// Channels that aren't the network. There are no byte counts to check here — macOS doesn't account for these per
/// app — so what matters is reading the system's answer correctly and deciding what counts as a change.
final class DeviceTests: XCTestCase {

    // MARK: Reading what system_profiler said

    private let sample = """
    {"SPBluetoothDataType":[{"controller_properties":{"controller_address":"AA:BB"},
      "device_connected":[{"Magic Keyboard":{"device_address":"11:22:33:44:55:66","device_minorType":"Keyboard","device_vendorID":"0x004C"}}],
      "device_not_connected":[{"blessdyb’s AirPods":{"device_address":"AC:1D:06:B9:B6:0E","device_minorType":"Headphones","device_vendorID":"0x004C"}},
                              {"DYB":{"device_address":"B4:56:E3:4A:7E:0D"}}]}]}
    """

    func testConnectedAndPairedDevicesAreBothRead() throws {
        let devices = try XCTUnwrap(BluetoothMonitor.parse(Data(sample.utf8)))
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices.first?.name, "Magic Keyboard", "connected devices sort first")
        XCTAssertTrue(devices.first?.connected == true)
        XCTAssertEqual(devices.first?.detail, "Keyboard")
        XCTAssertEqual(devices.first?.vendor, "Apple")
        XCTAssertEqual(devices.filter(\.connected).count, 1)
    }

    func testADeviceWithNothingButAnAddressStillCounts() throws {
        let devices = try XCTUnwrap(BluetoothMonitor.parse(Data(sample.utf8)))
        let bare = try XCTUnwrap(devices.first { $0.name == "DYB" })
        XCTAssertEqual(bare.id, "B4:56:E3:4A:7E:0D")
        XCTAssertEqual(bare.detail, "")
        XCTAssertEqual(bare.vendor, "", "a vendor id nobody has named is left unnamed rather than guessed at")
    }

    func testAMacWithNoBluetoothIsAnEmptyListRatherThanAFailure() throws {
        let devices = try XCTUnwrap(BluetoothMonitor.parse(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)))
        XCTAssertTrue(devices.isEmpty)
    }

    func testNonsenseIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(BluetoothMonitor.parse(Data("not json".utf8)))
        XCTAssertNil(BluetoothMonitor.parse(Data(#"{"SomethingElse":[]}"#.utf8)))
    }

    func testAConnectedSightingWinsOverADisconnectedOne() throws {
        // The same device can be listed under two controllers.
        let twice = """
        {"SPBluetoothDataType":[
          {"device_not_connected":[{"Mouse":{"device_address":"99:88"}}]},
          {"device_connected":[{"Mouse":{"device_address":"99:88"}}]}]}
        """
        let devices = try XCTUnwrap(BluetoothMonitor.parse(Data(twice.utf8)))
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices.first?.connected == true)
    }

    // MARK: What counts as a change

    private func device(_ id: String, connected: Bool, name: String? = nil) -> PeripheralDevice {
        PeripheralDevice(kind: .bluetooth, id: id, name: name ?? id, detail: "Headphones", connected: connected)
    }

    func testTheFirstSightingIsABaselineNotAFlurryOfNotices() {
        let events = DeviceDiff.events(from: [], to: [device("a", connected: true), device("b", connected: false)],
                                       firstSighting: true)
        XCTAssertTrue(events.isEmpty, "everything already paired is not news")
    }

    func testConnectingAndDisconnectingAreBothRecorded() {
        let before = [device("a", connected: false)]
        let after = [device("a", connected: true)]
        XCTAssertEqual(DeviceDiff.events(from: before, to: after).map(\.change), [.connected])
        XCTAssertEqual(DeviceDiff.events(from: after, to: before).map(\.change), [.disconnected])
    }

    func testANewPairingIsRecordedOnceAndThenIsQuiet() {
        let first = DeviceDiff.events(from: [], to: [device("a", connected: false)])
        XCTAssertEqual(first.map(\.change), [.appeared])
        let again = DeviceDiff.events(from: [device("a", connected: false)], to: [device("a", connected: false)])
        XCTAssertTrue(again.isEmpty, "a device that is simply still there is not an event")
    }

    func testUnpairingIsRecorded() {
        let events = DeviceDiff.events(from: [device("a", connected: true)], to: [])
        XCTAssertEqual(events.map(\.change), [.removed])
    }

    func testARenamedDeviceIsStillTheSameDevice() {
        let events = DeviceDiff.events(from: [device("a", connected: true, name: "Old")],
                                       to: [device("a", connected: true, name: "New")])
        XCTAssertTrue(events.isEmpty, "the address is the identity; a name is a label someone changed")
    }

    // MARK: Which apps are built to use the radio

    func testOnlyAppsThatDeclareAPurposeAreListed() {
        let apps = [
            InstalledApps.App(name: "Quiet", bundleID: "a", path: "/a"),
            InstalledApps.App(name: "Talks", bundleID: "b", path: "/b", bluetoothPurpose: "to find your headphones"),
        ]
        XCTAssertEqual(InstalledApps.bluetoothUsers(apps).map(\.name), ["Talks"])
    }
}
