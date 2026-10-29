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

private final class CameraMonitorSpy: CameraMonitoring {
    var onDevices: ([CameraDevice], UInt64) -> Void = { _, _ in }
    var onEvents: ([DeviceEvent], UInt64) -> Void = { _, _ in }
    private(set) var starts: [UInt64] = []
    private(set) var stopCount = 0

    func start(generation: UInt64) { starts.append(generation) }
    func stop() { stopCount += 1 }
    func refresh() {}

    func send(_ events: [DeviceEvent]) {
        guard let generation = starts.last else { return }
        onEvents(events, generation)
    }
}

@MainActor
final class CameraStoreTests: XCTestCase {
    private var savedCamera: Any?
    private var savedUSB: Any?

    override func setUp() {
        super.setUp()
        savedCamera = UserDefaults.standard.object(forKey: DeviceStore.Keys.camera)
        savedUSB = UserDefaults.standard.object(forKey: DeviceStore.Keys.usb)
        UserDefaults.standard.set(false, forKey: DeviceStore.Keys.camera)
        UserDefaults.standard.set(false, forKey: DeviceStore.Keys.usb)
    }

    override func tearDown() {
        restore(savedCamera, key: DeviceStore.Keys.camera)
        restore(savedUSB, key: DeviceStore.Keys.usb)
        super.tearDown()
    }

    func testChangingAnotherChannelDoesNotRestartCameraBaseline() {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        store.watchingCamera = true
        XCTAssertEqual(monitor.starts.count, 1)

        store.watchingUSB = true
        store.watchingUSB = false
        XCTAssertEqual(monitor.starts.count, 1, "unrelated channel changes preserve the camera transition baseline")
    }

    func testCameraEventDuringDeleteEverythingIsPersistedAfterClear() async throws {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-camera-clear-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        store.attach(db: db)
        try await db.asyncResult { _ in }
        await Task.yield()
        store.watchingCamera = true

        store.beginHistoryClear()
        monitor.send([DeviceEvent(
            at: Date(), kind: .camera, deviceID: "built-in", name: "Camera", detail: "",
            change: .started
        )])
        await Task.yield()
        try await db.asyncResult { try $0.clearAll() }
        store.finishHistoryClear(succeeded: true)
        try await db.asyncResult { _ in }

        XCTAssertEqual(store.events.map(\.change), [.started])
        XCTAssertEqual(try db.deviceEvents().map(\.change), [.started],
                       "an event crossing the clear boundary must not be hidden until relaunch")
    }

    private func restore(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

final class CameraTests: XCTestCase {
    private func camera(_ id: String, _ state: CameraDevice.State, name: String? = nil) -> CameraDevice {
        CameraDevice(id: id, name: name ?? id, manufacturer: "Acme", state: state)
    }

    func testFirstCameraReadingIsABaseline() {
        let events = CameraDiff.events(
            from: [],
            to: [camera("built-in", .active), camera("desk-view", .inactive)],
            firstSighting: true
        )
        XCTAssertTrue(events.isEmpty, "cameras already active when watching starts are not new activity")
    }

    func testConfirmedCameraStartAndStopAreRecorded() {
        let inactive = [camera("built-in", .inactive, name: "MacBook Pro Camera")]
        let active = [camera("built-in", .active, name: "MacBook Pro Camera")]
        XCTAssertEqual(CameraDiff.events(from: inactive, to: active).map(\.change), [.started])
        XCTAssertEqual(CameraDiff.events(from: active, to: inactive).map(\.change), [.stopped])
    }

    func testUnknownCameraStateNeverPretendsToStartOrStop() {
        let unknown = [camera("built-in", .unknown)]
        let active = [camera("built-in", .active)]
        let inactive = [camera("built-in", .inactive)]
        XCTAssertTrue(CameraDiff.events(from: active, to: unknown).isEmpty)
        XCTAssertTrue(CameraDiff.events(from: unknown, to: inactive).isEmpty)
        XCTAssertTrue(CameraDiff.events(from: unknown, to: active).isEmpty)
    }

    func testHotPluggedAndRenamedCamerasDoNotFabricateActivity() {
        XCTAssertTrue(CameraDiff.events(from: [], to: [camera("external", .active)]).isEmpty)
        XCTAssertTrue(CameraDiff.events(
            from: [camera("built-in", .inactive, name: "Old")],
            to: [camera("built-in", .inactive, name: "New")]
        ).isEmpty)
    }

    func testDuplicateCameraCallbacksAreQuiet() {
        let cameras = [camera("built-in", .active)]
        XCTAssertTrue(CameraDiff.events(from: cameras, to: cameras).isEmpty)
    }

    func testCameraEventHistoryIsPrunedAndDeletedWithEverythingElse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-camera-events-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let old = DeviceEvent(
            at: Date(timeIntervalSince1970: 100), kind: .camera, deviceID: "old",
            name: "Old Camera", detail: "", change: .started
        )
        let recent = DeviceEvent(
            at: Date(timeIntervalSince1970: 200), kind: .camera, deviceID: "recent",
            name: "Recent Camera", detail: "Acme", change: .stopped
        )
        try db.recordDeviceEvents([old, recent])

        XCTAssertEqual(try db.deviceEvents().map(\.change), [.stopped, .started])
        try db.pruneDeviceEvents(before: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(try db.deviceEvents().map(\.deviceID), ["recent"])
        try db.clearAll()
        XCTAssertTrue(try db.deviceEvents().isEmpty, "Delete everything includes device and camera history")
    }
}

/// USB and the volumes that appear. Nothing is plugged into a build machine, so the rules about what counts are
/// tested against the shapes `system_profiler` and the file system actually produce.
final class USBTests: XCTestCase {

    private let tree = """
    {"SPUSBDataType":[
      {"_name":"USB31Bus","host_controller":"AppleT8122USBXHCI","_items":[
        {"_name":"USB-C Hub","manufacturer":"Acme","location_id":"0x02100000 / 1","device_speed":"super_speed","_items":[
          {"_name":"Backup Drive","serial_num":"SN12345","manufacturer":"Seagate",
           "Media":[{"size_in_bytes":2000000000000,"bsd_name":"disk4"}]},
          {"_name":"Keyboard","location_id":"0x02110000 / 3","device_speed":"low_speed","vendor_id":"0x05ac  (Apple Inc.)"}]}]},
      {"_name":"USB30Bus","host_controller":"AppleT8122USBXHCI"}]}
    """

    func testBusesAreWalkedThroughRatherThanListed() throws {
        let devices = try XCTUnwrap(USBMonitor.parse(Data(tree.utf8)))
        XCTAssertFalse(devices.contains { $0.name.hasSuffix("Bus") }, "a controller is not something anyone plugged in")
        XCTAssertEqual(devices.map(\.name), ["Backup Drive", "Keyboard", "USB-C Hub"])
    }

    func testAStorageDeviceCarriesItsCapacity() throws {
        let devices = try XCTUnwrap(USBMonitor.parse(Data(tree.utf8)))
        let drive = try XCTUnwrap(devices.first { $0.name == "Backup Drive" })
        XCTAssertEqual(drive.capacity, 2_000_000_000_000)
        XCTAssertEqual(drive.detail, "Storage")
        XCTAssertEqual(drive.id, "usb:SN12345", "a serial number is the only stable identity a device has")
    }

    func testADeviceWithNoSerialIsIdentifiedByWhereItIsPluggedIn() throws {
        let devices = try XCTUnwrap(USBMonitor.parse(Data(tree.utf8)))
        let keyboard = try XCTUnwrap(devices.first { $0.name == "Keyboard" })
        XCTAssertTrue(keyboard.id.contains("0x02110000"))
        XCTAssertEqual(keyboard.detail, "USB 1.1")
        XCTAssertEqual(keyboard.vendor, "Apple Inc.", "the name inside the parentheses, not the hex id")
    }

    func testAMacWithNothingPluggedInIsAnEmptyList() throws {
        XCTAssertEqual(try XCTUnwrap(USBMonitor.parse(Data(#"{"SPUSBDataType":[]}"#.utf8))).count, 0)
        XCTAssertNil(USBMonitor.parse(Data("not json".utf8)))
    }

    func testVendorStringsAreCleanedUpOrLeftOut() {
        XCTAssertEqual(USBMonitor.vendor("0x05ac  (Apple Inc.)"), "Apple Inc.")
        XCTAssertEqual(USBMonitor.vendor("Seagate"), "Seagate")
        XCTAssertEqual(USBMonitor.vendor("0x1234"), "", "a bare hex id names nothing, so it says nothing")
        XCTAssertEqual(USBMonitor.vendor(nil), "")
    }

    // MARK: Volumes

    private func volume(_ name: String, removable: Bool, internalDisk: Bool) -> USBMonitor.Volume {
        USBMonitor.Volume(name: name, path: "/Volumes/\(name)", removable: removable,
                          internalDisk: internalDisk, capacity: 500_000_000)
    }

    func testTheBootDiskIsNotNews() {
        let volumes = [volume("Macintosh HD", removable: false, internalDisk: true),
                       volume("Backup", removable: true, internalDisk: false)]
        XCTAssertEqual(USBMonitor.external(volumes).map(\.name), ["Backup"])
    }

    func testAnExternalDiskThatIsNotRemovableStillCounts() {
        // A Thunderbolt drive is external but not "removable" in the file system's sense.
        let devices = USBMonitor.external([volume("Studio Drive", removable: false, internalDisk: false)])
        XCTAssertEqual(devices.map(\.detail), ["External"])
        XCTAssertEqual(devices.first?.id, "volume:/Volumes/Studio Drive")
    }

    func testARemovableInternalCardReaderCounts() {
        let devices = USBMonitor.external([volume("SD Card", removable: true, internalDisk: true)])
        XCTAssertEqual(devices.map(\.detail), ["Removable"])
    }
}
