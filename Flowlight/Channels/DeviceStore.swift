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

    private let bluetoothMonitor: PeripheralMonitoring
    private let usbMonitor: PeripheralMonitoring
    private let cameraMonitor: CameraMonitoring
    private let bluetoothAppsProvider: @Sendable () -> [InstalledApps.App]
    private let bluetoothAppsRetryDelay: Duration
    private weak var db: TrafficDatabase?
    private var bluetoothGeneration: UInt64 = 0
    private var usbGeneration: UInt64 = 0
    private var cameraGeneration: UInt64 = 0
    private var historyRevision: UInt64 = 0
    private var clearingHistory = false
    private var eventsDuringClear: [DeviceEvent] = []
    private var bluetoothRunning = false
    private var usbRunning = false
    private var cameraRunning = false
    private var bluetoothAppsScanInFlight = false
    private var bluetoothAppsAutomaticRetriesRemaining = 1

    init(
        bluetoothMonitor: PeripheralMonitoring = BluetoothMonitor(),
        usbMonitor: PeripheralMonitoring = USBMonitor(),
        cameraMonitor: CameraMonitoring = CameraMonitor(),
        bluetoothAppsProvider: @escaping @Sendable () -> [InstalledApps.App] = { InstalledApps.bluetoothUsers() },
        bluetoothAppsRetryDelay: Duration = .seconds(5)
    ) {
        self.bluetoothMonitor = bluetoothMonitor
        self.usbMonitor = usbMonitor
        self.cameraMonitor = cameraMonitor
        self.bluetoothAppsProvider = bluetoothAppsProvider
        self.bluetoothAppsRetryDelay = bluetoothAppsRetryDelay
        UserDefaults.standard.register(defaults: [Keys.bluetooth: false, Keys.usb: false, Keys.camera: false])
        bluetoothMonitor.onDevices = { [weak self] devices, generation in
            Task { @MainActor in
                guard let self,
                      self.watchingBluetooth,
                      generation == self.bluetoothGeneration else { return }
                self.bluetooth = devices
            }
        }
        bluetoothMonitor.onEvents = { [weak self] events, generation in
            Task { @MainActor in
                guard let self,
                      self.watchingBluetooth,
                      generation == self.bluetoothGeneration else { return }
                self.record(events)
            }
        }
        usbMonitor.onDevices = { [weak self] devices, generation in
            Task { @MainActor in
                guard let self,
                      self.watchingUSB,
                      generation == self.usbGeneration else { return }
                self.usb = devices
            }
        }
        usbMonitor.onEvents = { [weak self] events, generation in
            Task { @MainActor in
                guard let self,
                      self.watchingUSB,
                      generation == self.usbGeneration else { return }
                self.record(events)
            }
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
            guard newValue != watchingBluetooth else { return }
            bluetoothGeneration &+= 1
            if newValue { bluetoothAppsAutomaticRetriesRemaining = 1 }
            UserDefaults.standard.set(newValue, forKey: Keys.bluetooth)
            objectWillChange.send()
            apply()
        }
    }

    var watchingUSB: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.usb) }
        set {
            guard newValue != watchingUSB else { return }
            usbGeneration &+= 1
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
        if watchingBluetooth {
            bluetoothMonitor.refresh()
            if bluetoothApps.isEmpty {
                bluetoothAppsAutomaticRetriesRemaining = 1
                apply()
            }
        }
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
        if !pending.isEmpty {
            // SQLite uses descending insertion IDs to order events sharing one-second timestamps.
            // Persist oldest-first so the newest in-memory event remains newest after relaunch.
            persist(Array(pending.reversed()))
        }
    }

    private func apply() {
        if watchingBluetooth {
            if !bluetoothRunning {
                bluetoothRunning = true
                bluetoothMonitor.start(generation: bluetoothGeneration)
            }
            if bluetoothApps.isEmpty, !bluetoothAppsScanInFlight {
                // Reading several hundred Info.plists off the main actor. One scan may be in flight at a time, while
                // an empty result remains retryable because application-directory enumeration can fail transiently.
                bluetoothAppsScanInFlight = true
                let provider = bluetoothAppsProvider
                let scan = Task.detached(priority: .utility) { provider() }
                let generation = bluetoothGeneration
                Task { @MainActor in
                    let apps = await scan.value
                    self.bluetoothAppsScanInFlight = false
                    guard self.watchingBluetooth,
                          self.bluetoothGeneration == generation else {
                        // A scan crossing opt-out must neither publish stale applications nor consume the next
                        // generation's retry budget. Re-enter apply so a re-enabled session starts its own scan.
                        self.apply()
                        return
                    }
                    self.bluetoothApps = apps
                    guard apps.isEmpty, self.bluetoothAppsAutomaticRetriesRemaining > 0 else { return }
                    self.bluetoothAppsAutomaticRetriesRemaining -= 1
                    let delay = self.bluetoothAppsRetryDelay
                    Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        guard self.watchingBluetooth,
                              self.bluetoothGeneration == generation,
                              self.bluetoothApps.isEmpty else { return }
                        self.apply()
                    }
                }
            }
        } else if bluetoothRunning {
            bluetoothRunning = false
            bluetoothMonitor.stop()
            bluetooth = []
        }
        if watchingUSB {
            if !usbRunning {
                usbRunning = true
                usbMonitor.start(generation: usbGeneration)
            }
        } else if usbRunning {
            usbRunning = false
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
            eventsDuringClear = incoming + eventsDuringClear
        } else {
            // The UI prepends this newest-first batch as-is, while SQLite breaks equal-second ties by descending row ID.
            // Insert the batch in reverse so a relaunch reconstructs the exact same visible order.
            persist(Array(incoming.reversed()))
        }
        Notifier.post(devices: incoming)
    }

    private func persist(_ events: [DeviceEvent]) {
        db?.async { try $0.recordDeviceEvents(events) }
    }
}
