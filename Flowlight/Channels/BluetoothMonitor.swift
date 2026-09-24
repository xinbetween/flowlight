import Foundation

/// What is paired to this Mac over Bluetooth, and when that changes.
///
/// **What this can and can't say.** macOS keeps no per-app byte accounting for Bluetooth: there is no equivalent of
/// the per-socket counters the network side is built on, and byte-level HCI traces need Apple's PacketLogger
/// profile, which an ordinary app cannot read. So Flowlight reports which devices are paired, which are connected,
/// and when that changed — and it does not pretend to know how much any app sent over the radio.
///
/// It reads `system_profiler SPBluetoothDataType`, which needs no entitlement and no permission prompt, and covers
/// both Classic and Low Energy devices. That costs a subprocess of a second or so, which is why it is polled every
/// half minute rather than continuously, and only while the feature is switched on.
final class BluetoothMonitor: @unchecked Sendable {
    /// Called with the current devices whenever the list is re-read, and separately with anything that changed.
    var onDevices: ([PeripheralDevice]) -> Void = { _ in }
    var onEvents: ([DeviceEvent]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "flowlight.bluetooth", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var known: [PeripheralDevice] = []
    private var sawAnything = false

    var interval: TimeInterval = 30
    /// Overridable for tests.
    var read: () -> Data? = { BluetoothMonitor.runSystemProfiler() }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Re-reads now, for the button that says so.
    func refresh() { queue.async { [weak self] in self?.sample() } }

    private func sample() {
        guard let data = read(), let devices = Self.parse(data) else { return }
        let events = DeviceDiff.events(from: known, to: devices, firstSighting: !sawAnything)
        known = devices
        sawAnything = true
        onDevices(devices)
        if !events.isEmpty { onEvents(events) }
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: Reading what it said

    /// `system_profiler SPBluetoothDataType -json`, as a list of devices.
    ///
    /// The shape is awkward: connected and disconnected devices are two separate arrays, and each entry is a
    /// single-key dictionary whose key is the device's name. Parsed rather than assumed, so a Mac with no
    /// Bluetooth hardware, or a macOS that renames a key, produces an empty list instead of a crash.
    static func parse(_ data: Data) -> [PeripheralDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var devices: [PeripheralDevice] = []
        for section in sections {
            devices += entries(section["device_connected"], connected: true)
            devices += entries(section["device_not_connected"], connected: false)
        }
        // A device can be listed twice across controllers; the connected sighting is the one that matters.
        var byID: [String: PeripheralDevice] = [:]
        for device in devices {
            if let existing = byID[device.id], existing.connected, !device.connected { continue }
            byID[device.id] = device
        }
        return byID.values.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
    }

    private static func entries(_ value: Any?, connected: Bool) -> [PeripheralDevice] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.flatMap { entry -> [PeripheralDevice] in
            entry.compactMap { name, info in
                guard let fields = info as? [String: Any] else { return nil }
                let address = (fields["device_address"] as? String) ?? name
                return PeripheralDevice(kind: .bluetooth, id: address, name: name,
                                        detail: (fields["device_minorType"] as? String) ?? "",
                                        connected: connected,
                                        vendor: Self.vendor(fields["device_vendorID"] as? String))
            }
        }
    }

    /// Vendor IDs come through as `0x004C`. Only the ones worth naming are named; the rest aren't guessed at.
    static func vendor(_ id: String?) -> String {
        guard let id = id?.lowercased() else { return "" }
        switch id {
        case "0x004c", "0x4c": return "Apple"
        case "0x000f", "0xf": return "Broadcom"
        case "0x0006", "0x6": return "Microsoft"
        case "0x0075", "0x75": return "Samsung"
        case "0x00e0", "0xe0": return "Google"
        case "0x0087", "0x87": return "Garmin"
        case "0x0171", "0x171": return "Amazon"
        default: return ""
        }
    }
}
