import Foundation

/// The channels that aren't the network: Bluetooth, USB, and whether a camera is active.
///
/// Each channel is off until it is switched on. Not because either needs a permission Flowlight can't get — neither
/// does — but because turning them on widens what the app watches, and that should be a decision rather than a
/// surprise in an update.
@MainActor
final class DeviceStore: ObservableObject {
    enum Keys {
        static let bluetooth = "devices.bluetooth"
        static let usb = "devices.usb"
        static let camera = "devices.camera"
    }

    @Published private(set) var bluetooth: [PeripheralDevice] = []
    @Published private(set) var usb: [PeripheralDevice] = []
    @Published private(set) var cameras: [CameraDevice] = []
    @Published private(set) var events: [DeviceEvent] = []
    /// Apps built to use Bluetooth, as their own Info.plist declares.
    @Published private(set) var bluetoothApps: [InstalledApps.App] = []

    private let bluetoothMonitor = BluetoothMonitor()
    private let usbMonitor = USBMonitor()
    private let cameraMonitor: CameraMonitoring
    private weak var db: TrafficDatabase?
    private var cameraGeneration: UInt64 = 0
    private var historyRevision: UInt64 = 0
    private var clearingHistory = false
    private var eventsDuringClear: [DeviceEvent] = []
    private var cameraRunning = false

    init(cameraMonitor: CameraMonitoring = CameraMonitor()) {
        self.cameraMonitor = cameraMonitor
        UserDefaults.standard.register(defaults: [Keys.bluetooth: false, Keys.usb: false, Keys.camera: false])
        bluetoothMonitor.onDevices = { [weak self] devices in
            Task { @MainActor in self?.bluetooth = devices }
        }
        bluetoothMonitor.onEvents = { [weak self] events in
            Task { @MainActor in self?.record(events) }
        }
        usbMonitor.onDevices = { [weak self] devices in
            Task { @MainActor in self?.usb = devices }
        }
        usbMonitor.onEvents = { [weak self] events in
            Task { @MainActor in self?.record(events) }
        }
        cameraMonitor.onDevices = { [weak self] cameras, generation in
            Task { @MainActor in
                guard let self, self.watchingCamera, generation == self.cameraGeneration else { return }
                self.cameras = cameras
            }
        }
        cameraMonitor.onEvents = { [weak self] events, generation in
            Task { @MainActor in
                guard let self, self.watchingCamera, generation == self.cameraGeneration else { return }
                self.record(events)
            }
        }
    }

    var watchingBluetooth: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.bluetooth) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.bluetooth)
            objectWillChange.send()
            apply()
        }
    }

    var watchingUSB: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.usb) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.usb)
            objectWillChange.send()
            apply()
        }
    }

    var watchingCamera: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.camera) }
        set {
            guard newValue != watchingCamera else { return }
            cameraGeneration &+= 1
            UserDefaults.standard.set(newValue, forKey: Keys.camera)
            objectWillChange.send()
            apply()
        }
    }

    var isWatchingAnything: Bool { watchingBluetooth || watchingUSB || watchingCamera }

    func attach(db: TrafficDatabase) {
        self.db = db
        let expectedRevision = historyRevision
        db.async { [weak self] db in
            let history = (try? db.deviceEvents()) ?? []
            Task { @MainActor in
                guard let self else { return }
                if self.historyRevision == expectedRevision { self.events = history }
                self.apply()
            }
        }
    }

    func refresh() {
        if watchingBluetooth { bluetoothMonitor.refresh() }
        if watchingUSB { usbMonitor.refresh() }
        if watchingCamera { cameraMonitor.refresh() }
    }

    /// Starts the Delete everything barrier before its database work is queued. New transitions remain in memory and
    /// are persisted only after the clear succeeds, so a queued insert cannot land behind the deletion unnoticed.
    func beginHistoryClear() {
        clearingHistory = true
        historyRevision &+= 1
        eventsDuringClear = []
    }

    func finishHistoryClear(succeeded: Bool) {
        let pending = eventsDuringClear
        clearingHistory = false
        eventsDuringClear = []
        if succeeded { events = pending }
        if !pending.isEmpty { persist(pending) }
    }

    private func apply() {
        if watchingBluetooth {
            bluetoothMonitor.start()
            if bluetoothApps.isEmpty {
                // Reading several hundred Info.plists, once, off the main actor.
                Task.detached(priority: .utility) {
                    let apps = InstalledApps.bluetoothUsers()
                    await MainActor.run { self.bluetoothApps = apps }
                }
            }
        } else {
            bluetoothMonitor.stop()
            bluetooth = []
        }
        if watchingUSB {
            usbMonitor.start()
        } else {
            usbMonitor.stop()
            usb = []
        }
        if watchingCamera {
            if !cameraRunning {
                cameraRunning = true
                cameraMonitor.start(generation: cameraGeneration)
            }
        } else if cameraRunning {
            cameraRunning = false
            cameraMonitor.stop()
            cameras = []
        }
    }

    private func record(_ incoming: [DeviceEvent]) {
        guard !incoming.isEmpty else { return }
        historyRevision &+= 1
        events = incoming + events
        if clearingHistory {
            eventsDuringClear += incoming
        } else {
            persist(incoming)
        }
        Notifier.post(devices: incoming)
    }

    private func persist(_ events: [DeviceEvent]) {
        db?.async { try $0.recordDeviceEvents(events) }
    }
}
