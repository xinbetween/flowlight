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

    func testBluetoothRestartEstablishesANewBaseline() {
        let monitor = BluetoothMonitor()
        monitor.interval = 3_600
        let samples = NSLock()
        var reads = [
            Data(#"{"SPBluetoothDataType":[{"device_not_connected":[{"Headphones":{"device_address":"AA"}}]}]}"#.utf8),
            Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Headphones":{"device_address":"AA"}}]}]}"#.utf8),
        ]
        monitor.read = {
            samples.lock(); defer { samples.unlock() }
            return reads.isEmpty ? nil : reads.removeFirst()
        }
        let first = expectation(description: "first Bluetooth baseline")
        let second = expectation(description: "second Bluetooth baseline")
        let stale = expectation(description: "no event from time spent opted out")
        stale.isInverted = true
        var callbacks = 0
        monitor.onDevices = { _, _ in
            callbacks += 1
            (callbacks == 1 ? first : second).fulfill()
        }
        monitor.onEvents = { _, _ in stale.fulfill() }

        monitor.start(generation: 1)
        wait(for: [first], timeout: 2)
        monitor.stop()
        monitor.start(generation: 2)
        wait(for: [second, stale], timeout: 0.3)
        monitor.stop()
    }

    func testUSBRestartEstablishesANewBaseline() {
        let monitor = USBMonitor()
        monitor.interval = 3_600
        monitor.read = { nil }
        let drive = PeripheralDevice(kind: .usb, id: "usb:drive", name: "Drive", detail: "Storage", connected: true)
        let samples = NSLock()
        var reads = [[drive], []]
        monitor.readVolumes = {
            samples.lock(); defer { samples.unlock() }
            return reads.isEmpty ? [] : reads.removeFirst()
        }
        let first = expectation(description: "first USB baseline")
        let second = expectation(description: "second USB baseline")
        let stale = expectation(description: "no event from time spent opted out")
        stale.isInverted = true
        var callbacks = 0
        monitor.onDevices = { _, _ in
            callbacks += 1
            (callbacks == 1 ? first : second).fulfill()
        }
        monitor.onEvents = { _, _ in stale.fulfill() }

        monitor.start(generation: 1)
        wait(for: [first], timeout: 2)
        monitor.stop()
        monitor.start(generation: 2)
        wait(for: [second, stale], timeout: 0.3)
        monitor.stop()
    }

    func testRefreshAfterPeripheralStopDoesNotSampleOptedOutChannels() {
        let bluetooth = BluetoothMonitor()
        bluetooth.interval = 3_600
        bluetooth.read = { Data(#"{"SPBluetoothDataType":[{}]}"#.utf8) }
        let bluetoothBaseline = expectation(description: "Bluetooth baseline")
        bluetooth.onDevices = { _, _ in bluetoothBaseline.fulfill() }
        bluetooth.start(generation: 1)
        wait(for: [bluetoothBaseline], timeout: 2)
        bluetooth.stop()
        let bluetoothRead = expectation(description: "no Bluetooth read after stop")
        bluetoothRead.isInverted = true
        bluetooth.read = { bluetoothRead.fulfill(); return nil }
        bluetooth.refresh()

        let usb = USBMonitor()
        usb.interval = 3_600
        usb.read = { nil }
        usb.readVolumes = { [] }
        let usbBaseline = expectation(description: "USB baseline")
        usb.onDevices = { _, _ in usbBaseline.fulfill() }
        usb.start(generation: 1)
        wait(for: [usbBaseline], timeout: 2)
        usb.stop()
        let usbRead = expectation(description: "no USB read after stop")
        usbRead.isInverted = true
        usb.readVolumes = { usbRead.fulfill(); return [] }
        usb.refresh()

        wait(for: [bluetoothRead, usbRead], timeout: 0.3)
    }

    func testOptOutInvalidatesPeripheralSamplesAlreadyBlockedInARead() {
        let bluetooth = BluetoothMonitor()
        bluetooth.interval = 3_600
        let bluetoothStarted = expectation(description: "Bluetooth read started")
        let releaseBluetooth = DispatchSemaphore(value: 0)
        bluetooth.read = {
            bluetoothStarted.fulfill()
            releaseBluetooth.wait()
            return Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)
        }
        let bluetoothCallback = expectation(description: "no Bluetooth callback after opt-out")
        bluetoothCallback.isInverted = true
        bluetooth.onDevices = { _, _ in bluetoothCallback.fulfill() }
        bluetooth.start(generation: 1)
        wait(for: [bluetoothStarted], timeout: 2)
        bluetooth.stop()
        releaseBluetooth.signal()

        let usb = USBMonitor()
        usb.interval = 3_600
        usb.read = { nil }
        let usbStarted = expectation(description: "USB read started")
        let releaseUSB = DispatchSemaphore(value: 0)
        usb.readVolumes = {
            usbStarted.fulfill()
            releaseUSB.wait()
            return []
        }
        let usbCallback = expectation(description: "no USB callback after opt-out")
        usbCallback.isInverted = true
        usb.onDevices = { _, _ in usbCallback.fulfill() }
        usb.start(generation: 1)
        wait(for: [usbStarted], timeout: 2)
        usb.stop()
        releaseUSB.signal()

        wait(for: [bluetoothCallback, usbCallback], timeout: 0.3)
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

private final class PeripheralMonitorSpy: PeripheralMonitoring {
    var onDevices: ([PeripheralDevice], UInt64) -> Void = { _, _ in }
    var onEvents: ([DeviceEvent], UInt64) -> Void = { _, _ in }
    private(set) var starts: [UInt64] = []
    private(set) var stopCount = 0

    func start(generation: UInt64) { starts.append(generation) }
    func stop() { stopCount += 1 }
    func refresh() {}

    func send(devices: [PeripheralDevice], events: [DeviceEvent]) {
        guard let generation = starts.last else { return }
        onDevices(devices, generation)
        onEvents(events, generation)
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

private final class BluetoothAppGenerationGate: @unchecked Sendable {
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func scan() -> [InstalledApps.App] {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            releaseFirst.wait()
            return [InstalledApps.App(name: "Stale", bundleID: "stale", path: "/stale")]
        }
        return [InstalledApps.App(name: "Fresh", bundleID: "fresh", path: "/fresh")]
    }
}

private final class BluetoothAppScanGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func scan() -> [InstalledApps.App] {
        lock.lock(); calls += 1; lock.unlock()
        release.wait()
        return []
    }
}

@MainActor
final class CameraStoreTests: XCTestCase {
    private var savedBluetooth: Any?
    private var savedCamera: Any?
    private var savedUSB: Any?

    override func setUp() {
        super.setUp()
        savedBluetooth = UserDefaults.standard.object(forKey: DeviceStore.Keys.bluetooth)
        savedCamera = UserDefaults.standard.object(forKey: DeviceStore.Keys.camera)
        savedUSB = UserDefaults.standard.object(forKey: DeviceStore.Keys.usb)
        UserDefaults.standard.set(false, forKey: DeviceStore.Keys.bluetooth)
        UserDefaults.standard.set(false, forKey: DeviceStore.Keys.camera)
        UserDefaults.standard.set(false, forKey: DeviceStore.Keys.usb)
    }

    override func tearDown() {
        restore(savedBluetooth, key: DeviceStore.Keys.bluetooth)
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

    func testBluetoothAppScanCoalescesWhileRunningAndRetriesAnEmptyResult() async {
        let gate = BluetoothAppScanGate()
        let store = DeviceStore(
            bluetoothMonitor: PeripheralMonitorSpy(),
            usbMonitor: PeripheralMonitorSpy(),
            cameraMonitor: CameraMonitorSpy(),
            bluetoothAppsProvider: { gate.scan() },
            bluetoothAppsRetryDelay: .milliseconds(10)
        )
        store.watchingBluetooth = true
        for _ in 0..<200 {
            if gate.callCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(gate.callCount, 1)

        store.watchingUSB = true
        store.watchingCamera = true
        store.watchingUSB = false
        store.watchingCamera = false
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.callCount, 1, "unrelated apply calls must coalesce behind the active scan")

        gate.release.signal()
        for _ in 0..<200 {
            if gate.callCount >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(gate.callCount, 2, "an empty transient scan must schedule its own bounded retry")
        gate.release.signal()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.callCount, 2, "a genuinely empty app inventory must not cause an unbounded scan loop")
    }

    func testBluetoothAppScanRejectsResultsFromAnOptedOutGeneration() async {
        let gate = BluetoothAppGenerationGate()
        let store = DeviceStore(
            bluetoothMonitor: PeripheralMonitorSpy(),
            usbMonitor: PeripheralMonitorSpy(),
            cameraMonitor: CameraMonitorSpy(),
            bluetoothAppsProvider: { gate.scan() },
            bluetoothAppsRetryDelay: .milliseconds(10)
        )
        store.watchingBluetooth = true
        for _ in 0..<200 {
            if gate.callCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(gate.callCount, 1)

        store.watchingBluetooth = false
        store.watchingBluetooth = true
        gate.releaseFirst.signal()
        for _ in 0..<200 {
            if gate.callCount >= 2, store.bluetoothApps.map(\.name) == ["Fresh"] { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(gate.callCount, 2)
        XCTAssertEqual(store.bluetoothApps.map(\.name), ["Fresh"],
                       "a scan begun before opt-out must not populate or consume retries for the new generation")
    }

    func testBluetoothAndUSBLateCallbacksAreRejectedAfterOptOut() async {
        let bluetoothMonitor = PeripheralMonitorSpy()
        let usbMonitor = PeripheralMonitorSpy()
        let store = DeviceStore(
            bluetoothMonitor: bluetoothMonitor,
            usbMonitor: usbMonitor,
            cameraMonitor: CameraMonitorSpy()
        )
        store.watchingBluetooth = true
        store.watchingUSB = true
        store.watchingBluetooth = false
        store.watchingUSB = false

        bluetoothMonitor.send(
            devices: [PeripheralDevice(
                kind: .bluetooth, id: "late-bluetooth", name: "Late Bluetooth", detail: "", connected: true
            )],
            events: [DeviceEvent(
                at: Date(), kind: .bluetooth, deviceID: "late-bluetooth", name: "Late Bluetooth", detail: "",
                change: .connected
            )]
        )
        usbMonitor.send(
            devices: [PeripheralDevice(
                kind: .usb, id: "late-usb", name: "Late USB", detail: "", connected: true
            )],
            events: [DeviceEvent(
                at: Date(), kind: .usb, deviceID: "late-usb", name: "Late USB", detail: "",
                change: .appeared
            )]
        )
        await Task.yield()

        XCTAssertTrue(store.bluetooth.isEmpty)
        XCTAssertTrue(store.usb.isEmpty)
        XCTAssertTrue(store.events.isEmpty, "late opt-out callbacks must not persist or notify")
    }

    func testEventsBufferedDuringHistoryClearRemainNewestFirst() async {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        store.watchingCamera = true
        store.beginHistoryClear()

        monitor.send([DeviceEvent(
            at: Date(timeIntervalSince1970: 100), kind: .camera, deviceID: "older", name: "Older", detail: "",
            change: .started
        )])
        await Task.yield()
        monitor.send([DeviceEvent(
            at: Date(timeIntervalSince1970: 200), kind: .camera, deviceID: "newer", name: "Newer", detail: "",
            change: .stopped
        )])
        await Task.yield()
        store.finishHistoryClear(succeeded: true)

        XCTAssertEqual(store.events.map(\.deviceID), ["newer", "older"])
    }

    func testBufferedSameSecondEventsRemainNewestFirstAfterPersistence() async throws {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-camera-clear-order-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        store.attach(db: db)
        try await db.asyncResult { _ in }
        await Task.yield()
        store.watchingCamera = true
        store.beginHistoryClear()

        let timestamp = Date(timeIntervalSince1970: 100)
        monitor.send([DeviceEvent(
            at: timestamp, kind: .camera, deviceID: "older", name: "Older", detail: "", change: .started
        )])
        await Task.yield()
        monitor.send([DeviceEvent(
            at: timestamp, kind: .camera, deviceID: "newer", name: "Newer", detail: "", change: .stopped
        )])
        await Task.yield()
        store.finishHistoryClear(succeeded: true)
        try await db.asyncResult { _ in }

        XCTAssertEqual(store.events.map(\.deviceID), ["newer", "older"])
        XCTAssertEqual(try db.deviceEvents().map(\.deviceID), ["newer", "older"],
                       "same-second ordering must survive a relaunch")
    }

    func testOrdinarySameSecondEventBatchKeepsItsLiveOrderAfterPersistence() async throws {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-camera-order-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        store.attach(db: db)
        try await db.asyncResult { _ in }
        await Task.yield()
        store.watchingCamera = true

        let timestamp = Date(timeIntervalSince1970: 100)
        monitor.send([
            DeviceEvent(at: timestamp, kind: .camera, deviceID: "a", name: "A", detail: "", change: .started),
            DeviceEvent(at: timestamp, kind: .camera, deviceID: "b", name: "B", detail: "", change: .stopped),
        ])
        await Task.yield()
        try await db.asyncResult { _ in }

        XCTAssertEqual(store.events.map(\.deviceID), ["a", "b"])
        let reloaded = try await db.asyncResult { try $0.deviceEvents() }
        XCTAssertEqual(reloaded.map(\.deviceID), ["a", "b"],
                       "ordinary equal-second batches must retain their live order after relaunch")
    }

    func testEventsBufferedDuringFailedHistoryClearRemainNewestFirst() async {
        let monitor = CameraMonitorSpy()
        let store = DeviceStore(cameraMonitor: monitor)
        store.watchingCamera = true
        store.beginHistoryClear()

        monitor.send([DeviceEvent(
            at: Date(timeIntervalSince1970: 100), kind: .camera, deviceID: "older", name: "Older", detail: "",
            change: .started
        )])
        await Task.yield()
        monitor.send([DeviceEvent(
            at: Date(timeIntervalSince1970: 200), kind: .camera, deviceID: "newer", name: "Newer", detail: "",
            change: .stopped
        )])
        await Task.yield()
        store.finishHistoryClear(succeeded: false)

        XCTAssertEqual(store.events.map(\.deviceID), ["newer", "older"])
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
    func testListenerDrivenSampleSchedulesRetryAfterEnumerationFailureThenRecovers() {
        var scheduled = 0
        var enumerations: [[Int]?] = [nil, [42]]
        let enumerate = { enumerations.removeFirst() }

        XCTAssertNil(CameraSampleEnumeration.resolve(prefetched: nil, enumerate: enumerate,
                                                     failed: { scheduled += 1 }))
        XCTAssertEqual(scheduled, 1, "a device-state listener must not leave the last camera state indefinitely")
        XCTAssertEqual(CameraSampleEnumeration.resolve(prefetched: nil, enumerate: enumerate,
                                                       failed: { scheduled += 1 }), [42])
        XCTAssertEqual(scheduled, 1, "recovery returns the current devices without scheduling another retry")
    }

    func testEnumerationRetryBacksOffAndResetsAfterRecovery() {
        var backoff = CameraEnumerationBackoff()
        XCTAssertEqual(backoff.failed(), 1)
        XCTAssertEqual(backoff.failed(), 2)
        XCTAssertEqual(backoff.failed(), 5)
        XCTAssertEqual(backoff.failed(), 10)
        XCTAssertEqual(backoff.failed(), 10, "persistent failure retries at a bounded cadence")
        backoff.recovered()
        XCTAssertEqual(backoff.failed(), 1, "a later transient failure starts from the fast retry again")
    }

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
