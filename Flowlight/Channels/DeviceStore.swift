import Foundation

/// The channels that aren't the network: what is connected over Bluetooth or USB, and when that changed.
///
/// Each channel is off until it is switched on. Not because either needs a permission Flowlight can't get — neither
/// does — but because turning them on widens what the app watches, and that should be a decision rather than a
/// surprise in an update.
@MainActor
final class DeviceStore: ObservableObject {
    enum Keys {
        static let bluetooth = "devices.bluetooth"
        static let usb = "devices.usb"
    }

    @Published private(set) var bluetooth: [PeripheralDevice] = []
    @Published private(set) var usb: [PeripheralDevice] = []
    @Published private(set) var events: [DeviceEvent] = []
    /// Apps built to use Bluetooth, as their own Info.plist declares.
    @Published private(set) var bluetoothApps: [InstalledApps.App] = []

    private let bluetoothMonitor = BluetoothMonitor()
    private weak var db: TrafficDatabase?

    init() {
        UserDefaults.standard.register(defaults: [Keys.bluetooth: false, Keys.usb: false])
        bluetoothMonitor.onDevices = { [weak self] devices in
            Task { @MainActor in self?.bluetooth = devices }
        }
        bluetoothMonitor.onEvents = { [weak self] events in
            Task { @MainActor in self?.record(events) }
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

    var isWatchingAnything: Bool { watchingBluetooth || watchingUSB }

    func attach(db: TrafficDatabase) {
        self.db = db
        db.async { [weak self] db in
            let history = (try? db.deviceEvents()) ?? []
            Task { @MainActor in self?.events = history }
        }
        apply()
    }

    func refresh() {
        if watchingBluetooth { bluetoothMonitor.refresh() }
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
        if !watchingUSB { usb = [] }
    }

    private func record(_ incoming: [DeviceEvent]) {
        guard !incoming.isEmpty else { return }
        events = incoming + events
        db?.async { try $0.recordDeviceEvents(incoming) }
        Notifier.post(devices: incoming)
    }
}
